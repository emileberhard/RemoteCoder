pub(crate) mod upload;

use std::fs::{File, Metadata, OpenOptions};
use std::io::{self, Read};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use axum::Json;
use axum::body::{Body, Bytes};
use axum::http::{HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use futures_util::stream;
use serde::{Deserialize, Serialize};
use serde_json::json;
use tokio::runtime::Handle;
use tokio::sync::{Semaphore, mpsc, oneshot};
use tokio_util::sync::CancellationToken;

const MAX_FILE_BYTES: u64 = 1024 * 1024 * 1024;
const MAX_DOWNLOADS: usize = 2;
const CHUNK_BYTES: usize = 64 * 1024;
const OPEN_TIMEOUT: Duration = Duration::from_secs(30);
const BODY_STALL_TIMEOUT: Duration = Duration::from_secs(30);
const METADATA_HEADER: &str = "x-remotecoder-file-metadata";

#[derive(Deserialize)]
#[serde(untagged)]
pub(crate) enum DownloadRequest {
    File(FileDownloadRequest),
    Visual(VisualDownloadRequest),
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct FileDownloadRequest {
    path: String,
    known_revision: Option<String>,
    containing_directory: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct VisualDownloadRequest {
    visual_digest: String,
    known_revision: Option<String>,
}

enum DownloadSource {
    File {
        path: PathBuf,
        containing_directory: Option<String>,
    },
    Visual {
        root: PathBuf,
        digest: String,
    },
}

impl VisualDownloadRequest {
    fn resolve(
        self,
        paths: &crate::config::HostPaths,
    ) -> Result<(DownloadSource, Option<String>), DownloadError> {
        if self.visual_digest.len() != 64
            || !self
                .visual_digest
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Err(DownloadError::InvalidPath);
        }
        Ok((
            DownloadSource::Visual {
                root: paths.state("visuals"),
                digest: self.visual_digest,
            },
            self.known_revision,
        ))
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct FileMetadata {
    path: String,
    name: String,
    bytes: u64,
    modified_at: f64,
    revision: String,
}

#[derive(Debug)]
pub(crate) enum DownloadError {
    InvalidPath,
    Missing,
    AccessDenied,
    NotFile,
    TooLarge,
    Busy,
    Draining,
    Changed,
    Io(io::Error),
}

impl DownloadError {
    fn kind(&self) -> &'static str {
        match self {
            Self::InvalidPath => "invalidPath",
            Self::Missing => "missing",
            Self::AccessDenied => "accessDenied",
            Self::NotFile => "notFile",
            Self::TooLarge => "tooLarge",
            Self::Busy => "busy",
            Self::Draining => "draining",
            Self::Changed => "changed",
            Self::Io(_) => "io",
        }
    }

    fn message(&self) -> String {
        match self {
            Self::InvalidPath => {
                "Provide an absolute path or a visualDigest containing 64 lowercase hex characters."
                    .to_string()
            }
            Self::Missing => "The file no longer exists on this host.".to_string(),
            Self::AccessDenied => {
                "The host cannot read this file. Check its file permissions.".to_string()
            }
            Self::NotFile => {
                "Only regular files can be downloaded. Choose a file, not a directory or device."
                    .to_string()
            }
            Self::TooLarge => "This file exceeds its download limit.".to_string(),
            Self::Busy => {
                "Two downloads are already active on this host. Try again after one finishes."
                    .to_string()
            }
            Self::Draining => "The host is restarting. Reconnect and try again.".to_string(),
            Self::Changed => {
                "The file changed during the download. Try again when it has finished saving."
                    .to_string()
            }
            Self::Io(error) => format!("The file could not be read: {error}"),
        }
    }

    fn into_stream_error(self) -> io::Error {
        io::Error::other(format!("{}: {}", self.kind(), self.message()))
    }
}

impl From<io::Error> for DownloadError {
    fn from(error: io::Error) -> Self {
        match error.kind() {
            io::ErrorKind::NotFound => Self::Missing,
            io::ErrorKind::PermissionDenied => Self::AccessDenied,
            io::ErrorKind::InvalidInput => Self::InvalidPath,
            _ => match error.raw_os_error() {
                Some(libc::ENOTDIR) => Self::Missing,
                Some(libc::ENAMETOOLONG | libc::ELOOP) => Self::InvalidPath,
                Some(libc::ENXIO | libc::ENODEV) => Self::NotFile,
                _ => Self::Io(error),
            },
        }
    }
}

impl IntoResponse for DownloadError {
    fn into_response(self) -> Response {
        let status = match self {
            Self::InvalidPath | Self::NotFile => StatusCode::BAD_REQUEST,
            Self::Missing => StatusCode::NOT_FOUND,
            Self::AccessDenied => StatusCode::FORBIDDEN,
            Self::TooLarge => StatusCode::PAYLOAD_TOO_LARGE,
            Self::Busy => StatusCode::TOO_MANY_REQUESTS,
            Self::Draining => StatusCode::SERVICE_UNAVAILABLE,
            Self::Changed => StatusCode::CONFLICT,
            Self::Io(_) => StatusCode::INTERNAL_SERVER_ERROR,
        };
        (
            status,
            [(header::CACHE_CONTROL, "no-store")],
            Json(json!({"kind": self.kind(), "message": self.message()})),
        )
            .into_response()
    }
}

#[derive(Clone)]
pub(crate) struct FileDownloads {
    slots: Arc<Semaphore>,
    shutdown: CancellationToken,
    body_stall_timeout: Duration,
}

struct PreparedDownload {
    metadata: FileMetadata,
    unchanged: bool,
}

impl Default for FileDownloads {
    fn default() -> Self {
        Self {
            slots: Arc::new(Semaphore::new(MAX_DOWNLOADS)),
            shutdown: CancellationToken::new(),
            body_stall_timeout: BODY_STALL_TIMEOUT,
        }
    }
}

impl FileDownloads {
    pub(crate) fn drain(&self) {
        self.shutdown.cancel();
    }

    pub(crate) async fn download(
        &self,
        request: DownloadRequest,
    ) -> Result<Response, DownloadError> {
        if self.shutdown.is_cancelled() {
            return Err(DownloadError::Draining);
        }
        let (source, known_revision) = match request {
            DownloadRequest::File(request) => (
                DownloadSource::File {
                    path: normalized_path(&request.path)?,
                    containing_directory: request.containing_directory,
                },
                request.known_revision,
            ),
            DownloadRequest::Visual(request) => {
                let paths = crate::config::HostPaths::from_env()
                    .map_err(|error| DownloadError::Io(io::Error::other(error)))?;
                request.resolve(&paths)?
            }
        };
        self.download_source(source, known_revision).await
    }

    async fn download_source(
        &self,
        source: DownloadSource,
        known_revision: Option<String>,
    ) -> Result<Response, DownloadError> {
        let permit = Arc::clone(&self.slots)
            .try_acquire_owned()
            .map_err(|_| DownloadError::Busy)?;
        let (prepared_tx, prepared_rx) = oneshot::channel();
        let (body_tx, body_rx) = mpsc::channel(1);
        let shutdown = self.shutdown.clone();
        let body_stall_timeout = self.body_stall_timeout;
        let runtime = Handle::current();
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            if prepared_tx.is_closed() || shutdown.is_cancelled() {
                return;
            }
            let opened = match source {
                DownloadSource::File {
                    path,
                    containing_directory,
                } => FileSource::open_download(path, containing_directory.as_deref()),
                DownloadSource::Visual { root, digest } => FileSource::open_visual(&root, &digest),
            };
            let mut source = match opened {
                Ok(source) => source,
                Err(error) => {
                    let _ = prepared_tx.send(Err(error));
                    return;
                }
            };
            let unchanged = known_revision.as_deref() == Some(&source.metadata.revision);
            let first = if unchanged {
                source.revalidate().map(|()| None)
            } else {
                source.read_chunk()
            };
            let first = match first {
                Ok(first) => first,
                Err(error) => {
                    let _ = prepared_tx.send(Err(error));
                    return;
                }
            };
            let empty = source.metadata.bytes == 0;
            if prepared_tx
                .send(Ok(PreparedDownload {
                    metadata: source.metadata.clone(),
                    unchanged,
                }))
                .is_err()
                || unchanged
                || empty
            {
                return;
            }
            let mut next = first;
            loop {
                if shutdown.is_cancelled() || body_tx.is_closed() {
                    return;
                }
                let Some(chunk) = next else {
                    runtime.block_on(async {
                        tokio::select! {
                            () = shutdown.cancelled() => {},
                            _ = tokio::time::timeout(body_stall_timeout, async {
                                if body_tx.send(None).await.is_ok() {
                                    body_tx.closed().await;
                                }
                            }) => {},
                        }
                    });
                    return;
                };
                let capacity = runtime.block_on(async {
                    tokio::select! {
                        () = shutdown.cancelled() => None,
                        result = tokio::time::timeout(body_stall_timeout, body_tx.reserve()) => {
                            result.ok().and_then(Result::ok)
                        },
                    }
                });
                let Some(capacity) = capacity else {
                    return;
                };
                if source.remaining == 0
                    && let Err(error) = source.revalidate()
                {
                    capacity.send(Some(Err(error.into_stream_error())));
                    return;
                }
                capacity.send(Some(Ok(chunk)));
                if source.remaining == 0 {
                    next = None;
                    continue;
                }
                match source.read_chunk() {
                    Ok(chunk) => next = chunk,
                    Err(error) => {
                        runtime.block_on(async {
                            tokio::select! {
                                () = shutdown.cancelled() => {},
                                _ = tokio::time::timeout(
                                    body_stall_timeout,
                                    body_tx.send(Some(Err(error.into_stream_error()))),
                                ) => {},
                            }
                        });
                        return;
                    }
                }
            }
        });
        let prepared = tokio::select! {
            () = self.shutdown.cancelled() => return Err(DownloadError::Draining),
            result = tokio::time::timeout(OPEN_TIMEOUT, prepared_rx) => {
                result
                    .map_err(|_| DownloadError::Io(io::Error::new(io::ErrorKind::TimedOut, "file open stalled")))?
                    .map_err(|_| DownloadError::Io(io::Error::other("file reader stopped")))??
            },
        };
        let metadata = serde_json::to_vec(&prepared.metadata)
            .map_err(|error| DownloadError::Io(io::Error::other(error)))?;
        let metadata = HeaderValue::from_str(&STANDARD.encode(metadata))
            .map_err(|error| DownloadError::Io(io::Error::other(error)))?;
        let mut response = if prepared.unchanged {
            StatusCode::NO_CONTENT.into_response()
        } else {
            let body = Body::from_stream(stream::unfold(body_rx, |mut receiver| async move {
                receiver
                    .recv()
                    .await
                    .flatten()
                    .map(|chunk| (chunk, receiver))
            }));
            let mut response = Response::new(body);
            response.headers_mut().insert(
                header::CONTENT_TYPE,
                HeaderValue::from_static("application/octet-stream"),
            );
            response.headers_mut().insert(
                header::CONTENT_LENGTH,
                HeaderValue::from(prepared.metadata.bytes),
            );
            response
        };
        response.headers_mut().insert(METADATA_HEADER, metadata);
        response
            .headers_mut()
            .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
        Ok(response)
    }
}

struct FileSource {
    file: File,
    metadata: FileMetadata,
    remaining: u64,
}

impl FileSource {
    fn open_visual(root: &Path, digest: &str) -> Result<Self, DownloadError> {
        let path = root.join(format!("{digest}.html"));
        let root = crate::storage::no_follow::Root::open_existing(root).map_err(|error| {
            if error
                .chain()
                .filter_map(|cause| cause.downcast_ref::<io::Error>())
                .any(|error| error.kind() == io::ErrorKind::NotFound)
            {
                DownloadError::Missing
            } else {
                DownloadError::AccessDenied
            }
        })?;
        let file = root
            .open_file(&path)
            .map_err(|_| DownloadError::AccessDenied)?
            .ok_or(DownloadError::Missing)?;
        let source = Self::from_file(path, file)?;
        if source.metadata.bytes > crate::storage::visuals::MAX_HTML_BYTES as u64 {
            return Err(DownloadError::TooLarge);
        }
        Ok(source)
    }

    fn open(path: PathBuf) -> Result<Self, DownloadError> {
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC)
            .open(&path)?;
        Self::from_file(path, file)
    }

    fn open_download(
        path: PathBuf,
        containing_directory: Option<&str>,
    ) -> Result<Self, DownloadError> {
        let Some(directory) = containing_directory else {
            return Self::open(path);
        };
        let directory = normalized_path(directory)?;
        if !path.starts_with(&directory) {
            return Err(DownloadError::AccessDenied);
        }
        let canonical_directory = directory.canonicalize()?;
        let canonical_path = path.canonicalize()?;
        if !canonical_path.starts_with(&canonical_directory) {
            return Err(DownloadError::AccessDenied);
        }
        let root = crate::storage::no_follow::Root::open_existing(&canonical_directory)
            .map_err(|_| DownloadError::AccessDenied)?;
        let file = root
            .open_file(&canonical_path)
            .map_err(|_| DownloadError::AccessDenied)?
            .ok_or(DownloadError::Missing)?;
        Self::from_file(path, file)
    }

    fn from_file(path: PathBuf, file: File) -> Result<Self, DownloadError> {
        let stat = file.metadata()?;
        if !stat.is_file() {
            return Err(DownloadError::NotFile);
        }
        if stat.len() > MAX_FILE_BYTES {
            return Err(DownloadError::TooLarge);
        }
        let revision = revision(&stat);
        let metadata = FileMetadata {
            name: path
                .file_name()
                .and_then(|name| name.to_str())
                .ok_or(DownloadError::InvalidPath)?
                .to_string(),
            path: path.to_str().ok_or(DownloadError::InvalidPath)?.to_string(),
            bytes: stat.len(),
            modified_at: stat.mtime() as f64 + stat.mtime_nsec() as f64 / 1_000_000_000.0,
            revision,
        };
        Ok(Self {
            file,
            metadata,
            remaining: stat.len(),
        })
    }

    fn revalidate(&self) -> Result<(), DownloadError> {
        if revision(&self.file.metadata()?) != self.metadata.revision {
            return Err(DownloadError::Changed);
        }
        Ok(())
    }

    fn read_chunk(&mut self) -> Result<Option<Bytes>, DownloadError> {
        if self.remaining == 0 {
            self.revalidate()?;
            return Ok(None);
        }
        let mut chunk = vec![0; self.remaining.min(CHUNK_BYTES as u64) as usize];
        match self.file.read_exact(&mut chunk) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => {
                return Err(DownloadError::Changed);
            }
            Err(error) => return Err(error.into()),
        }
        self.remaining -= chunk.len() as u64;
        if self.remaining == 0 {
            self.revalidate()?;
        }
        Ok(Some(Bytes::from(chunk)))
    }
}

fn revision(metadata: &Metadata) -> String {
    format!(
        "{:x}-{:x}-{:x}-{:x}-{:x}-{:x}-{:x}",
        metadata.dev(),
        metadata.ino(),
        metadata.len(),
        metadata.mtime(),
        metadata.mtime_nsec(),
        metadata.ctime(),
        metadata.ctime_nsec(),
    )
}

fn normalized_path(raw: &str) -> Result<PathBuf, DownloadError> {
    if raw.len() > 4096 || raw.contains('\0') || !Path::new(raw).is_absolute() {
        return Err(DownloadError::InvalidPath);
    }
    let mut path = PathBuf::new();
    for component in Path::new(raw).components() {
        match component {
            Component::RootDir | Component::Normal(_) => path.push(component.as_os_str()),
            Component::CurDir => {}
            Component::ParentDir => {
                if !path.pop() {
                    return Err(DownloadError::InvalidPath);
                }
            }
            Component::Prefix(_) => return Err(DownloadError::InvalidPath),
        }
    }
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures_util::StreamExt;
    use std::os::unix::fs::{PermissionsExt, symlink};

    fn request(path: &Path, known_revision: Option<String>) -> DownloadRequest {
        DownloadRequest::File(FileDownloadRequest {
            path: path.to_str().unwrap().to_string(),
            known_revision,
            containing_directory: None,
        })
    }

    fn metadata(response: &Response) -> serde_json::Value {
        let header = response.headers().get(METADATA_HEADER).unwrap();
        let bytes = STANDARD.decode(header.as_bytes()).unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }

    async fn await_released(downloads: &FileDownloads) {
        let permits = tokio::time::timeout(
            Duration::from_secs(2),
            downloads.slots.acquire_many(MAX_DOWNLOADS as u32),
        )
        .await
        .expect("download workers release their slots")
        .unwrap();
        drop(permits);
    }

    #[test]
    fn visual_requests_are_distinct_and_validate_canonical_digests() {
        let directory = tempfile::tempdir().unwrap();
        let paths =
            crate::config::HostPaths::from_home(directory.path().canonicalize().unwrap()).unwrap();
        for digest in [
            "a".repeat(63),
            "a".repeat(65),
            "A".repeat(64),
            "g".repeat(64),
            format!("{}../", "a".repeat(61)),
        ] {
            assert!(matches!(
                VisualDownloadRequest {
                    visual_digest: digest,
                    known_revision: None
                }
                .resolve(&paths),
                Err(DownloadError::InvalidPath)
            ));
        }
        for body in [
            json!({"visualDigest":"a".repeat(64), "path":"/private/file"}),
            json!({"visualDigest":"a".repeat(64), "containingDirectory":"/private"}),
            json!({"path":"/file", "maximumBytes":42}),
        ] {
            assert!(serde_json::from_value::<DownloadRequest>(body).is_err());
        }
        assert!(
            serde_json::from_value::<DownloadRequest>(json!({"visualDigest":"a".repeat(64)}))
                .is_ok()
        );
    }

    #[tokio::test]
    async fn missing_visual_store_is_read_only_and_reports_missing() {
        let directory = tempfile::tempdir().unwrap();
        let paths =
            crate::config::HostPaths::from_home(directory.path().canonicalize().unwrap()).unwrap();
        let (source, known) = VisualDownloadRequest {
            visual_digest: "a".repeat(64),
            known_revision: None,
        }
        .resolve(&paths)
        .unwrap();
        assert!(matches!(
            FileDownloads::default()
                .download_source(source, known)
                .await,
            Err(DownloadError::Missing)
        ));
        assert!(!paths.state_directory().exists());
    }

    #[tokio::test]
    async fn visual_downloads_resolve_owned_store_and_enforce_cap_before_cached_response() {
        let directory = tempfile::tempdir().unwrap();
        let paths =
            crate::config::HostPaths::from_home(directory.path().canonicalize().unwrap()).unwrap();
        let root = paths.state("visuals");
        std::fs::create_dir_all(&root).unwrap();
        let digest = "a".repeat(64);
        let path = root.join(format!("{digest}.html"));
        std::fs::write(&path, b"<p>visual</p>").unwrap();
        let downloads = FileDownloads::default();
        let (source, known) = VisualDownloadRequest {
            visual_digest: digest.clone(),
            known_revision: None,
        }
        .resolve(&paths)
        .unwrap();
        let response = downloads.download_source(source, known).await.unwrap();
        assert_eq!(metadata(&response)["name"], format!("{digest}.html"));
        assert_eq!(
            axum::body::to_bytes(response.into_body(), 100)
                .await
                .unwrap()
                .as_ref(),
            b"<p>visual</p>"
        );
        await_released(&downloads).await;
        File::options()
            .write(true)
            .open(&path)
            .unwrap()
            .set_len(crate::storage::visuals::MAX_HTML_BYTES as u64)
            .unwrap();
        let (source, known) = VisualDownloadRequest {
            visual_digest: digest.clone(),
            known_revision: None,
        }
        .resolve(&paths)
        .unwrap();
        let response = downloads.download_source(source, known).await.unwrap();
        assert_eq!(
            axum::body::to_bytes(
                response.into_body(),
                crate::storage::visuals::MAX_HTML_BYTES
            )
            .await
            .unwrap()
            .len(),
            crate::storage::visuals::MAX_HTML_BYTES
        );
        await_released(&downloads).await;
        File::options()
            .write(true)
            .open(&path)
            .unwrap()
            .set_len(crate::storage::visuals::MAX_HTML_BYTES as u64 + 1)
            .unwrap();
        let revision = revision(&std::fs::metadata(&path).unwrap());
        for known_revision in [None, Some(revision)] {
            let (source, known) = VisualDownloadRequest {
                visual_digest: digest.clone(),
                known_revision,
            }
            .resolve(&paths)
            .unwrap();
            assert!(matches!(
                downloads.download_source(source, known).await,
                Err(DownloadError::TooLarge)
            ));
            await_released(&downloads).await;
        }
    }

    #[tokio::test]
    async fn visual_downloads_reject_file_store_and_ancestor_symlinks() {
        let directory = tempfile::tempdir().unwrap();
        let home = directory.path().canonicalize().unwrap();
        let root = home.join(".remote-coder/visuals");
        std::fs::create_dir_all(&root).unwrap();
        let digest = "a".repeat(64);
        let downloads = FileDownloads::default();
        let paths = crate::config::HostPaths::from_home(home.clone()).unwrap();
        let outside = home.join("outside.html");
        std::fs::write(&outside, b"private").unwrap();
        let path = root.join(format!("{digest}.html"));
        symlink(&outside, &path).unwrap();
        let (source, known) = VisualDownloadRequest {
            visual_digest: digest.clone(),
            known_revision: Some(revision(&std::fs::metadata(&outside).unwrap())),
        }
        .resolve(&paths)
        .unwrap();
        assert!(matches!(
            downloads.download_source(source, known).await,
            Err(DownloadError::AccessDenied)
        ));
        await_released(&downloads).await;
        std::fs::remove_file(&path).unwrap();
        std::fs::remove_dir(&root).unwrap();
        symlink(&home, &root).unwrap();
        let (source, known) = VisualDownloadRequest {
            visual_digest: digest.clone(),
            known_revision: Some(revision(&std::fs::metadata(&outside).unwrap())),
        }
        .resolve(&paths)
        .unwrap();
        assert!(matches!(
            downloads.download_source(source, known).await,
            Err(DownloadError::AccessDenied)
        ));
        await_released(&downloads).await;
        std::fs::remove_file(&root).unwrap();
        std::fs::remove_dir(home.join(".remote-coder")).unwrap();
        symlink(&home, home.join(".remote-coder")).unwrap();
        let (source, known) = VisualDownloadRequest {
            visual_digest: digest.clone(),
            known_revision: Some(revision(&std::fs::metadata(&outside).unwrap())),
        }
        .resolve(&paths)
        .unwrap();
        assert!(matches!(
            downloads.download_source(source, known).await,
            Err(DownloadError::AccessDenied)
        ));
        await_released(&downloads).await;
    }

    #[tokio::test]
    async fn scoped_downloads_admit_nested_files_and_contained_symlinks_but_reject_escapes() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().join("report");
        std::fs::create_dir_all(root.join("assets")).unwrap();
        let asset = root.join("assets/style.css");
        std::fs::write(&asset, b"body{}").unwrap();
        let outside = directory.path().join("private.txt");
        std::fs::write(&outside, b"private").unwrap();
        symlink(&asset, root.join("style.css")).unwrap();
        symlink(&outside, root.join("escape.txt")).unwrap();
        symlink(directory.path(), root.join("escape-directory")).unwrap();
        let downloads = FileDownloads::default();
        for path in [&asset, &root.join("style.css")] {
            let mut scoped = request(path, None);
            let DownloadRequest::File(ref mut file) = scoped else {
                unreachable!()
            };
            file.containing_directory = Some(root.to_str().unwrap().to_owned());
            let response = downloads.download(scoped).await.unwrap();
            assert_eq!(
                axum::body::to_bytes(response.into_body(), 100)
                    .await
                    .unwrap()
                    .as_ref(),
                b"body{}"
            );
            await_released(&downloads).await;
        }
        for path in [
            outside.clone(),
            root.join("../private.txt"),
            root.join("escape.txt"),
            root.join("escape-directory/private.txt"),
        ] {
            let mut scoped = request(&path, Some(revision(&std::fs::metadata(&outside).unwrap())));
            let DownloadRequest::File(ref mut file) = scoped else {
                unreachable!()
            };
            file.containing_directory = Some(root.to_str().unwrap().to_owned());
            assert_eq!(
                downloads.download(scoped).await.unwrap_err().kind(),
                "accessDenied"
            );
            await_released(&downloads).await;
        }
    }

    #[tokio::test]
    async fn returns_exact_bytes_and_unicode_metadata_without_provider_access() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("år 2026:42 #%.bin");
        let bytes: Vec<u8> = (0..CHUNK_BYTES * 3 + 17).map(|value| value as u8).collect();
        std::fs::write(&path, &bytes).unwrap();
        let downloads = FileDownloads::default();

        let response = downloads.download(request(&path, None)).await.unwrap();
        let metadata = metadata(&response);
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response.headers()[header::CONTENT_LENGTH],
            bytes.len().to_string()
        );
        assert_eq!(
            response.headers()[header::CONTENT_TYPE],
            "application/octet-stream"
        );
        assert_eq!(metadata["name"], "år 2026:42 #%.bin");
        assert_eq!(metadata["path"], path.to_str().unwrap());
        assert_eq!(metadata["bytes"], bytes.len());
        assert!(metadata["modifiedAt"].as_f64().unwrap() > 0.0);
        let body = axum::body::to_bytes(response.into_body(), bytes.len())
            .await
            .unwrap();
        assert_eq!(body.as_ref(), bytes);
        await_released(&downloads).await;
    }

    #[tokio::test]
    async fn empty_files_are_successful_and_revalidate_with_a_bodyless_204() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("empty.txt");
        std::fs::write(&path, []).unwrap();
        let downloads = FileDownloads::default();

        let response = downloads.download(request(&path, None)).await.unwrap();
        let original = metadata(&response);
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.headers()[header::CONTENT_LENGTH], "0");
        assert!(
            axum::body::to_bytes(response.into_body(), 1)
                .await
                .unwrap()
                .is_empty()
        );
        let response = downloads
            .download(request(
                &path,
                Some(original["revision"].as_str().unwrap().to_string()),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NO_CONTENT);
        assert_eq!(metadata(&response), original);
        assert!(
            axum::body::to_bytes(response.into_body(), 1)
                .await
                .unwrap()
                .is_empty()
        );
        await_released(&downloads).await;
    }

    #[tokio::test]
    async fn a_changed_revision_downloads_new_bytes_and_keeps_the_symlink_name() {
        let directory = tempfile::tempdir().unwrap();
        let target = directory.path().join("target.bin");
        let alias = directory.path().join("original name.txt");
        std::fs::write(&target, b"before").unwrap();
        symlink(&target, &alias).unwrap();
        let downloads = FileDownloads::default();
        let response = downloads.download(request(&alias, None)).await.unwrap();
        let before = metadata(&response);
        axum::body::to_bytes(response.into_body(), 100)
            .await
            .unwrap();
        await_released(&downloads).await;
        std::fs::write(&target, b"after saving").unwrap();

        let response = downloads
            .download(request(
                &alias,
                Some(before["revision"].as_str().unwrap().to_string()),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(metadata(&response)["name"], "original name.txt");
        assert_eq!(metadata(&response)["path"], alias.to_str().unwrap());
        assert_ne!(metadata(&response)["revision"], before["revision"]);
        assert_eq!(
            axum::body::to_bytes(response.into_body(), 100)
                .await
                .unwrap()
                .as_ref(),
            b"after saving"
        );
        await_released(&downloads).await;
    }

    #[tokio::test]
    async fn rejects_missing_directories_devices_fifos_and_oversized_files() {
        let directory = tempfile::tempdir().unwrap();
        let fifo = directory.path().join("fifo");
        nix::unistd::mkfifo(&fifo, nix::sys::stat::Mode::S_IRUSR).unwrap();
        let large = directory.path().join("large.bin");
        File::create(&large)
            .unwrap()
            .set_len(MAX_FILE_BYTES + 1)
            .unwrap();
        let downloads = FileDownloads::default();

        for (path, kind) in [
            (directory.path().join("missing"), "missing"),
            (directory.path().to_path_buf(), "notFile"),
            (PathBuf::from("/dev/null"), "notFile"),
            (fifo, "notFile"),
            (large, "tooLarge"),
        ] {
            let error = tokio::time::timeout(
                Duration::from_secs(2),
                downloads.download(request(&path, None)),
            )
            .await
            .expect("FIFO open must not block")
            .unwrap_err();
            assert_eq!(error.kind(), kind);
            await_released(&downloads).await;
        }
        await_released(&downloads).await;
    }

    #[tokio::test]
    async fn file_access_denial_is_distinct_from_gateway_authorization() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("private.txt");
        std::fs::write(&path, b"private").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o0)).unwrap();
        let downloads = FileDownloads::default();
        let result = downloads.download(request(&path, None)).await;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(result.unwrap_err().kind(), "accessDenied");
        await_released(&downloads).await;
    }

    #[test]
    fn validates_absolute_paths_without_decoding_filename_characters() {
        assert_eq!(
            normalized_path("/tmp/a/../x%20 y:12#L1").unwrap(),
            Path::new("/tmp/x%20 y:12#L1")
        );
        for path in ["relative.txt", "file:///tmp/a", "/../../a", "/tmp/\0bad"] {
            assert_eq!(normalized_path(path).unwrap_err().kind(), "invalidPath");
        }
        assert_eq!(
            normalized_path(&format!("/{}", "a".repeat(4096)))
                .unwrap_err()
                .kind(),
            "invalidPath"
        );
    }

    #[test]
    fn detects_in_place_growth_truncation_and_same_length_rewrites() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("changing.bin");
        for (label, replacement) in [
            ("growth", vec![2; CHUNK_BYTES + 11]),
            ("truncation", vec![1; 5]),
        ] {
            std::fs::write(&path, vec![1; CHUNK_BYTES + 10]).unwrap();
            let mut source = FileSource::open(path.clone()).unwrap();
            assert_eq!(source.read_chunk().unwrap().unwrap().len(), CHUNK_BYTES);
            std::fs::write(&path, replacement).unwrap();
            assert_eq!(
                source.read_chunk().unwrap_err().kind(),
                "changed",
                "{label}"
            );
        }
        std::fs::write(&path, b"before").unwrap();
        let mut source = FileSource::open(path.clone()).unwrap();
        std::fs::write(&path, b"after!").unwrap();
        File::options()
            .write(true)
            .open(&path)
            .unwrap()
            .set_modified(std::time::UNIX_EPOCH + Duration::from_secs(1))
            .unwrap();
        assert_eq!(
            source.read_chunk().unwrap_err().kind(),
            "changed",
            "same length"
        );
    }

    #[tokio::test]
    async fn a_streaming_mutation_never_delivers_the_declared_length() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("changing.bin");
        std::fs::write(&path, vec![1; CHUNK_BYTES * 8]).unwrap();
        let downloads = FileDownloads::default();
        let response = downloads.download(request(&path, None)).await.unwrap();
        let mut stream = response.into_body().into_data_stream();
        let mut received = stream.next().await.unwrap().unwrap().len();
        File::options()
            .write(true)
            .open(&path)
            .unwrap()
            .set_len(1)
            .unwrap();
        let mut failed = false;
        while let Some(chunk) = stream.next().await {
            match chunk {
                Ok(chunk) => received += chunk.len(),
                Err(_) => {
                    failed = true;
                    break;
                }
            }
        }
        assert!(failed);
        assert!(received < CHUNK_BYTES * 8);
        drop(stream);
        await_released(&downloads).await;
    }

    #[tokio::test]
    async fn a_mutation_while_the_tail_waits_for_capacity_interrupts_the_body() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("changing.bin");
        std::fs::write(&path, vec![1; CHUNK_BYTES * 2]).unwrap();
        let downloads = FileDownloads::default();
        let response = downloads.download(request(&path, None)).await.unwrap();
        File::options()
            .write(true)
            .open(&path)
            .unwrap()
            .set_len((CHUNK_BYTES * 2 + 1) as u64)
            .unwrap();

        let mut stream = response.into_body().into_data_stream();
        let mut received = 0;
        let mut failed = false;
        while let Some(chunk) = stream.next().await {
            match chunk {
                Ok(chunk) => received += chunk.len(),
                Err(_) => {
                    failed = true;
                    break;
                }
            }
        }
        assert!(failed);
        assert!(received <= CHUNK_BYTES);
        drop(stream);
        await_released(&downloads).await;
    }

    #[tokio::test]
    async fn body_cancellation_releases_the_two_transfer_slots() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("large.bin");
        std::fs::write(&path, vec![1; CHUNK_BYTES * 8]).unwrap();
        let downloads = FileDownloads::default();
        let first = downloads.download(request(&path, None)).await.unwrap();
        let second = downloads.download(request(&path, None)).await.unwrap();
        assert_eq!(
            downloads
                .download(request(&path, None))
                .await
                .unwrap_err()
                .kind(),
            "busy"
        );

        drop(first);
        drop(second);
        await_released(&downloads).await;
        let response = downloads.download(request(&path, None)).await.unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        drop(response);
        await_released(&downloads).await;
    }

    #[tokio::test]
    async fn unpolled_response_stalls_release_resources_for_large_and_small_files() {
        let directory = tempfile::tempdir().unwrap();
        let downloads = FileDownloads {
            body_stall_timeout: Duration::ZERO,
            ..FileDownloads::default()
        };
        for length in [1, CHUNK_BYTES * 8] {
            let path = directory.path().join(format!("{length}.bin"));
            std::fs::write(&path, vec![1; length]).unwrap();
            let response = downloads.download(request(&path, None)).await.unwrap();
            await_released(&downloads).await;
            drop(response);
        }
    }

    #[tokio::test]
    async fn draining_cancels_active_bodies_and_rejects_new_downloads() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("large.bin");
        std::fs::write(&path, vec![1; CHUNK_BYTES * 8]).unwrap();
        let downloads = FileDownloads::default();
        let response = downloads.download(request(&path, None)).await.unwrap();
        downloads.drain();
        await_released(&downloads).await;
        assert_eq!(
            downloads
                .download(request(&path, None))
                .await
                .unwrap_err()
                .kind(),
            "draining"
        );
        let body = axum::body::to_bytes(response.into_body(), CHUNK_BYTES * 8)
            .await
            .unwrap();
        assert!(body.len() < CHUNK_BYTES * 8);
    }
}
