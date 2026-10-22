use super::package::{copy_tree, sha256_file};
use anyhow::{Context, Result, ensure};
use std::collections::BTreeMap;
use std::fs::File;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

pub(super) const NAME: &str = env!("RC_GATEWAY_BUNDLE_NAME");
pub(super) const BINARY: &str = env!("RC_GATEWAY_EXECUTABLE_NAME");

pub(super) fn executable(bundle: &Path) -> PathBuf {
    bundle.join("Contents/MacOS").join(BINARY)
}

pub(super) enum GatewayArtifact {
    Flat(PathBuf),
    Bundle(PathBuf),
}

impl GatewayArtifact {
    pub(super) fn load(path: &Path) -> Result<Self> {
        let path = path.canonicalize()?;
        if path.is_dir() {
            ensure!(
                executable(&path).is_file() && path.join("Contents/Info.plist").is_file(),
                "Gateway bundle is incomplete"
            );
            return Ok(Self::Bundle(path));
        }
        ensure!(path.is_file(), "Gateway executable is unavailable");
        if let Some(bundle) = path.ancestors().nth(3)
            && path == executable(bundle)
            && bundle.join("Contents/Info.plist").is_file()
        {
            Ok(Self::Bundle(bundle.to_owned()))
        } else {
            Ok(Self::Flat(path))
        }
    }

    pub(super) fn binary(&self) -> PathBuf {
        match self {
            Self::Flat(path) => path.clone(),
            Self::Bundle(path) => executable(path),
        }
    }

    pub(super) fn version_directory(&self) -> Result<&Path> {
        match self {
            Self::Flat(path) | Self::Bundle(path) => path.parent().context("Gateway has no parent"),
        }
    }

    pub(super) fn copy_to(&self, version: &Path) -> Result<()> {
        match self {
            Self::Flat(path) => {
                std::fs::copy(path, version.join(BINARY))?;
                File::open(version.join(BINARY))?.sync_all()?;
            }
            Self::Bundle(path) => {
                let expected = snapshot(path)?;
                let destination = version.join(NAME);
                copy_tree(path, &destination)?;
                ensure!(
                    snapshot(&destination)? == expected,
                    "Gateway bundle changed during staging"
                );
                for entry in walkdir::WalkDir::new(&destination).contents_first(true) {
                    File::open(entry?.path())?.sync_all()?;
                }
                std::os::unix::fs::symlink(
                    Path::new(NAME).join("Contents/MacOS").join(BINARY),
                    version.join(BINARY),
                )?;
            }
        }
        Ok(())
    }

    pub(super) fn matches(&self, version: &Path) -> Result<bool> {
        match self {
            Self::Flat(path) => Ok(!version.join(BINARY).is_symlink()
                && !version.join(NAME).exists()
                && sha256_file(path)? == sha256_file(&version.join(BINARY))?),
            Self::Bundle(path) => Ok(std::fs::read_link(version.join(BINARY))?
                == Path::new(NAME).join("Contents/MacOS").join(BINARY)
                && snapshot(path)? == snapshot(&version.join(NAME))?),
        }
    }
}

#[derive(PartialEq, Eq)]
enum Entry {
    Directory,
    File {
        executable_bits: u32,
        sha256: String,
    },
}

fn snapshot(root: &Path) -> Result<BTreeMap<PathBuf, Entry>> {
    ensure!(
        root.is_dir() && !root.is_symlink(),
        "Gateway bundle is unavailable"
    );
    let mut entries = BTreeMap::new();
    let mut bytes = 0_u64;
    for entry in walkdir::WalkDir::new(root).min_depth(1) {
        let entry = entry?;
        let kind = entry.file_type();
        ensure!(
            kind.is_dir() || kind.is_file(),
            "Unsupported gateway bundle entry"
        );
        let value = if kind.is_file() {
            let metadata = entry.metadata()?;
            bytes += metadata.len();
            ensure!(
                bytes <= 256 * 1024 * 1024,
                "Gateway bundle exceeds installation capacity"
            );
            Entry::File {
                executable_bits: metadata.permissions().mode() & 0o111,
                sha256: sha256_file(entry.path())?,
            }
        } else {
            Entry::Directory
        };
        entries.insert(entry.path().strip_prefix(root)?.to_owned(), value);
        ensure!(
            entries.len() <= 128,
            "Gateway bundle exceeds entry capacity"
        );
    }
    Ok(entries)
}
