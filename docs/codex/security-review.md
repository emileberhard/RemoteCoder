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

Unmaintained, unsoundness and yanked-package warnings are reported separately by RustSec. These are not erased by fixing the fourteen original vulnerability records. The public source does not imply that other targets, optional features, or future dependency resolutions have been assessed.

## Linux introduction and common source update

The 2026-11-01 review covers common fork source `1f412796c9b46d46fd218d43fd47ea3455c46c55`, both package targets and the default features of the shipped CLI/code-mode-host. The Linux packaging descendant `f8d9f770971005e9a809460da4cf557fcbbcce03` changes only package assembly and its tests. Voice-host, optional DNSSEC and other workspace-only features are outside these artifacts. The raw audit remains **9 vulnerability records, 10 unmaintained warnings and 15 unsoundness warnings**. These are reachability assessments, not a claim of a clean audit or proof about different feature sets.

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
| [RUSTSEC-2026-0391](https://rustsec.org/advisories/RUSTSEC-2026-0391.html), zstd 0.13.3 | Production callers construct fresh stream contexts; they do not reuse an abandoned borrowed context. ZIP, reqwest and tonic do not enable zstd in these artifacts. | Borrowed context reuse or new compression consumers/features |
| [RUSTSEC-2026-0398](https://rustsec.org/advisories/RUSTSEC-2026-0398.html), zstd-safe 7.2.4 | Seekable/experimental APIs are not compiled. | Enabling experimental/seekable features |
| [RUSTSEC-2026-0403](https://rustsec.org/advisories/RUSTSEC-2026-0403.html), zstd-safe 7.2.4 | Shipped decompression uses `read::Decoder`/`decode_all`, explicitly outside this advisory; no production `write::Decoder` caller. | New write-decoder callers or changed zstd features |

The other unsoundness records are retained in the raw report. `scc` is absent from the production closure. The selected event-listener callers do not use affected non-Send tags; faster-hex uses checked decoding; memmap2 callers do not use the affected range operation; Tokio AsyncFd wraps owned files and the affected inotify stream is disabled. The zstd-safe records 2026-0395–0397, 0399–0402 and 0404–0406 concern unused APIs or disabled experimental/multithreaded features in these artifacts.

The unmaintained records cover atomic-polyfill, basic-toml, bincode, derivative, fxhash, paste, unsafe-libyaml, zbus_names, zvariant and zvariant_derive. They remain maintenance liabilities; this review does not convert them into supported dependencies or suppress them. Recheck the entire assessment when the common source, lockfile, targets or feature closure changes. Host-specific raw reports and native acceptance receipts remain in private operations.
