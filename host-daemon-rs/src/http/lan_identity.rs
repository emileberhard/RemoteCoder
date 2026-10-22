use std::fs::{File, OpenOptions};
use std::io::{ErrorKind, Read};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;

use anyhow::{Context, Result, ensure};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use rcgen::{CertificateParams, KeyPair, PKCS_ECDSA_P256_SHA256, PublicKeyData};
use sha2::{Digest, Sha256};
use tokio_rustls::TlsAcceptor;
use tokio_rustls::rustls::ServerConfig;
use tokio_rustls::rustls::crypto::ring;
use tokio_rustls::rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use tokio_rustls::rustls::version::TLS13;

use crate::storage::private_state::{self, Creation};

/// A PKCS#8 P-256 key is about 140 bytes; anything near this is not one.
const MAX_KEY_BYTES: u64 = 4096;

pub(crate) struct LanIdentity {
    pub host: String,
    pub spki_sha256: String,
    pub acceptor: TlsAcceptor,
}

impl LanIdentity {
    pub(crate) fn load(key_path: &Path, host: String) -> Result<Self> {
        let key = load_or_create_key(key_path)?;
        let acceptor = acceptor(&key, certificate(&key, &host)?)?;
        Ok(Self {
            spki_sha256: spki_sha256(&key),
            host,
            acceptor,
        })
    }
}

pub(crate) fn default_key_path() -> Result<PathBuf> {
    Ok(crate::config::HostPaths::from_env()?.state("lan-tls-key.der"))
}

pub(crate) fn mdns_host_name() -> Result<String> {
    let output = Command::new("/usr/sbin/scutil")
        .args(["--get", "LocalHostName"])
        .output()
        .context("running scutil --get LocalHostName")?;
    ensure!(
        output.status.success(),
        "scutil --get LocalHostName exited with {}: {}",
        output.status,
        String::from_utf8_lossy(&output.stderr).trim()
    );
    let name = String::from_utf8(output.stdout).context("LocalHostName is not UTF-8")?;
    let name = name.trim();
    ensure!(!name.is_empty(), "LocalHostName is empty");
    Ok(format!("{name}.local"))
}

fn load_or_create_key(path: &Path) -> Result<KeyPair> {
    match open_key(path) {
        Ok(file) => read_key(file, path),
        Err(error) if error.kind() == ErrorKind::NotFound => create_key(path),
        Err(error) => Err(error).with_context(|| format!("opening {}", path.display())),
    }
}

fn create_key(path: &Path) -> Result<KeyPair> {
    private_state::ensure_private_directory(
        path.parent().context("LAN TLS key path has no parent")?,
    )?;
    let key =
        KeyPair::generate_for(&PKCS_ECDSA_P256_SHA256).context("generating the LAN TLS key")?;
    match private_state::create_new(path, key.serialized_der())? {
        Creation::Created => Ok(key),
        Creation::AlreadyExists => {
            let file = open_key(path).with_context(|| format!("opening {}", path.display()))?;
            read_key(file, path)
        }
    }
}

fn open_key(path: &Path) -> std::io::Result<File> {
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
}

fn read_key(mut file: File, path: &Path) -> Result<KeyPair> {
    let metadata = file
        .metadata()
        .with_context(|| format!("inspecting {}", path.display()))?;
    ensure!(
        metadata.is_file(),
        "{} is not a regular file",
        path.display()
    );
    ensure!(
        metadata.len() <= MAX_KEY_BYTES,
        "{} is {} bytes; a LAN TLS key is at most {MAX_KEY_BYTES}",
        path.display(),
        metadata.len()
    );
    let mode = metadata.permissions().mode() & 0o777;
    ensure!(
        mode & 0o077 == 0,
        "{} has mode {mode:o}; the LAN TLS key must be readable only by its owner",
        path.display()
    );
    let mut der = Vec::new();
    file.read_to_end(&mut der)
        .with_context(|| format!("reading {}", path.display()))?;
    KeyPair::from_pkcs8_der_and_sign_algo(&PrivatePkcs8KeyDer::from(der), &PKCS_ECDSA_P256_SHA256)
        .with_context(|| format!("{} is not a PKCS#8 ECDSA P-256 key", path.display()))
}

fn certificate(key: &KeyPair, host: &str) -> Result<CertificateDer<'static>> {
    let params = CertificateParams::new(vec![host.to_owned(), "localhost".to_owned()])
        .with_context(|| format!("LAN TLS certificate names for {host}"))?;
    Ok(params
        .self_signed(key)
        .context("signing the LAN TLS certificate")?
        .der()
        .clone())
}

fn acceptor(key: &KeyPair, certificate: CertificateDer<'static>) -> Result<TlsAcceptor> {
    let private_key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key.serialize_der()));
    let mut config = ServerConfig::builder_with_provider(Arc::new(ring::default_provider()))
        .with_protocol_versions(&[&TLS13])
        .context("LAN TLS protocol versions")?
        .with_no_client_auth()
        .with_single_cert(vec![certificate], private_key)
        .context("LAN TLS certificate")?;
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    Ok(TlsAcceptor::from(Arc::new(config)))
}

fn spki_sha256(key: &KeyPair) -> String {
    STANDARD.encode(Sha256::digest(key.subject_public_key_info()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio_rustls::rustls::server::ParsedCertificate;

    const P256_SPKI_HEADER: [u8; 26] = [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08,
        0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
    ];

    fn mode(path: &Path) -> u32 {
        std::fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    #[test]
    fn key_persists_owner_only_and_reloads_with_the_same_pin() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("lan-tls-key.der");

        let created = load_or_create_key(&path).unwrap();
        let reloaded = load_or_create_key(&path).unwrap();

        assert_eq!(mode(&path), 0o600);
        assert_eq!(std::fs::read(&path).unwrap(), created.serialized_der());
        assert_eq!(reloaded.serialized_der(), created.serialized_der());
        assert_eq!(spki_sha256(&reloaded), spki_sha256(&created));
        assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 1);
    }

    #[test]
    fn group_readable_key_is_rejected_and_kept() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("lan-tls-key.der");
        let original = load_or_create_key(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o640)).unwrap();

        let error = load_or_create_key(&path).expect_err("group-readable key");

        assert!(error.to_string().contains("mode 640"), "{error:#}");
        assert_eq!(std::fs::read(&path).unwrap(), original.serialized_der());
    }

    #[test]
    fn key_that_is_not_p256_is_rejected_and_kept() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("lan-tls-key.der");
        let p384 = KeyPair::generate_for(&rcgen::PKCS_ECDSA_P384_SHA384).unwrap();
        private_state::create_new(&path, p384.serialized_der()).unwrap();

        assert!(load_or_create_key(&path).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), p384.serialized_der());
    }

    #[test]
    fn a_fifo_in_place_of_the_key_is_rejected_without_blocking() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("lan-tls-key.der");
        nix::unistd::mkfifo(&path, nix::sys::stat::Mode::from_bits_truncate(0o600)).unwrap();

        let error = load_or_create_key(&path).expect_err("fifo key");

        assert!(
            error.to_string().contains("not a regular file"),
            "{error:#}"
        );
    }

    #[test]
    fn an_oversized_key_file_is_rejected_unread() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("lan-tls-key.der");
        private_state::create_new(&path, &vec![0; MAX_KEY_BYTES as usize + 1]).unwrap();

        let error = load_or_create_key(&path).expect_err("oversized key");

        assert!(error.to_string().contains("at most"), "{error:#}");
    }

    #[test]
    fn symlinked_key_is_rejected() {
        let directory = tempfile::tempdir().unwrap();
        let target = directory.path().join("elsewhere.der");
        let path = directory.path().join("lan-tls-key.der");
        load_or_create_key(&target).unwrap();
        std::os::unix::fs::symlink(&target, &path).unwrap();

        assert!(load_or_create_key(&path).is_err());
    }

    #[test]
    fn existing_key_wins_over_a_concurrent_generation() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("lan-tls-key.der");
        let existing = load_or_create_key(&path).unwrap();

        let loser = create_key(&path).unwrap();
        assert_eq!(loser.serialized_der(), existing.serialized_der());

        let racing = tempfile::tempdir().unwrap();
        let racing_path = racing.path().join("lan-tls-key.der");
        let pins = std::thread::scope(|scope| {
            let starters: Vec<_> = (0..8)
                .map(|_| scope.spawn(|| spki_sha256(&load_or_create_key(&racing_path).unwrap())))
                .collect();
            starters
                .into_iter()
                .map(|starter| starter.join().unwrap())
                .collect::<Vec<_>>()
        });
        let persisted = spki_sha256(&load_or_create_key(&racing_path).unwrap());
        assert!(pins.iter().all(|pin| *pin == persisted), "{pins:?}");
        assert_eq!(std::fs::read_dir(racing.path()).unwrap().count(), 1);
    }

    #[test]
    fn pin_hashes_the_p256_spki_that_the_certificate_carries() {
        let directory = tempfile::tempdir().unwrap();
        let key = load_or_create_key(&directory.path().join("lan-tls-key.der")).unwrap();
        let point = key.public_key_raw();
        assert_eq!(point.len(), 65);
        assert_eq!(point[0], 0x04);
        let spki = [P256_SPKI_HEADER.as_slice(), point].concat();

        assert_eq!(spki_sha256(&key), STANDARD.encode(Sha256::digest(&spki)));

        let certificate = certificate(&key, "gateway-test.local").unwrap();
        let parsed = ParsedCertificate::try_from(&certificate).unwrap();
        assert_eq!(parsed.subject_public_key_info().as_ref(), spki.as_slice());
    }
}
