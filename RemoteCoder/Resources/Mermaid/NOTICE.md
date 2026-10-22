# Offline Mermaid runtime

This directory contains the unmodified Mermaid **12.0.0** browser distribution,
released on **2026-09-10** and reviewed on **2026-09-20**. No CDN, npm install,
package lifecycle script, remote font, or rendering service is used by the app.
The distribution embeds its transitive dependencies; their versions are pinned
by the verified archive, rather than re-resolved at build time.

`mermaid-12.0.0-LICENSE.txt` contains Mermaid's MIT license. The distribution's
embedded **Bundled license information** is retained verbatim, including the
notices for its dependencies. Do not minify away or strip those notices.

The app-owned `MermaidHost.html` and `MermaidHost.js` are not upstream Mermaid code.

To reproduce the two vendor files, run `python3 scripts/vendor-mermaid.py` from
the repository root. The script checks the complete npm archive's pinned SHA-512
before writing either file and never executes code from the package.

Runtime SHA-256:
`28fca7ae6ebc7ed7bb63bde63136a74bfef14f296a57e403657eeb8b32836073`

Upstream: https://github.com/mermaid-js/mermaid
Package: https://registry.npmjs.org/mermaid/12.0.0
