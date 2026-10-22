# macOS runtime dependency review

The runtime ships the `codex` CLI (including app-server) and `codex-code-mode-host` for `aarch64-apple-darwin`. The reproducible production dependency view is:

```sh
cargo tree --locked --target aarch64-apple-darwin --edges normal,build -p codex-cli -p codex-code-mode-host
```

The publication patch updates Rustls to 0.23.46, rustls-webpki to 0.103.16, webpki-roots/root-certs to 1.0.10, plist to 1.10.1, and ZIP to 9.0.0. The plugin extractor keeps ordinary permission bits and has a focused extraction regression. Dependency release timestamps were checked against the 12-hour update policy. The exact deployed source and binary hashes remain in compatibility.json.

A raw, unfiltered RustSec audit must be run outside the Codex workspace, because upstream's `.cargo/audit.toml` ignores reviewed advisories. A green ordinary `cargo audit` is not evidence of zero advisory records.

| Remaining raw advisory | Runtime assessment | Recheck when |
| --- | --- | --- |
| [RUSTSEC-2026-0118](https://rustsec.org/advisories/RUSTSEC-2026-0118.html), Hickory 0.25.2 | The vulnerable DNSSEC validation code is not compiled. Enabled proto features are `futures-io,std,tokio`; no `dnssec-ring`, `dnssec-aws-lc-rs` or `__dnssec`. | DNSSEC features or Rama/Hickory version changes |
| [RUSTSEC-2026-0119](https://rustsec.org/advisories/RUSTSEC-2026-0119.html), Hickory 0.25.2 | Rama uses Hickory as a hostname resolver. Its request builder emits one bounded query plus EDNS metadata, not attacker-supplied multi-record DNS messages. The quadratic encoder requires large multi-record messages; no such caller is exposed by this runtime. This is a static reachability assessment. | Adding DNS server/forwarder behavior or passing arbitrary DNS messages to the encoder |
| [RUSTSEC-2026-0194](https://rustsec.org/advisories/RUSTSEC-2026-0194.html) and [RUSTSEC-2026-0195](https://rustsec.org/advisories/RUSTSEC-2026-0195.html), quick-xml 0.39.4 | The remaining lockfile copy belongs to Linux Wayland build tooling. The macOS production closure uses patched quick-xml through plist. | Shipping a Linux artifact or changing the target feature closure |

Unmaintained, unsoundness and yanked-package warnings are reported separately by RustSec. These are not erased by fixing the fourteen original vulnerability records. The public source does not imply that other targets, optional features, or future dependency resolutions have been assessed.
