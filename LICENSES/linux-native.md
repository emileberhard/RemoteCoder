# Linux native runtime components

The Linux bundle retains the Rust inventories for the GNU gateway and the musl Codex CLI and code-mode host. The existing ripgrep and V8 notices also apply. Native code linked into those executables keeps these additional terms. Bubblewrap is a separately installed distribution dependency and is not bundled.

| Component | Exact source | Terms |
| --- | --- | --- |
| musl 1.2.5 | [Upstream source](https://musl.libc.org/releases/musl-1.2.5.tar.gz) | MIT and retained source-specific notices; [Debian source copyright inventory](musl-1.2.5.txt) |
| OpenSSL 3.6.4 | [Source archive](https://www.openssl.org/source/openssl-3.6.4.tar.gz) | Copyright 1998–2026 The OpenSSL Project Authors. Apache-2.0; [full terms](OpenSSL-3.6.4.txt) |

The fork's checksum-pinned `install-musl-build-tools.sh` and `install-musl-openssl.sh` own the native dependency recipes. The Linux builder retains the approved complete package tree; changing source, native dependencies, resources or executable modes requires a new reviewed package approval.

The unmodified Claude Code executable in private operator bundles remains under Anthropic's separate terms. Its vendor version, download location and signed-manifest fingerprint are recorded in `docs/claude/compatibility.json`; RemoteCoder grants no additional rights in that executable.
