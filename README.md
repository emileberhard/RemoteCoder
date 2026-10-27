# RemoteCoder

RemoteCoder brings Codex and Claude Code on your own Mac to iPhone, iPad,
Mac and a browser. Stream replies, inspect tool activity, attach files, switch
between hosts and continue the same conversations. Optional dictation, spoken
replies and Voice Mode let you work by voice.

A Rust gateway on each Mac serves authenticated JSON-RPC over WebSocket. It
connects to one managed, version-matched Codex app-server and runs Claude Code
through its stream-json CLI. The native clients share Swift logic; the browser
uses a same-origin bridge that keeps gateway credentials on its host.

## Self-host

You need a Mac, the [matched Codex runtime](docs/codex/runtime.md),
Rust/Cargo, Python 3 and `just`. Native builds also need Xcode 27, Swift 6.4
and `just`. Device installs require your own Apple signing configuration.

1. Follow the [gateway setup](host-daemon-rs/README.md) to build the gateway,
   install the matched Codex package, generate a random operator token and start
   the local listener. Sign in to your own Codex and/or unmodified Claude Code
   CLI. Basic chat does not require a router, push broker or private dotfiles.
2. Give your client a private route to that host, such as a VPN. Use HTTPS/WSS
   for remote connections, or deliberately configure the trusted-network
   transport described in [owned operations](docs/owned-operations.md#credentials-and-transport).
3. For a native client, follow the [app build guide](docs/self-hosting.md).
   For a browser, follow [web-client/README.md](web-client/README.md) to build
   the bridge and bind your gateway through a private token file.
4. Add the gateway address and token in the native app's host settings, choose
   a working folder and start a chat. Keep credentials out of source control.

## Trust boundary

**A gateway credential grants execution as the gateway's host user.** It can
run commands, read and write files, use signed-in provider accounts and invoke
configured tools. Installation credentials can be revoked separately, but do
not provide a restricted or read-only account. This is a personal execution
surface, not a multi-tenant service.

Admit only people and agents you trust with that host. Keep the gateway behind
an authenticated private network or properly secured TLS endpoint. A browser
bridge session inherits the authority of every gateway bound to that bridge.
Generated HTML visuals may access external HTTPS resources. See
[SECURITY.md](SECURITY.md) and [PRIVACY.md](PRIVACY.md).

## Optional integrations

| Feature | Prerequisites |
| --- | --- |
| Claude through llm-router, account switching, automatic titles and speech relay | Your own router deployment, host key and explicit gateway configuration |
| Dictation and spoken replies | Configured speech relay and provider accounts; microphone permission for capture |
| Realtime Voice Mode | Compatible Codex realtime access, provider login and microphone permission; native system-call integration is iOS-only |
| Notifications, incoming calls, Live Activities and location wake-ups | An APNs broker authorized for your own bundle IDs, signing capabilities and device registration |
| Maps and navigation | Your own restricted Google Maps/Navigation credentials, enabled APIs and location permission |
| Shared dictation library | Your own CloudKit container and signing configuration; explicit opt-in |
| Telephone calls | Your own 46elks account/numbers, carrier worker, private media credential and HTTPS/WSS ingress |
| Maintainer deployment | Private operator configuration for signing, device delivery, ingress and fleet services |

These integrations are optional. Do not enable them until their credentials,
permissions and network boundaries are configured. The
[calling guide](agent-calls/README.md), [navigation contract](docs/live-navigation.md)
and [dictation contract](docs/unified-dictation.md) describe their data flows.

## Development

```sh
just setup          # prepare optional local configuration
just ios-build      # compile without installing or running a simulator
just mac-build      # compile the Mac target
just test           # Mac-native Swift logic tests
just gateway-check  # gateway and tooling checks
```

[AGENTS.md](AGENTS.md) maps ownership and chooses checks for each change.
[Architecture](docs/system-architecture.md), [glossary](docs/glossary.md) and
[repository model](docs/repository-model.md) describe the contracts. Sources live
in `RemoteCoder/`, `Core/`, `Shared/`, the app-extension directories,
`host-daemon-rs/`, `web-client/`, `agent-calls/` and `dev-tools/`.
See [CONTRIBUTING.md](CONTRIBUTING.md) before submitting changes.

## Dependency updates

Dependabot updates GitHub Actions, Cargo, Bun and uv dependencies. The app's
remote Swift dependencies are declared in the Xcode project, while `Core` has
no remote dependencies. Dependabot cannot update an Xcode-only
`Package.resolved`. Maintainers review those upstream releases, update the
package requirements in Xcode and commit the project and its
`RemoteCoder.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
together after the relevant app checks pass.

## License, name and icon

Original RemoteCoder code is [PolyForm Shield 1.0.0](LICENSE): you may read,
run, modify, self-host and share it for permitted purposes, subject to the
license's noncompete restriction. This is source-available software. Third-party
code and forks retain their own licenses, including Apache-2.0 for Codex; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

The RemoteCoder name and icon are reserved. Distributed forks need their own
name and icon; the code license grants no branding rights.

## Security

Report vulnerabilities privately through
[GitHub security advisories](https://github.com/emileberhard/RemoteCoder/security/advisories/new).
Do not include tokens, private transcripts or account details in public issues.
[SECURITY.md](SECURITY.md) describes reporting and supported versions.
