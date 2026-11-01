# Linux native runtime components

The Linux bundle retains the Rust inventories for the GNU gateway and the musl Codex CLI, code-mode host and bubblewrap wrapper. The existing ripgrep and V8 notices also apply. Native code linked into those executables keeps these additional terms.

| Component | Exact source | Terms |
| --- | --- | --- |
| bubblewrap 0.11.2 | [Vendored source and build wrapper at the matched fork revision](https://github.com/emileberhard/codex/tree/1f412796c9b46d46fd218d43fd47ea3455c46c55/codex-rs/vendor/bubblewrap), [Rust wrapper and Cargo build script](https://github.com/emileberhard/codex/tree/1f412796c9b46d46fd218d43fd47ea3455c46c55/codex-rs/bwrap) | Copyright (C) 2016 Alexander Larsson. LGPL-2.0-or-later; [full license](bubblewrap-LGPL-2.0.txt). The wrapper and build script are available as source so this executable can be rebuilt with modified bubblewrap. |
| libcap 2.75 | [Source archive](https://mirrors.edge.kernel.org/pub/linux/libs/security/linux-privs/libcap2/libcap-2.75.tar.xz), SHA-256 `de4e7e064c9ba451d5234dd46e897d7c71c96a9ebf9a0c445bc04f4742d83632` | BSD-3-Clause option; [copyright and full terms](libcap-2.75.txt) |
| musl 1.2.5 | [Upstream source](https://musl.libc.org/releases/musl-1.2.5.tar.gz) | MIT and retained source-specific notices; [Debian source copyright inventory](musl-1.2.5.txt) |
| OpenSSL 3.6.4 | [Source archive](https://www.openssl.org/source/openssl-3.6.4.tar.gz) | Copyright 1998–2026 The OpenSSL Project Authors. Apache-2.0; [full terms](OpenSSL-3.6.4.txt) |

The fork's checksum-pinned `install-musl-build-tools.sh` and `install-musl-openssl.sh` own the native dependency recipes. The Linux builder retains the approved complete package tree; changing source, native dependencies, resources or executable modes requires a new reviewed package approval.

The unmodified Claude Code executable in private operator bundles remains under Anthropic's separate terms. Its vendor version, download location and signed-manifest fingerprint are recorded in `docs/claude/compatibility.json`; RemoteCoder grants no additional rights in that executable.
