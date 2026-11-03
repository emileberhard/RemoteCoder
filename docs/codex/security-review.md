# Matched runtime dependency review

The runtime ships the `codex` CLI (including app-server) and `codex-code-mode-host` for `aarch64-apple-darwin` and `x86_64-unknown-linux-musl`. The reproducible production dependency view selects the package target:

```sh
cargo tree --locked --target <package-target> --edges normal,build -p codex-cli -p codex-code-mode-host
```

The publication patch updates Rustls to 0.23.46, rustls-webpki to 0.103.16, webpki-roots/root-certs to 1.0.10, plist to 1.10.1, and ZIP to 9.0.0. The plugin extractor keeps ordinary permission bits and has a focused extraction regression. Dependency release timestamps were checked against the 12-hour update policy. The exact deployed source and binary hashes remain in compatibility.json.

A raw, unfiltered RustSec audit must be run outside the Codex workspace, because upstream's `.cargo/audit.toml` ignores reviewed advisories. A green ordinary `cargo audit` is not evidence of zero advisory records.

| Remaining raw advisory | Runtime assessment | Recheck when |
| --- | --- | --- |
| [RUSTSEC-2026-0118](https://rustsec.org/advisories/RUSTSEC-2026-0118.html), Hickory 0.25.2 | The vulnerable DNSSEC validation code is not compiled. Enabled proto features are `futures-io,std,tokio`; no `dnssec-ring`, `dnssec-aws-lc-rs` or `__dnssec`. | DNSSEC features or Rama/Hickory version changes |
| [RUSTSEC-2026-0119](https://rustsec.org/advisories/RUSTSEC-2026-0119.html), Hickory 0.25.2 | Rama uses Hickory as a hostname resolver. Its request builder emits one bounded query plus EDNS metadata, not attacker-supplied multi-record DNS messages. The quadratic encoder requires large multi-record messages; no such caller is exposed by this runtime. This is a static reachability assessment. | Adding DNS server/forwarder behavior or passing arbitrary DNS messages to the encoder |
| [RUSTSEC-2026-0194](https://rustsec.org/advisories/RUSTSEC-2026-0194.html) and [RUSTSEC-2026-0195](https://rustsec.org/advisories/RUSTSEC-2026-0195.html), quick-xml 0.39.4 | On Linux, quick-xml 0.39.4 is build-only Wayland protocol generation from pinned source XML, without attacker-supplied XML. The shipped parser uses patched quick-xml 0.41. The macOS closure uses patched quick-xml through plist. | Accepting untrusted build inputs or changing the target feature closure |

Unmaintained, unsoundness and yanked-package warnings are reported separately by RustSec. The public source does not imply that other targets, optional features, or future dependency resolutions have been assessed.

## Linux introduction and common source update

The 2026-11-03 candidate covers common fork source `7133910f6709274b35f310b2b68d27d5a6cd6a76` and Linux packaging descendant `09c13024bda50b1204d9faae5cd91e2081a540f8`. Relative to the prior reviewed target sources, the common source changes the zstd dependency lock and notices; the Linux-only packaging delta is unchanged. Both package targets and the default features of the CLI/code-mode-host retain the 2026-11-01 reachability review. Voice-host, optional DNSSEC and other workspace-only features are outside these artifacts. A raw, unfiltered `cargo audit` against [RustSec advisory database commit `263a4d951a0867d4bddc29dddd6d59427c78f9a7`](https://github.com/RustSec/advisory-db/commit/263a4d951a0867d4bddc29dddd6d59427c78f9a7) reports **6 vulnerability records, 10 unmaintained warnings, 5 unsoundness warnings and 2 yanked packages**. The prior lockfile audited against the same database reported 9, 10, 15 and 2 respectively. These are reachability assessments, not a claim of a clean audit or proof about different feature sets. The yanked lockfile packages are `clipboard-win` 5.4.1 and `spin` 0.9.8.

The vendored bubblewrap 0.11.2 is affected by
[CVE-2026-87766](https://github.com/containers/bubblewrap/security/advisories/GHSA-pxhw-h44j-8pfx).
Linux packages therefore select the supported system-bubblewrap path, declare
that dependency and omit the bundled executable entirely. Deployment requires
Debian's root-owned bubblewrap 0.12.0 or newer; Debian security updates own its
future fixes. Neither the Mac package nor the Linux package ships this
vulnerable native component. RustSec alone does not cover native dependencies.

| Advisory | Assessed production path and action | Recheck when |
| --- | --- | --- |
| [RUSTSEC-2026-0387](https://rustsec.org/advisories/RUSTSEC-2026-0387.html), crypto-bigint 0.5.5 | The previous source enabled AWS `credentials-login`, reaching P-256 private DPoP signing through `aws-config/src/login/dpop.rs`. That optional feature is removed for **both targets**, retaining environment, profile, SSO and credential-process authentication. Remaining `codex-secrets` age usage creates only scrypt recipients; `codex-user-verification` parses/verifies public credentials. Its private signing appears only in tests. Those paths do not reach affected secret arithmetic. Exact target timing exploitability was not established; the private signing path was removed rather than waived. | Enabling AWS login sessions, asymmetric age recipients, private user-verification signing or changing crypto features |
| [RUSTSEC-2026-0385](https://rustsec.org/advisories/RUSTSEC-2026-0385.html), ctutils 0.4.2 | Not in the selected production feature closure. Its lockfile presence is not evidence that the affected implementation ships. | Expanding production features or dependencies |

The other unsoundness records are retained in the raw report. `scc` is absent from the production closure. The selected event-listener callers do not use affected non-Send tags; faster-hex uses checked decoding; memmap2 callers do not use the affected range operation; Tokio AsyncFd wraps owned files and the affected inotify stream is disabled.

The [zstd 0.13.4](https://github.com/rust-lang/crates.io-index/commit/32900fee5ca09b47f3941e4343bcfe44d16f9b01) and [zstd-safe 7.4.0](https://github.com/rust-lang/crates.io-index/commit/8e225264cb6b3a3cd57ee83589821f8a4ec8fb4b) update fixes the three vulnerability and ten unsoundness records present in the prior lockfile. The feature closure is unchanged; this removes the previous zstd reachability waivers rather than implying other advisories are fixed.

The unmaintained records cover atomic-polyfill, basic-toml, bincode, derivative, fxhash, paste, unsafe-libyaml, zbus_names, zvariant and zvariant_derive. They remain maintenance liabilities; this review does not convert them into supported dependencies or suppress them. Recheck the entire assessment when the common source, lockfile, targets or feature closure changes. Host-specific raw reports and native acceptance receipts remain in private operations.
