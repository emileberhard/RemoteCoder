use std::fs::{File, OpenOptions};
use std::io::Read;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, SystemTime};

use anyhow::{Context, Result, ensure};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::time::Instant;

use super::content_store::{Limits, inventory, retain};
use super::no_follow::Root;
use super::visual_bundle::LocalImages;
use super::visual_images::{Admission, ImageError, Preparation};
use crate::config::HostPaths;

pub(crate) const MAX_HTML_BYTES: usize = 2 * 1024 * 1024;
const PUBLISH_DEADLINE: Duration = Duration::from_secs(30);
const MAX_TITLE_BYTES: usize = 200;
const LIMITS: Limits = Limits {
    bytes: 256 * 1024 * 1024,
    entries: 4096,
};
static TRANSACTION: Mutex<()> = Mutex::new(());

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Arguments {
    html: Option<String>,
    path: Option<PathBuf>,
    title: String,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(try_from = "Arguments")]
pub(crate) struct PublishVisual {
    source: Source,
    title: String,
}

#[derive(Debug, PartialEq)]
enum Source {
    Html(String),
    Path(PathBuf),
}

impl TryFrom<Arguments> for PublishVisual {
    type Error = &'static str;

    fn try_from(arguments: Arguments) -> Result<Self, Self::Error> {
        let source = match (arguments.html, arguments.path) {
            (Some(html), None) => Source::Html(html),
            (None, Some(path)) => Source::Path(path),
            _ => return Err("publish_visual needs exactly one of html or path"),
        };
        Ok(Self {
            source,
            title: arguments.title,
        })
    }
}

impl PublishVisual {
    pub(crate) fn validate(&self) -> Result<()> {
        match &self.source {
            Source::Html(html) => ensure!(
                !html.trim().is_empty() && html.len() <= MAX_HTML_BYTES,
                "publish_visual html must be non-empty and at most 2 MiB"
            ),
            Source::Path(path) => {
                ensure!(path.is_absolute(), "publish_visual needs an absolute path")
            }
        }
        ensure!(
            !self.title.trim().is_empty()
                && self.title.len() <= MAX_TITLE_BYTES
                && !self.title.chars().any(char::is_control),
            "publish_visual title must contain 1–200 UTF-8 bytes without control characters"
        );
        Ok(())
    }

    pub(crate) fn audit(&self) -> serde_json::Value {
        match &self.source {
            Source::Html(html) => {
                serde_json::json!({"htmlBytes": html.len(), "titleBytes": self.title.len()})
            }
            Source::Path(path) => {
                serde_json::json!({"pathBytes": path.as_os_str().len(), "titleBytes": self.title.len()})
            }
        }
    }

    pub(crate) async fn publish(self) -> Result<Published, PublishError> {
        let paths = HostPaths::from_env()
            .map_err(|error| PublishError::new("host", format!("{error:#}")))?;
        self.publish_to(paths).await
    }

    async fn publish_to(self, paths: HostPaths) -> Result<Published, PublishError> {
        let deadline = Instant::now() + PUBLISH_DEADLINE;
        self.validate()
            .map_err(|error| PublishError::new("arguments", format!("{error:#}")))?;
        let Self { source, title } = self;
        let (html, images) = blocking(move || {
            let (html, file) = match source {
                Source::Html(html) => (html, None),
                Source::Path(path) => (
                    String::from_utf8(read_source(&path)?)
                        .map_err(|_| PublishError::new("source", "HTML must be valid UTF-8"))?,
                    Some(path),
                ),
            };
            let images = LocalImages::find(&html, file.as_deref())
                .map_err(|message| PublishError::new("local_reference", message))?;
            Ok((html, images))
        })
        .await?;
        let mut audit = json!({"htmlBytes": html.len(), "images": images.paths().len(), "occurrences": images.occurrences()});
        let bytes = if images.paths().is_empty() {
            html.into_bytes()
        } else {
            let prepared = prepare_images(&paths, &images, deadline).await?;
            audit["converted"] = json!(prepared.iter().filter(|image| image.converted).count());
            audit["passedThrough"] =
                json!(prepared.iter().filter(|image| !image.converted).count());
            blocking(move || {
                images
                    .embed(&html, &prepared)
                    .map_err(|message| PublishError::new("budget", message))
            })
            .await?
        };
        audit["visualBytes"] = json!(bytes.len());
        let (hash, bytes) = blocking(move || {
            validate_html(&bytes).map_err(|error| {
                match error.downcast::<super::visual_html::Rejection>() {
                    Ok(rejection) => PublishError::new(rejection.category, rejection.message),
                    Err(error) => PublishError::new("invalid_html", format!("{error:#}")),
                }
            })?;
            let hash = publish_bytes(&paths, &bytes)
                .map_err(|error| PublishError::new("store", format!("{error:#}")))?;
            Ok((hash, bytes))
        })
        .await?;
        Ok(Published {
            embed: embed(&title, &hash),
            audit,
            hash,
            bytes,
        })
    }
}

pub(crate) fn embed(title: &str, hash: &str) -> String {
    let title = title
        .replace('\\', "\\\\")
        .replace('[', "\\[")
        .replace(']', "\\]");
    format!("![{title}](rc-visual:{hash})")
}

pub(crate) struct Published {
    pub(crate) embed: String,
    pub(crate) audit: Value,
    pub(crate) hash: String,
    pub(crate) bytes: Vec<u8>,
}

#[derive(Debug)]
pub(crate) struct PublishError {
    category: &'static str,
    message: String,
}

impl PublishError {
    fn new(category: &'static str, message: impl Into<String>) -> Self {
        Self {
            category,
            message: message.into(),
        }
    }

    pub(crate) fn audit(&self) -> Value {
        json!({"failure": self.category})
    }
}

impl std::fmt::Display for PublishError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

async fn blocking<T: Send + 'static>(
    work: impl FnOnce() -> Result<T, PublishError> + Send + 'static,
) -> Result<T, PublishError> {
    tokio::task::spawn_blocking(work).await.map_err(|error| {
        PublishError::new(
            "worker",
            format!("visual publishing worker failed: {error}"),
        )
    })?
}

async fn prepare_images(
    paths: &HostPaths,
    images: &LocalImages,
    deadline: Instant,
) -> Result<Vec<super::visual_images::EmbeddedImage>, PublishError> {
    let unavailable = |error: ImageError| {
        PublishError::new(
            error.category(),
            format!("Local images could not be embedded: {error}"),
        )
    };
    let admission = Admission::try_new().ok_or_else(|| unavailable(ImageError::Busy))?;
    let preparation = Preparation::admit(&admission, paths, deadline)
        .await
        .map_err(unavailable)?;
    let mut prepared = Vec::with_capacity(images.paths().len());
    let mut failures = Vec::new();
    let mut category = None;
    for (index, path) in images.paths().iter().enumerate() {
        if Instant::now() >= deadline {
            category.get_or_insert("timeout");
            failures.extend(
                images.paths()[index..]
                    .iter()
                    .map(|path| format!("- {}: not attempted before the deadline", path.display())),
            );
            break;
        }
        match preparation.prepare(path, deadline).await {
            Ok(image) => prepared.push(image),
            Err(error) => {
                category.get_or_insert(error.category());
                failures.push(format!("- {}: {error}", path.display()));
            }
        }
    }
    match category {
        None => Ok(prepared),
        Some(category) => Err(PublishError::new(
            category,
            format!(
                "Local images could not be embedded:\n{}",
                failures.join("\n")
            ),
        )),
    }
}

fn read_source(path: &Path) -> Result<Vec<u8>, PublishError> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .map_err(|error| {
            PublishError::new("source", format!("could not open visual source: {error}"))
        })?;
    read_bounded(file).map_err(|error| PublishError::new("source", format!("{error:#}")))
}

fn read_bounded(file: File) -> Result<Vec<u8>> {
    let metadata = file.metadata()?;
    ensure!(metadata.is_file(), "visual source must be a regular file");
    ensure!(
        metadata.len() <= MAX_HTML_BYTES as u64,
        "HTML exceeds 2 MiB"
    );
    let mut bytes = Vec::new();
    file.take(MAX_HTML_BYTES as u64 + 1)
        .read_to_end(&mut bytes)?;
    ensure!(bytes.len() <= MAX_HTML_BYTES, "HTML exceeds 2 MiB");
    Ok(bytes)
}

fn read_html(file: File) -> Result<Vec<u8>> {
    let bytes = read_bounded(file)?;
    validate_html(&bytes)?;
    Ok(bytes)
}

fn validate_html(bytes: &[u8]) -> Result<()> {
    ensure!(bytes.len() <= MAX_HTML_BYTES, "HTML exceeds 2 MiB");
    let html = std::str::from_utf8(bytes).context("HTML must be valid UTF-8")?;
    super::visual_html::validate_html(html)?;
    Ok(())
}

fn publish_bytes(paths: &HostPaths, bytes: &[u8]) -> Result<String> {
    validate_html(bytes)?;
    let _transaction = TRANSACTION
        .lock()
        .map_err(|_| anyhow::anyhow!("visual store transaction lock poisoned"))?;
    let root = Root::open(paths.home())?;
    let directory = paths.state("visuals");
    root.ensure_directory(&directory)?;
    let _lock = root.lock_file(&directory.join("store.lock"))?;
    let hash = format!("{:x}", Sha256::digest(bytes));
    let destination = directory.join(format!("{hash}.html"));
    let entries = inventory(&root, &directory, &LIMITS, &["html"])?;
    let existing = root.open_file(&destination)?;
    if let Some(file) = &existing {
        ensure!(
            file.metadata()?.permissions().mode() & 0o777 == 0o400,
            "stored visual has invalid permissions"
        );
        ensure!(
            read_html(file.try_clone()?)? == bytes,
            "stored visual content is corrupt"
        );
    }
    let incoming = if existing.is_some() {
        0
    } else {
        bytes.len() as u64
    };
    retain(
        &root,
        entries,
        std::slice::from_ref(&destination),
        incoming,
        usize::from(incoming > 0),
        &LIMITS,
    )?;
    if let Some(file) = existing {
        file.set_modified(SystemTime::now())?;
    } else {
        root.write_read_only(&destination, bytes)?;
    }
    Ok(hash)
}

#[cfg(test)]
mod tests {
    use super::super::visual_images::test_images;
    use super::*;

    #[test]
    fn arguments_are_strict_and_title_cannot_break_the_embed() {
        let decode = |value| serde_json::from_value::<PublishVisual>(value);
        for value in [
            serde_json::json!({"path":"/tmp/a.html"}),
            serde_json::json!({"path":"/tmp/a.html","title":"a","extra":true}),
            serde_json::json!({"path":7,"title":"a"}),
            serde_json::json!({"title":"a"}),
            serde_json::json!({"html":"<p>a</p>","path":"/tmp/a.html","title":"a"}),
        ] {
            assert!(decode(value).is_err());
        }
        for value in [
            serde_json::json!({"path":"relative","title":"a"}),
            serde_json::json!({"path":"/tmp/a.html","title":" "}),
            serde_json::json!({"path":"/tmp/a.html","title":"line\nnext"}),
            serde_json::json!({"html":" ","title":"a"}),
            serde_json::json!({"html":"a".repeat(MAX_HTML_BYTES + 1),"title":"a"}),
        ] {
            assert!(decode(value).unwrap().validate().is_err());
        }
        let inline = decode(serde_json::json!({"html":"<p>a</p>","title":"a"})).unwrap();
        inline.validate().unwrap();
        assert_eq!(
            inline.audit(),
            serde_json::json!({"htmlBytes":8,"titleBytes":1})
        );
        assert!(
            decode(serde_json::json!({"path":"/tmp/a.html","title":"a".repeat(201)}))
                .unwrap()
                .validate()
                .is_err()
        );
        let visual = decode(serde_json::json!({"path":"/tmp/a.html","title":r"a[b]\c"})).unwrap();
        visual.validate().unwrap();
        assert_eq!(embed(&visual.title, "abc"), r"![a\[b\]\\c](rc-visual:abc)");
        assert_eq!(
            visual.audit(),
            serde_json::json!({"pathBytes":11,"titleBytes":6})
        );
    }

    #[test]
    fn publishing_is_content_addressed_read_only_and_refuses_corruption() {
        let home = tempfile::tempdir().unwrap();
        let paths = HostPaths::from_home(home.path().to_owned()).unwrap();
        let bytes = b"<html><body>Visual</body></html>";
        let directory = paths.state("visuals");
        std::fs::create_dir_all(&directory).unwrap();
        std::fs::write(directory.join(".migration.12.1.new"), b"abandoned").unwrap();
        let hash = publish_bytes(&paths, bytes).unwrap();
        assert_eq!(publish_bytes(&paths, bytes).unwrap(), hash);
        let path = paths.state("visuals").join(format!("{hash}.html"));
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o400
        );
        assert_eq!(
            std::fs::read_dir(path.parent().unwrap()).unwrap().count(),
            2
        );
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert!(publish_bytes(&paths, bytes).is_err());
        std::fs::write(&path, b"<div>Corruption</div>").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o400)).unwrap();
        assert!(publish_bytes(&paths, bytes).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"<div>Corruption</div>");
    }

    #[test]
    fn sources_reject_non_html_invalid_utf8_oversize_symlinks_and_non_files() {
        let directory = tempfile::tempdir().unwrap();
        let source = directory.path().join("source");
        for bytes in [
            b"plain text".as_slice(),
            b"<div>\xff</div>",
            b"<div>\0</div>",
        ] {
            assert!(validate_html(bytes).is_err());
        }
        std::fs::write(&source, b"<section>Fragment</section>").unwrap();
        assert!(read_source(&source).is_ok());
        let link = directory.path().join("link");
        std::os::unix::fs::symlink(&source, &link).unwrap();
        assert!(read_source(&link).is_err());
        assert!(read_source(directory.path()).is_err());
        let file = OpenOptions::new().write(true).open(&source).unwrap();
        file.set_len(MAX_HTML_BYTES as u64 + 1).unwrap();
        assert!(read_source(&source).is_err());
        assert!(validate_html(&vec![b'a'; MAX_HTML_BYTES + 1]).is_err());
    }

    #[test]
    fn concurrent_publishers_share_one_atomic_read_only_file() {
        let home = tempfile::tempdir().unwrap();
        let paths = HostPaths::from_home(home.path().to_owned()).unwrap();
        let workers = (0..8)
            .map(|_| {
                let paths = paths.clone();
                std::thread::spawn(move || publish_bytes(&paths, b"<svg></svg>").unwrap())
            })
            .collect::<Vec<_>>();
        let hashes = workers
            .into_iter()
            .map(|worker| worker.join().unwrap())
            .collect::<Vec<_>>();
        assert!(hashes.iter().all(|hash| hash == &hashes[0]));
        let directory = paths.state("visuals");
        assert_eq!(std::fs::read_dir(&directory).unwrap().count(), 2);
        let file = directory.join(format!("{}.html", hashes[0]));
        assert_eq!(std::fs::read(&file).unwrap(), b"<svg></svg>");
        assert_eq!(
            std::fs::metadata(file).unwrap().permissions().mode() & 0o777,
            0o400
        );
    }

    #[test]
    fn deduplicated_publication_refreshes_retention_priority_without_changing_content() {
        let home = tempfile::tempdir().unwrap();
        let paths = HostPaths::from_home(home.path().to_owned()).unwrap();
        let bytes = b"<pre>Frequently published</pre>";
        let hash = publish_bytes(&paths, bytes).unwrap();
        let directory = paths.state("visuals");
        let repeated = directory.join(format!("{hash}.html"));
        File::open(&repeated)
            .unwrap()
            .set_modified(SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(1))
            .unwrap();
        let older = directory.join(format!("{}.html", "0".repeat(64)));
        let file = File::create(&older).unwrap();
        file.set_len(LIMITS.bytes - bytes.len() as u64).unwrap();
        file.set_modified(SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(2))
            .unwrap();
        assert_eq!(publish_bytes(&paths, bytes).unwrap(), hash);
        assert!(
            std::fs::metadata(&repeated).unwrap().modified().unwrap()
                > SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(2)
        );
        publish_bytes(&paths, b"<h4>New publication</h4>").unwrap();
        assert!(repeated.exists());
        assert!(!older.exists());
        assert_eq!(std::fs::read(&repeated).unwrap(), bytes);
        assert_eq!(
            std::fs::metadata(&repeated).unwrap().permissions().mode() & 0o777,
            0o400
        );
    }

    #[test]
    fn retention_removes_oldest_visuals_before_admitting_new_content() {
        let home = tempfile::tempdir().unwrap();
        let paths = HostPaths::from_home(home.path().to_owned()).unwrap();
        let root = Root::open(paths.home()).unwrap();
        let directory = paths.state("visuals");
        root.ensure_directory(&directory).unwrap();
        let old = directory.join(format!("{}.html", "0".repeat(64)));
        let newer = directory.join(format!("{}.html", "1".repeat(64)));
        for (path, modified) in [(&old, 1), (&newer, 2)] {
            let file = File::create(path).unwrap();
            file.set_len(LIMITS.bytes / 2).unwrap();
            file.set_times(
                std::fs::FileTimes::new()
                    .set_modified(std::time::UNIX_EPOCH + std::time::Duration::from_secs(modified)),
            )
            .unwrap();
        }
        let hash = publish_bytes(&paths, b"<div>New</div>").unwrap();
        assert!(!old.exists());
        assert!(newer.exists());
        assert!(directory.join(format!("{hash}.html")).exists());
    }

    fn visual(path: &Path) -> PublishVisual {
        PublishVisual {
            source: Source::Path(path.to_owned()),
            title: "Screens".into(),
        }
    }

    fn stored(paths: &HostPaths) -> Vec<PathBuf> {
        std::fs::read_dir(paths.state("visuals"))
            .map(|entries| {
                entries
                    .map(|entry| entry.unwrap().path())
                    .filter(|path| {
                        path.extension()
                            .is_some_and(|extension| extension == "html")
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    #[tokio::test]
    async fn local_images_are_embedded_once_and_the_visual_outlives_them() {
        let _serial = test_images::SERIAL.lock().await;
        let home = tempfile::tempdir().unwrap();
        let paths = HostPaths::from_home(home.path().to_owned()).unwrap();
        let abandoned = paths.state("visual-staging").join("999999");
        std::fs::create_dir_all(&abandoned).unwrap();
        std::fs::write(abandoned.join("source"), b"left behind").unwrap();
        let work = tempfile::tempdir().unwrap();
        std::fs::create_dir(work.path().join("shots")).unwrap();
        let wide = work.path().join("shots/wide.png");
        let small = work.path().join("small one.png");
        std::fs::write(&wide, test_images::png(3200, 1000, false)).unwrap();
        std::fs::write(&small, test_images::png(40, 20, true)).unwrap();
        let source = work.path().join("visual.html");
        std::fs::write(
            &source,
            format!(
                "<h4>Screens</h4><img src=\"shots/wide.png\"><img src='file://{}'><svg><image href=\"small%20one.png\"/></svg>",
                wide.display()
            ),
        )
        .unwrap();
        let published = visual(&source).publish_to(paths.clone()).await.unwrap();
        assert_eq!(
            published.audit,
            json!({"htmlBytes": std::fs::metadata(&source).unwrap().len(), "images": 2, "occurrences": 3,
                "converted": 1, "passedThrough": 1, "visualBytes": published.audit["visualBytes"]})
        );
        let [file] = stored(&paths).try_into().unwrap();
        let html = std::fs::read_to_string(&file).unwrap();
        assert_eq!(html.matches("data:image/jpeg;base64,").count(), 2);
        assert_eq!(html.matches("data:image/png;base64,").count(), 1);
        assert!(!html.contains("wide.png") && !html.contains("small%20one.png"));
        assert_eq!(
            published.embed,
            format!(
                "![Screens](rc-visual:{})",
                file.file_stem().unwrap().to_str().unwrap()
            )
        );
        std::fs::remove_file(&wide).unwrap();
        assert_eq!(std::fs::read_to_string(&file).unwrap(), html);
        assert!(!abandoned.exists());
        assert!(
            !paths
                .state("visual-staging")
                .join(std::process::id().to_string())
                .exists()
        );
    }

    #[tokio::test]
    async fn inline_html_embeds_absolute_local_images_and_names_relative_ones() {
        let _serial = test_images::SERIAL.lock().await;
        let home = tempfile::tempdir().unwrap();
        let paths = HostPaths::from_home(home.path().to_owned()).unwrap();
        let work = tempfile::tempdir().unwrap();
        let image = work.path().join("chart.png");
        std::fs::write(&image, test_images::png(40, 20, true)).unwrap();
        let inline = |html: String| PublishVisual {
            source: Source::Html(html),
            title: "Inline".into(),
        };
        let published = inline(format!("<h4>Chart</h4><img src=\"{}\">", image.display()))
            .publish_to(paths.clone())
            .await
            .unwrap();
        let [file] = stored(&paths).try_into().unwrap();
        let html = std::fs::read_to_string(&file).unwrap();
        assert_eq!(html.matches("data:image/png;base64,").count(), 1);
        assert!(published.embed.starts_with("![Inline](rc-visual:"));
        let error = inline("<img src=\"chart.png\">".into())
            .publish_to(paths.clone())
            .await
            .err()
            .unwrap();
        assert_eq!(error.audit(), json!({"failure": "local_reference"}));
        assert!(error.to_string().contains("absolute path"), "{error}");
        assert_eq!(stored(&paths).len(), 1);
    }

    #[tokio::test]
    async fn failures_name_every_image_category_and_store_nothing() {
        let _serial = test_images::SERIAL.lock().await;
        let home = tempfile::tempdir().unwrap();
        let paths = HostPaths::from_home(home.path().to_owned()).unwrap();
        let work = tempfile::tempdir().unwrap();
        std::fs::write(work.path().join("notes.txt"), b"secret notes").unwrap();
        let source = work.path().join("visual.html");
        let publish = |html: String| {
            std::fs::write(&source, html).unwrap();
            visual(&source).publish_to(paths.clone())
        };

        let error = publish("<img src=\"missing.png\"><img src=\"notes.txt\">".into())
            .await
            .err()
            .unwrap();
        assert_eq!(error.audit(), json!({"failure": "image_file"}));
        let message = error.to_string();
        assert!(message.contains("missing.png: file not found"), "{message}");
        assert!(message.contains("notes.txt: not a PNG, JPEG"), "{message}");
        assert!(!message.contains("secret"), "{message}");

        let error = publish("<div style=\"background:url(shot.png)\">x</div>".into())
            .await
            .err()
            .unwrap();
        assert_eq!(error.audit(), json!({"failure": "css_local_reference"}));
        assert!(error.to_string().contains("<img src>"), "{error}");

        let error = publish("<img src=\"/a&b.png\">".into())
            .await
            .err()
            .unwrap();
        assert_eq!(error.audit(), json!({"failure": "local_reference"}));

        std::fs::write(
            work.path().join("big.png"),
            test_images::png(1600, 2500, false),
        )
        .unwrap();
        let error = publish("<img src=\"big.png\">".repeat(40))
            .await
            .err()
            .unwrap();
        assert_eq!(error.audit(), json!({"failure": "budget"}));
        assert!(error.to_string().contains("× 40"), "{error}");

        let held = (0..4)
            .map(|_| Admission::try_new().unwrap())
            .collect::<Vec<_>>();
        let error = publish("<img src=\"big.png\">".into()).await.err().unwrap();
        assert_eq!(error.audit(), json!({"failure": "capacity"}));
        drop(held);

        assert!(stored(&paths).is_empty());
    }
}
