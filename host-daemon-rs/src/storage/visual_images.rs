use std::ffi::OsStr;
use std::fmt;
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use nix::errno::Errno;
use nix::sys::signal::kill;
use nix::unistd::Pid;
use tokio::io::AsyncReadExt;
use tokio::process::Command;
use tokio::sync::{Semaphore, SemaphorePermit};
use tokio::time::{Instant, timeout_at};

use super::no_follow::Root;
use super::visuals::MAX_HTML_BYTES;
use crate::config::HostPaths;

const SIPS: &str = "/usr/bin/sips";
const SIPS_TIMEOUT: Duration = Duration::from_secs(10);
const SIPS_OUTPUT_BYTES: u64 = 64 * 1024;
const MAX_SOURCE_BYTES: u64 = 64 * 1024 * 1024;
const MAX_SOURCE_PIXELS: u64 = 64_000_000;
const MAX_WIDTH: u64 = 1_600;
const MAX_AREA: u64 = 4_000_000;
const JPEG_QUALITY: &str = "80";
const PASS_THROUGH_BYTES: u64 = 512 * 1024;
const WAITING_PUBLICATIONS: usize = 4;
const STAGING_ENTRIES: usize = 256;
static PREPARATION: Semaphore = Semaphore::const_new(1);
static ADMISSION: Semaphore = Semaphore::const_new(WAITING_PUBLICATIONS);

pub(super) struct EmbeddedImage {
    pub(super) mime: &'static str,
    pub(super) bytes: Vec<u8>,
    pub(super) converted: bool,
}

#[derive(Debug)]
pub(super) enum ImageError {
    File(String),
    Unsupported(String),
    TooLarge,
    Timeout,
    Sips(String),
    Staging(String),
    Busy,
}

impl ImageError {
    pub(super) fn category(&self) -> &'static str {
        match self {
            ImageError::File(_) => "image_file",
            ImageError::Unsupported(_) => "unsupported_image",
            ImageError::TooLarge => "budget",
            ImageError::Timeout => "timeout",
            ImageError::Sips(_) => "sips",
            ImageError::Staging(_) => "staging",
            ImageError::Busy => "capacity",
        }
    }
}

impl fmt::Display for ImageError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ImageError::File(reason) | ImageError::Unsupported(reason) => {
                formatter.write_str(reason)
            }
            ImageError::TooLarge => write!(
                formatter,
                "still larger than {MAX_HTML_BYTES} bytes after downscaling"
            ),
            ImageError::Timeout => formatter.write_str("timed out"),
            ImageError::Sips(reason) => write!(formatter, "could not run sips: {reason}"),
            ImageError::Staging(reason) => write!(formatter, "could not stage the image: {reason}"),
            ImageError::Busy => {
                formatter.write_str("other visuals are already embedding images; try again shortly")
            }
        }
    }
}

pub(super) struct Admission {
    _permit: SemaphorePermit<'static>,
}

impl Admission {
    pub(super) fn try_new() -> Option<Self> {
        ADMISSION
            .try_acquire()
            .ok()
            .map(|permit| Self { _permit: permit })
    }
}

pub(super) struct Preparation {
    scratch: Scratch,
    _permit: SemaphorePermit<'static>,
}

impl Preparation {
    pub(super) async fn admit(
        _admission: &Admission,
        paths: &HostPaths,
        deadline: Instant,
    ) -> Result<Arc<Self>, ImageError> {
        let permit = timeout_at(deadline, PREPARATION.acquire())
            .await
            .map_err(|_| ImageError::Busy)?
            .map_err(|_| ImageError::Busy)?;
        let home = paths.home().to_owned();
        let staging = paths.state("visual-staging");
        tokio::task::spawn_blocking(move || {
            let scratch = Scratch::create(&home, &staging)
                .map_err(|error| ImageError::Staging(format!("{error:#}")))?;
            Ok(Arc::new(Self {
                scratch,
                _permit: permit,
            }))
        })
        .await
        .map_err(|error| ImageError::Staging(error.to_string()))?
    }

    pub(super) async fn prepare(
        self: &Arc<Self>,
        source: &Path,
        deadline: Instant,
    ) -> Result<EmbeddedImage, ImageError> {
        let snapshot = self.scratch.path.join("source");
        let output = self.scratch.path.join("output");
        let result = self
            .prepare_in_scratch(source, &snapshot, &output, deadline)
            .await;
        for path in [&snapshot, &output] {
            if let Err(error) = tokio::fs::remove_file(path).await
                && error.kind() != io::ErrorKind::NotFound
            {
                tracing::warn!(path = %path.display(), %error, "could not remove visual image scratch file");
            }
        }
        result
    }

    async fn prepare_in_scratch(
        self: &Arc<Self>,
        source: &Path,
        snapshot: &Path,
        output: &Path,
        deadline: Instant,
    ) -> Result<EmbeddedImage, ImageError> {
        let owner = Arc::clone(self);
        let (from, to) = (source.to_owned(), snapshot.to_owned());
        let copy = tokio::task::spawn_blocking(move || {
            let _owner = owner;
            let copied = copy_source(&from, &to)?;
            let rotated_png =
                png_swaps_axes(&to).map_err(|error| ImageError::Staging(error.to_string()))?;
            Ok((copied, rotated_png))
        });
        let (copied, rotated_png) = timeout_at(deadline, copy)
            .await
            .map_err(|_| ImageError::Timeout)?
            .map_err(|error| ImageError::File(error.to_string()))??;
        let probe = Probe::parse(
            &self
                .sips(
                    [
                        "-g",
                        "format",
                        "-g",
                        "hasAlpha",
                        "-g",
                        "pixelWidth",
                        "-g",
                        "pixelHeight",
                    ]
                    .map(OsStr::new)
                    .into_iter()
                    .chain([snapshot.as_os_str()])
                    .collect(),
                    deadline,
                )
                .await?,
        )?;
        let target = probe.target(rotated_png);
        let format = if probe.alpha { "png" } else { "jpeg" };
        let mut arguments = ["-s", "format", format].map(OsStr::new).to_vec();
        if !probe.alpha {
            arguments.extend(["-s", "formatOptions", JPEG_QUALITY].map(OsStr::new));
        }
        let size = target.map(|(width, height)| (height.to_string(), width.to_string()));
        if let Some((height, width)) = &size {
            arguments.extend([OsStr::new("-z"), OsStr::new(height), OsStr::new(width)]);
        }
        arguments.extend([
            snapshot.as_os_str(),
            OsStr::new("--out"),
            output.as_os_str(),
        ]);
        self.sips(arguments, deadline).await?;
        let pass_through = target.is_none() && copied <= PASS_THROUGH_BYTES;
        if pass_through && let Some(mime) = probe.original_mime() {
            return Ok(EmbeddedImage {
                mime,
                bytes: read_bounded(snapshot, PASS_THROUGH_BYTES).await?,
                converted: false,
            });
        }
        Ok(EmbeddedImage {
            mime: if probe.alpha {
                "image/png"
            } else {
                "image/jpeg"
            },
            bytes: read_bounded(output, MAX_HTML_BYTES as u64).await?,
            converted: true,
        })
    }

    async fn sips(
        self: &Arc<Self>,
        arguments: Vec<&OsStr>,
        deadline: Instant,
    ) -> Result<Vec<u8>, ImageError> {
        let mut command = Command::new(SIPS);
        command
            .args(arguments)
            .env("TMPDIR", &self.scratch.path)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        let owner = Arc::clone(self);
        let limit = deadline.min(Instant::now() + SIPS_TIMEOUT);
        tokio::spawn(async move {
            let _owner = owner;
            run_child(command, limit).await
        })
        .await
        .map_err(|error| ImageError::Sips(error.to_string()))?
    }
}

async fn run_child(mut command: Command, limit: Instant) -> Result<Vec<u8>, ImageError> {
    let mut child = command
        .spawn()
        .map_err(|error| ImageError::Sips(error.to_string()))?;
    let mut stdout = child
        .stdout
        .take()
        .ok_or_else(|| ImageError::Sips("standard output was not captured".into()))?;
    let finished = timeout_at(limit, async {
        let mut output = Vec::new();
        (&mut stdout)
            .take(SIPS_OUTPUT_BYTES)
            .read_to_end(&mut output)
            .await?;
        let status = child.wait().await?;
        io::Result::Ok((status, output))
    })
    .await;
    match finished {
        Ok(Ok((status, output))) if status.success() => Ok(output),
        Ok(Ok(_)) => Err(ImageError::Unsupported(
            "macOS could not decode it as an image".into(),
        )),
        Ok(Err(error)) => Err(ImageError::Sips(error.to_string())),
        Err(_) => {
            if let Err(error) = child.kill().await {
                tracing::warn!(%error, "could not stop a timed-out sips process");
            }
            Err(ImageError::Timeout)
        }
    }
}

#[derive(Debug, PartialEq)]
struct Probe {
    format: String,
    alpha: bool,
    width: u64,
    height: u64,
}

impl Probe {
    fn parse(output: &[u8]) -> Result<Self, ImageError> {
        let unreadable = || ImageError::Unsupported("macOS could not read it as an image".into());
        let text = std::str::from_utf8(output).map_err(|_| unreadable())?;
        let fields = text
            .lines()
            .filter_map(|line| line.strip_prefix("  ")?.split_once(": "))
            .collect::<Vec<_>>();
        let field = |name: &str| {
            fields
                .iter()
                .find(|(key, _)| *key == name)
                .map(|(_, value)| value.trim())
                .filter(|value| *value != "<nil>")
                .ok_or_else(unreadable)
        };
        let format = fields
            .iter()
            .find(|(key, _)| *key == "format")
            .map(|(_, value)| value.trim().to_owned())
            .ok_or_else(unreadable)?;
        if !matches!(
            format.as_str(),
            "png" | "jpeg" | "gif" | "heic" | "heif" | "tiff" | "webp" | "bmp"
        ) {
            return Err(ImageError::Unsupported(
                "not a PNG, JPEG, GIF, HEIC, TIFF, WebP or BMP image".into(),
            ));
        }
        let alpha = field("hasAlpha")? == "yes";
        let (Ok(width), Ok(height)) = (
            field("pixelWidth")?.parse::<u64>(),
            field("pixelHeight")?.parse::<u64>(),
        ) else {
            return Err(unreadable());
        };
        if width == 0 || height == 0 {
            return Err(unreadable());
        }
        if width.saturating_mul(height) > MAX_SOURCE_PIXELS {
            return Err(ImageError::Unsupported(format!(
                "{width}×{height} pixels is over the {MAX_SOURCE_PIXELS}-pixel limit"
            )));
        }
        Ok(Self {
            format,
            alpha,
            width,
            height,
        })
    }

    fn target(&self, rotated_png: bool) -> Option<(u64, u64)> {
        let (width, height) = (self.width as f64, self.height as f64);
        let displayed_width = if self.may_rotate(rotated_png) {
            width.max(height)
        } else {
            width
        };
        let scale =
            (MAX_WIDTH as f64 / displayed_width).min((MAX_AREA as f64 / (width * height)).sqrt());
        (scale < 1.0).then(|| {
            (
                ((width * scale + 1e-6).floor() as u64).max(1),
                ((height * scale + 1e-6).floor() as u64).max(1),
            )
        })
    }

    fn may_rotate(&self, rotated_png: bool) -> bool {
        match self.format.as_str() {
            "gif" | "bmp" => false,
            "png" => rotated_png,
            _ => true,
        }
    }

    fn original_mime(&self) -> Option<&'static str> {
        match self.format.as_str() {
            "png" => Some("image/png"),
            "jpeg" => Some("image/jpeg"),
            "gif" => Some("image/gif"),
            _ => None,
        }
    }
}

fn png_swaps_axes(path: &Path) -> io::Result<bool> {
    let mut file = File::open(path)?;
    let mut signature = [0; 8];
    if file.read_exact(&mut signature).is_err() || signature != *b"\x89PNG\r\n\x1a\n" {
        return Ok(false);
    }
    let mut header = [0; 8];
    while file.read_exact(&mut header).is_ok() {
        let length = u32::from_be_bytes([header[0], header[1], header[2], header[3]]);
        match &header[4..] {
            b"eXIf" => {
                let mut exif = Vec::new();
                (&mut file).take(u64::from(length)).read_to_end(&mut exif)?;
                return Ok(exif_swaps_axes(&exif));
            }
            b"IEND" => break,
            _ => {
                file.seek(SeekFrom::Current(i64::from(length) + 4))?;
            }
        }
    }
    Ok(false)
}

fn exif_swaps_axes(exif: &[u8]) -> bool {
    let big_endian = match exif.get(..4) {
        Some(b"MM\0*") => true,
        Some(b"II*\0") => false,
        _ => return false,
    };
    let read = |offset: usize, size: usize| -> Option<u32> {
        let bytes = exif.get(offset..offset.checked_add(size)?)?;
        Some(bytes.iter().enumerate().fold(0, |value, (index, byte)| {
            let shift = if big_endian { size - 1 - index } else { index } * 8;
            value | u32::from(*byte) << shift
        }))
    };
    let Some(directory) = read(4, 4).map(|offset| offset as usize) else {
        return false;
    };
    let entries = read(directory, 2).unwrap_or(0) as usize;
    (0..entries)
        .filter_map(|entry| directory.checked_add(2 + entry * 12))
        .find(|&entry| read(entry, 2) == Some(0x0112))
        .and_then(|entry| read(entry + 8, 2))
        .is_some_and(|orientation| (5..=8).contains(&orientation))
}

fn copy_source(source: &Path, target: &Path) -> Result<u64, ImageError> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(source)
        .map_err(|error| ImageError::File(file_error(&error)))?;
    let metadata = file
        .metadata()
        .map_err(|error| ImageError::File(file_error(&error)))?;
    if !metadata.is_file() {
        return Err(ImageError::File("not a regular file".into()));
    }
    let too_large = || ImageError::File(format!("larger than {MAX_SOURCE_BYTES} bytes"));
    if metadata.len() > MAX_SOURCE_BYTES {
        return Err(too_large());
    }
    let mut copy = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(target)
        .map_err(|error| ImageError::Staging(error.to_string()))?;
    let copied = io::copy(&mut file.take(MAX_SOURCE_BYTES + 1), &mut copy)
        .map_err(|error| ImageError::File(file_error(&error)))?;
    if copied > MAX_SOURCE_BYTES {
        return Err(too_large());
    }
    Ok(copied)
}

fn file_error(error: &io::Error) -> String {
    match error.kind() {
        io::ErrorKind::NotFound => "file not found".into(),
        io::ErrorKind::PermissionDenied => "permission denied".into(),
        _ if error.raw_os_error() == Some(libc::ELOOP) => "is a symbolic link".into(),
        _ => error.to_string(),
    }
}

async fn read_bounded(path: &Path, limit: u64) -> Result<Vec<u8>, ImageError> {
    let file = tokio::fs::File::open(path)
        .await
        .map_err(|error| ImageError::Staging(error.to_string()))?;
    let mut bytes = Vec::new();
    file.take(limit + 1)
        .read_to_end(&mut bytes)
        .await
        .map_err(|error| ImageError::Staging(error.to_string()))?;
    if bytes.len() as u64 > limit {
        return Err(ImageError::TooLarge);
    }
    Ok(bytes)
}

struct Scratch {
    root: Root,
    path: PathBuf,
}

impl Scratch {
    fn create(home: &Path, staging: &Path) -> Result<Self> {
        let root = Root::open(home)?;
        root.ensure_directory(staging)?;
        let own = std::process::id();
        for name in root.read_directory_bounded(staging, STAGING_ENTRIES)? {
            let path = staging.join(&name);
            let abandoned = name
                .to_str()
                .and_then(|name| name.parse::<u32>().ok())
                .is_none_or(|pid| pid == own || !process_alive(pid));
            if abandoned {
                root.remove_tree(&path).with_context(|| {
                    format!("reclaiming abandoned image staging {}", path.display())
                })?;
            }
        }
        let path = staging.join(own.to_string());
        root.ensure_directory(&path)?;
        Ok(Self { root, path })
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        if let Err(error) = self.root.remove_tree(&self.path) {
            tracing::warn!(path = %self.path.display(), error = format!("{error:#}"), "could not remove visual image staging");
        }
    }
}

fn process_alive(pid: u32) -> bool {
    let Ok(pid) = i32::try_from(pid) else {
        return false;
    };
    pid > 0 && kill(Pid::from_raw(pid), None).map_or_else(|errno| errno != Errno::ESRCH, |()| true)
}

#[cfg(test)]
pub(super) mod test_images {
    pub(in crate::storage) static SERIAL: tokio::sync::Mutex<()> =
        tokio::sync::Mutex::const_new(());

    pub(in crate::storage) fn png(width: u32, height: u32, alpha: bool) -> Vec<u8> {
        let mut raw = Vec::new();
        for y in 0..height {
            raw.push(0);
            for x in 0..width {
                raw.extend([(x % 256) as u8, (y % 256) as u8, 128]);
                if alpha {
                    raw.push(if x % 2 == 0 { 255 } else { 96 });
                }
            }
        }
        let mut zlib = vec![0x78, 0x01];
        let blocks = raw.chunks(65_535).collect::<Vec<_>>();
        for (index, block) in blocks.iter().enumerate() {
            zlib.push(u8::from(index + 1 == blocks.len()));
            let length = block.len() as u16;
            zlib.extend(length.to_le_bytes());
            zlib.extend((!length).to_le_bytes());
            zlib.extend_from_slice(block);
        }
        let (mut a, mut b) = (1u32, 0u32);
        for byte in &raw {
            a = (a + u32::from(*byte)) % 65_521;
            b = (b + a) % 65_521;
        }
        zlib.extend(((b << 16) | a).to_be_bytes());
        let mut header = Vec::new();
        header.extend(width.to_be_bytes());
        header.extend(height.to_be_bytes());
        header.extend([8, if alpha { 6 } else { 2 }, 0, 0, 0]);
        let mut png = b"\x89PNG\r\n\x1a\n".to_vec();
        for (kind, data) in [(b"IHDR", header), (b"IDAT", zlib), (b"IEND", Vec::new())] {
            png.extend((data.len() as u32).to_be_bytes());
            let start = png.len();
            png.extend_from_slice(kind);
            png.extend(&data);
            let crc = png[start..].iter().fold(!0u32, |crc, byte| {
                (0..8).fold(crc ^ u32::from(*byte), |crc, _| {
                    if crc & 1 == 1 {
                        (crc >> 1) ^ 0xEDB8_8320
                    } else {
                        crc >> 1
                    }
                })
            });
            png.extend((!crc).to_be_bytes());
        }
        png
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn probe(format: &str, alpha: bool, width: u64, height: u64) -> Probe {
        Probe {
            format: format.into(),
            alpha,
            width,
            height,
        }
    }

    async fn sips_size(bytes: &[u8]) -> (u64, u64) {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("image");
        std::fs::write(&path, bytes).unwrap();
        let output = Command::new(SIPS)
            .args([
                "-g",
                "format",
                "-g",
                "hasAlpha",
                "-g",
                "pixelWidth",
                "-g",
                "pixelHeight",
            ])
            .arg(&path)
            .output()
            .await
            .unwrap();
        let probe = Probe::parse(&output.stdout).unwrap();
        (probe.width, probe.height)
    }

    #[test]
    fn probes_require_complete_raster_metadata_within_the_pixel_ceiling() {
        let parse = |text: &str| Probe::parse(text.as_bytes());
        assert_eq!(
            parse("/s/source\n  format: png\n  hasAlpha: yes\n  pixelWidth: 1570\n  pixelHeight: 366\n").unwrap(),
            probe("png", true, 1570, 366)
        );
        for (text, reason) in [
            (
                "/s/source\n  format: \n  hasAlpha: no\n  pixelWidth: <nil>\n  pixelHeight: <nil>\n",
                "not a PNG",
            ),
            (
                "/s/source\n  format: svg\n  hasAlpha: no\n  pixelWidth: 10.000\n  pixelHeight: 10.000\n",
                "not a PNG",
            ),
            (
                "/s/source\n  format: pdf\n  hasAlpha: yes\n  pixelWidth: 785.000\n  pixelHeight: 183.000\n",
                "not a PNG",
            ),
            (
                "/s/source\n  format: png\n  hasAlpha: yes\n  pixelWidth: <nil>\n  pixelHeight: 366\n",
                "could not read",
            ),
            (
                "/s/source\n  format: png\n  hasAlpha: yes\n  pixelWidth: 0\n  pixelHeight: 366\n",
                "could not read",
            ),
            (
                "/s/source\n  format: png\n  hasAlpha: yes\n  pixelWidth: 10000\n  pixelHeight: 6401\n",
                "pixel limit",
            ),
            ("/s/source\n  format: png\n", "could not read"),
        ] {
            let error = parse(text).unwrap_err().to_string();
            assert!(error.contains(reason), "{text}: {error}");
        }
    }

    #[test]
    fn png_exif_orientation_decides_whether_axes_swap() {
        let exif = |big_endian: bool, orientation: u16| {
            let u16_bytes = |value: u16| {
                if big_endian {
                    value.to_be_bytes()
                } else {
                    value.to_le_bytes()
                }
            };
            let u32_bytes = |value: u32| {
                if big_endian {
                    value.to_be_bytes()
                } else {
                    value.to_le_bytes()
                }
            };
            let mut bytes = if big_endian {
                b"MM\0*".to_vec()
            } else {
                b"II*\0".to_vec()
            };
            bytes.extend(u32_bytes(8));
            bytes.extend(u16_bytes(2));
            for (tag, value) in [(0x0110, 0), (0x0112, orientation)] {
                bytes.extend(u16_bytes(tag));
                bytes.extend(u16_bytes(3));
                bytes.extend(u32_bytes(1));
                bytes.extend(u16_bytes(value));
                bytes.extend([0, 0]);
            }
            bytes
        };
        assert!(exif_swaps_axes(&exif(true, 6)));
        assert!(exif_swaps_axes(&exif(false, 8)));
        assert!(!exif_swaps_axes(&exif(false, 3)));
        assert!(!exif_swaps_axes(&exif(true, 6)[..20]));
        assert!(!exif_swaps_axes(b"not exif"));

        let directory = tempfile::tempdir().unwrap();
        let write = |name: &str, chunk: Option<Vec<u8>>| {
            let mut png = test_images::png(10, 30, false);
            if let Some(data) = chunk {
                let mut inserted = (data.len() as u32).to_be_bytes().to_vec();
                inserted.extend(b"eXIf");
                inserted.extend(&data);
                inserted.extend([0; 4]);
                png.splice(33..33, inserted);
            }
            let path = directory.path().join(name);
            std::fs::write(&path, png).unwrap();
            path
        };
        assert!(png_swaps_axes(&write("rotated.png", Some(exif(false, 6)))).unwrap());
        assert!(!png_swaps_axes(&write("upright.png", Some(exif(false, 1)))).unwrap());
        assert!(!png_swaps_axes(&write("plain.png", None)).unwrap());
        let text = directory.path().join("notes.txt");
        std::fs::write(&text, b"plain text").unwrap();
        assert!(!png_swaps_axes(&text).unwrap());
    }

    #[test]
    fn targets_keep_width_and_area_within_the_display_policy() {
        assert_eq!(probe("png", false, 1200, 800).target(false), None);
        assert_eq!(
            probe("png", false, 3200, 1000).target(false),
            Some((1600, 500))
        );
        assert_eq!(
            probe("png", true, 1170, 25_320).target(false),
            Some((429, 9_303))
        );
        assert_eq!(probe("png", false, 1170, 2532).target(false), None);
        assert_eq!(
            probe("jpeg", false, 2000, 4000).target(false),
            Some((800, 1600))
        );
        assert_eq!(probe("png", false, 1000, 3000).target(false), None);
        assert_eq!(
            probe("png", false, 1000, 3000).target(true),
            Some((533, 1600))
        );
        assert_eq!(probe("gif", false, 1000, 3000).target(true), None);
        assert_eq!(
            probe("jpeg", false, 4032, 3024).target(false),
            Some((1600, 1200))
        );
    }

    #[tokio::test]
    async fn a_timed_out_child_is_killed_and_reaped() {
        let started = std::time::Instant::now();
        let mut command = Command::new("/bin/sleep");
        command.arg("30").stdout(Stdio::piped()).kill_on_drop(true);
        let error = run_child(command, Instant::now() + Duration::from_millis(100))
            .await
            .unwrap_err();
        assert!(matches!(error, ImageError::Timeout));
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[tokio::test]
    async fn real_images_convert_pass_through_or_fail_with_a_reason() {
        let _serial = test_images::SERIAL.lock().await;
        let home = tempfile::tempdir().unwrap();
        let paths = HostPaths::from_home(home.path().to_owned()).unwrap();
        let inputs = tempfile::tempdir().unwrap();
        let write = |name: &str, bytes: &[u8]| {
            let path = inputs.path().join(name);
            std::fs::write(&path, bytes).unwrap();
            path
        };
        let wide = write("wide.png", &test_images::png(3200, 1000, false));
        let small = write("small.png", &test_images::png(200, 100, true));
        let translucent = write("translucent.png", &test_images::png(2000, 100, true));
        let mut corrupt = test_images::png(400, 400, false);
        corrupt.truncate(33);
        let corrupt = write("corrupt.png", &corrupt);
        let text = write("notes.txt", b"not an image");
        let svg = write(
            "drawing.svg",
            br#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>"#,
        );
        let link = inputs.path().join("link.png");
        std::os::unix::fs::symlink(&small, &link).unwrap();
        let huge = inputs.path().join("huge.png");
        std::fs::File::create(&huge)
            .unwrap()
            .set_len(MAX_SOURCE_BYTES + 1)
            .unwrap();

        let admission = Admission::try_new().unwrap();
        let deadline = Instant::now() + Duration::from_secs(30);
        let preparation = Preparation::admit(&admission, &paths, deadline)
            .await
            .unwrap();
        let scratch = preparation.scratch.path.clone();

        let image = preparation.prepare(&wide, deadline).await.unwrap();
        assert_eq!((image.mime, image.converted), ("image/jpeg", true));
        assert_eq!(sips_size(&image.bytes).await, (1600, 500));

        let image = preparation.prepare(&small, deadline).await.unwrap();
        assert_eq!((image.mime, image.converted), ("image/png", false));
        assert_eq!(image.bytes, std::fs::read(&small).unwrap());

        let image = preparation.prepare(&translucent, deadline).await.unwrap();
        assert_eq!((image.mime, image.converted), ("image/png", true));
        assert_eq!(sips_size(&image.bytes).await, (1600, 80));

        for (path, category, reason) in [
            (&corrupt, "unsupported_image", "could not read"),
            (&text, "unsupported_image", "not a PNG"),
            (&svg, "unsupported_image", "not a PNG"),
            (&link, "image_file", "symbolic link"),
            (&huge, "image_file", "larger than"),
            (
                &inputs.path().join("missing.png"),
                "image_file",
                "not found",
            ),
        ] {
            let error = preparation.prepare(path, deadline).await.err().unwrap();
            assert_eq!(error.category(), category, "{}: {error}", path.display());
            assert!(
                error.to_string().contains(reason),
                "{}: {error}",
                path.display()
            );
        }
        assert_eq!(std::fs::read_dir(&scratch).unwrap().count(), 0);
        drop(preparation);
        assert!(!scratch.exists());
        let expired = Preparation::admit(&admission, &paths, deadline)
            .await
            .unwrap();
        assert!(matches!(
            expired.prepare(&wide, Instant::now()).await,
            Err(ImageError::Timeout)
        ));
    }
}
