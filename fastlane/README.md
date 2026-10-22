# Releases

Contributor checks run in `.github/workflows/ci.yml` on GitHub-hosted runners.
The native logic suite uses Xcode 27 on macOS 27; gateway tests run there too
because the gateway bundles macOS metadata and native helpers. Browser checks
run on Ubuntu. No signing credentials or private operator services are needed.

A release is an annotated `MAJOR.MINOR.PATCH` tag on `main`, each component
0–999 without leading zeroes, higher than every earlier stable release. The
annotation becomes the public GitHub Release notes verbatim and the title is
the bare version. Every app and gateway artifact carries that version and the
exact tag commit. Release tags are immutable; corrections use a new patch.

The public release workflow validates tag syntax, remote tag identity, ordering
and main ancestry, then dispatches an exact version and commit to the private
operator repository. That repository independently validates them on a hosted
runner before admitting a self-hosted job. The private run's `verify-all` is the
release gate for that same commit; public CI provides hosted contributor feedback.
The private run owns signing, deployment, device delivery, TestFlight and Mac catch-up.
A successful public handoff proves dispatch, not deployment; the private run
and installed artifact identities prove delivery.

`fastlane/Fastfile` retains the archive, export and upload implementation and
bounded release caches. These maintainer lanes require an explicit identity
and operator helpers; ordinary unsigned contributor builds use `just ios-build`
and `just mac-build` instead. Optional local identity settings live in ignored
`Config/Local.xcconfig`. A maintainer configuration can be selected with
`RC_MAINTAINER_CONFIG`; no maintainer configuration is needed for public checks.

Maintainer operations and cutover instructions live in
[RemoteCoder-deploy/AGENTS.md](https://github.com/emileberhard/RemoteCoder-deploy/blob/main/AGENTS.md).
