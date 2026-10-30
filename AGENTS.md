# RemoteCoder Agent Context

RemoteCoder is an iOS 27 and macOS 27 SwiftUI app (Swift 6.4 strict
concurrency, Xcode 27) for running coding agents on Macs you control. The app speaks JSON-RPC over an
authenticated WebSocket to a Rust gateway (`host-daemon-rs/`) on each host. The
gateway proxies one managed, version-matched `codex app-server` and also runs
turns through the `claude` CLI, translating them into the same app-server v2
notifications. The app's surfaces are a streamed chat with attachments,
dictation and spoken replies; realtime Voice Mode; a history drawer across all
configured hosts; and direct `command/exec`. The `RemoteCoderMac` target
shares the chat, history, questions, attachments and dictation with the iOS app,
uses `RemoteCoder/Platform/macOS/` for its platform arms, and omits Voice Mode,
calls, Live Activities and Live Navigation.

## Instruction files

This file holds the rules for all work. Each area has its own `AGENTS.md`; read
it before editing there. Claude Code loads an area file automatically only when
it reads a file inside that directory, and Codex loads it only when started
there. So open it yourself, especially for the iOS targets outside
`RemoteCoder/`.

| Editing | Read first |
|---|---|
| iOS app and extensions: `RemoteCoder/`, `Shared/`, `RemoteCoderLiveActivities/`, `RemoteCoderNotificationService/`, `RemoteCoderLocationPushService/`, `RemoteCoderShareExtension/`, `RemoteCoderCaptureExtension/`, `RemoteCoderTests/`, `RemoteCoderUITests/`, `Core/` | [`RemoteCoder/AGENTS.md`](RemoteCoder/AGENTS.md) |
| Gateway, Codex runtime, Claude provider, agent tools, gateway voice: `host-daemon-rs/` | [`host-daemon-rs/AGENTS.md`](host-daemon-rs/AGENTS.md) |
| Gateway debug CLIs, live probes, wire protocol notes: `dev-tools/` | [`dev-tools/AGENTS.md`](dev-tools/AGENTS.md) |

Every `CLAUDE.md` is a symlink to the `AGENTS.md` beside it, so edit only
`AGENTS.md`; a new instruction scope gets the same symlink. Keep these files to
RemoteCoder-specific ownership, contracts and workflows. Use current Apple documentation and available Swift-development guidance for
Swift, SwiftUI, Liquid Glass and Observation changes. Keep this file focused on
RemoteCoder contracts rather than general language technique.

## Repository ownership

RemoteCoder is the owning integration repository for the shared agent stack.
Its `main` branch is canonical and the GitHub default. Read
[`docs/repository-model.md`](docs/repository-model.md) before changing the
cross-repository runtime, Git topology or release flow.

- RemoteCoder owns the gateway, the iOS client, runtime packaging and
  installers, both-host acceptance, and `docs/codex/compatibility.json`.
- The operator owns user and host configuration; none is required from a personal
  dotfiles repository for the public chat path.
- The public Apache-2.0 fork is [`emileberhard/codex`](https://github.com/emileberhard/codex)
  (`origin`), with [`openai/codex`](https://github.com/openai/codex) as `upstream`;
  both use `main`. The exact approved source and artifact identity lives in
  `docs/codex/compatibility.json`. Never substitute an unreviewed executable for
  the matched package. Maintainer checkout locations belong to private operations.
- Maintainers: full fleet configuration, upgrade skills and deployment authority
  live in the private [RemoteCoder-deploy operations entrypoint](https://github.com/emileberhard/RemoteCoder-deploy/blob/main/AGENTS.md).

## Delivering a request

Keep each change on its own branch and isolated worktree; preserve other agents'
and users' changes. Run the smallest relevant checks described below. A gateway
or runtime change needs an isolated end-to-end smoke test before deployment:
`dev-tools/probes/isolated-gateway.mjs` runs a candidate with separate port,
token and state. Use copies of transcripts, history and config, never live files.
Relevant `just gateway-e2e-*` probes then verify an explicitly configured deployment.

Public contributions do not carry production deployment or device-install
permission. Maintainer agents follow the private
[operations entrypoint](https://github.com/emileberhard/RemoteCoder-deploy/blob/main/AGENTS.md)
for coordination, delivery authority, configured host roles, test-device identity,
release batching and both-host acceptance. Experiments and automation use the
configured test device, never the maintainer's daily phone. Always pass its
exact device ID explicitly; do not let an installer choose a phone implicitly.

## Build, install and verify

The browser bridge is deployed independently from native releases. Its public
transport and hosting contract lives in [`web-client/README.md`](web-client/README.md).
Maintainer deployment, DNS, service ownership and rollback configuration live in
the private [operations entrypoint](https://github.com/emileberhard/RemoteCoder-deploy/blob/main/AGENTS.md).

- `just install-dev` puts an app build on the iPhone ([when](#delivering-a-request)). It snapshots the worktree into
  an isolated build on the selected host (`scripts/remote-build.py`) and reuses a
  signed device artifact only when its source, configuration, toolchain and
  signing inputs still match.
  Automatic delivery probes the exact enrolled iPhone for at most five seconds:
  a reachable, unlocked paired phone gets a direct install and launch; otherwise the app's
  existing managed installation receives the update when the optional delivery
  integration is configured. Explicit
  `just delivery=direct install-dev` or `just delivery=mdm install-dev` selects a
  transport. MDM verifies installation without claiming launch. A failed delivery
  never silently retries through another transport. Do not run `xcodebuild` directly.
- `scripts/build-host` defaults to the local builder; private configuration can
  select an operator build host.
  `RC_IOS_BUILD_HOST` (iOS kinds, `verify-all`)
  or `RC_GATEWAY_BUILD_HOST` (the other kinds) selects another host, such as
  `<gui-test-host>` or `local`, through the same capacity and source leases.
  `just install-phone` selects this machine; a failed builder never silently falls back.
  Builds preserve configured compiler parallelism limits; agent and CI builds
  use normal scheduling.
  `just ios-device-build` prepares the device artifact without phone delivery.
- Interactive device builds use optimized incremental Swift (`-O`, `singlefile`).
  Use `just compilation=wholemodule install-dev` for whole-module optimization
  matching the previous performance lane, or `just optimized=false install-dev`
  for breakpoint-heavy debugging. Each mode has a separate cache and verified
  build identity. Release compilation remains owned by its existing lane.
- `just install-mac` ([when](#delivering-a-request)) builds the snapshot optimized on the
  configured GUI test host, signs it like the newest published release
  with its Developer ID entitlements, profile and bundled configuration, keeps its
  dSYMs for `perf-trace`, then replaces and launches `/Applications/RemoteCoder.app`
  there. It uses the verified direct app in the GUI test host's release cache, which the
  GUI test host catch-up fills, independent of the currently installed app. The
  next release replaces it.
- `scripts/install-device` builds independently of phone reachability.
  `just device=<name|UDID> install-dev` selects the exact enrolled or paired
  device; ambiguous matches fail. There is no TestFlight fallback. It syncs the Google Maps
  key into the ignored local config, and `scripts/release-config.py
  verify-development` fails on any field beyond the public ones plus
  `codexGatewayAuthToken`. The committed `RemoteCoder.xcodeproj/project.xcproj`
  owns every target, synchronized source folders and shared schemes. Builds use
  its committed package lock and never resolve newer versions.
- Shared ad hoc packaging and managed-app onboarding belong to the
  `apple-devops` skill's iPhone iteration workflow. The repository adapter strips
  private local configuration, sets production APNs for the ad hoc copy, and
  verifies the upload payload. It preserves the original development artifact.
- Worktree leases protect the build host's mutable mirrors and caches, and a
  physical-device lease protects install, readback and launch. `.xcode-version`
  owns the default SDK; a per-command override does not change the shared
  toolchain. [`docs/owned-operations.md`](docs/owned-operations.md) covers build
  receipts, request ownership, and credential and transport boundaries.
- **The gates have distinct scopes.** `just test` runs the Mac-native Swift logic
  suite. `just verify` adds the source lints, gateway checks, tooling tests and
  generic iOS app, hosted-test and Mac app compilation, including the Mac
  `RC_PERF_HARNESS` code; it remains simulator-free. `just mac-harness-build`
  provides that build-only Mac harness check on its own.
  `just verify-all` adds the full gateway test suite and the hosted
  `StreamingRenderingTests`, `TranscriptScrollRenderingTests`,
  `ChatHistoryReadTests` and `GatewayBusyStateTests` on one simulator.
  `just core-test <filter>` is the fast Swift loop; `just gateway-check` and
  `just gateway-test <filter>` are gateway feedback. Successful
  gateway gates may be reused only for identical source, compiler/configuration
  and command inputs; candidates record that evidence.
- Scale verification to the changed behavior. This list owns when checks run:
  - **Small app/UI changes:** compile with `just ios-build` or `just mac-build`
    and add the relevant Mac-native tests when changing logic they cover; the user
    checks the release. Do not run simulator tests by default.
  - **Logic, history, recovery, voice or gateway changes:** run the affected
    Mac-native/gateway tests and relevant live gateway probes. Their risk alone
    does not require the entire iOS simulator suite. `just gateway-e2e-reads` is
    the read-only gateway baseline. If the affected tests still live in
    `RemoteCoderTests`, run those exact ids with `just ios-simulator-test <id>`
    (for example `RemoteCoderTests/StreamingRenderingTests` for splitter changes).
    Being app-hosted does not exempt relevant logic coverage; migrate portable
    cases to Core when practical.
  - **Changed iOS integration or relatively complex UI:** run
    `just ios-simulator-test <test id>` only when the change affects behavior
    that those tests actually exercise (for example hosted control lifecycle,
    keyboard/layout, or iOS service integration). Use `just ios-ui-test <test id>`
    for affected app navigation/accessibility flows. Run the full simulator suite
    only for a change spanning that coverage or an explicit user request. State
    the reason and select the smallest relevant suite; it is never a routine
    prerequisite for a gateway change, cleanup, merge, or release.
  - **Releases:** the release workflow requires green main CI on the exact tagged commit (see
    [Releasing](#releasing)). Run any relevant targeted iOS tests and live
    probes according to the changed behavior above before tagging.
- `scripts/build_cache.py` owns the total RemoteCoder-Build cap, including pinned
  data and every sub-owner. Reclaim only proven rebuildable payloads under their
  existing leases; publish unmet or unknown totals for the disk-pressure owner
  as defined in `docs/owned-operations.md`.
- Shared build admission keeps two compiler slots: simulator/background work
  uses one, leaving the other available to interactive work. A job acquires its
  source/cache lease before waiting for capacity. Do not bypass the runner or
  clear another job's cache to make a build start sooner. Receipts and
  `progress.json` separate queue wait, commands and artifact work.
- When the user asks for build-only verification or no iPhone is connected, run
  `just ios-build`. It uses the build host's lease and generic iOS Simulator SDK to
  compile the app and its hosted test targets with `build-for-testing`, but does
  not create, boot, or run tests in a simulator. `just mac-build` compiles the
  `RemoteCoderMac` target for `generic/platform=macOS` the same way.

- Local setup needs no bundled runtime seed. Add a gateway in the app's host
  settings, or optionally copy `RemoteCoder/Resources/RemoteCoderLocalConfig.example.json`
  to ignored `RemoteCoderLocalConfig.json`. Maps needs its own optional key;
  basic chat does not. The synchronized Resources folder includes the ignored
  local configuration when present; its example template is excluded. Provider keys never enter the app. Public identity defaults
  live in `Config/RemoteCoder.xcconfig`, with ignored `Config/Local.xcconfig`
  overrides; see [`docs/self-hosting.md`](docs/self-hosting.md).
- Optional maintainer settings are loaded by `scripts/maintainer_config.py`;
  `RC_MAINTAINER_CONFIG` selects an explicit file. Missing default configuration
  leaves public defaults active; an explicitly selected missing file fails.
  `xcodeSettings` generates local identity overrides while preserving existing
  development overrides. Signed releases require an actual team and namespace,
  regenerate the projection and reject example identities. Host/device roles,
  delivery coordinators, release seeds and service policy live only in the
  private operations repository. Generated projects and `Derived/` stay ignored.

## Releasing

A release is one annotated stable `X.Y.Z` tag (each part 0–999, no leading zeros),
on pushed `main` and higher than every stable tag. The tag is every artifact's
marketing version. Tags are immutable; fixes use the next patch.

Every Debug project build and Core package build fails on compiler warnings,
locally and in CI; Release archives retain their existing warning behavior. Fix
the cause, using a narrowly scoped `@diagnose(..., as: ignored, reason: "...")`
only when a justified exception cannot be removed.

Public hosted CI compiles both apps, their extensions, hosted tests and the Mac
performance harness, runs the existing logic/tooling/gateway checks and targeted
hosted rendering/history suites. Each macOS lane skips when a main push or
same-repository pull request already passed its exact inputs: the top-level
entries it can read. The `reuse` job owns each lane's excluded entries; when a
lane starts reading another top-level path, stop excluding it there. The `passed`
job records passing lanes and is the single verdict. Release admission waits for that exact main CI
commit; releases do not rerun it. `scripts/select-xcode` selects `.xcode-version`
without changing the host's default Xcode.

The public tag workflow reserves the next global App Store Connect build
number shared by both platforms, retains the exact reservation for retries, archives iOS and macOS on
hosted runners and cloud-signs checked App Store exports. `Config/entitlements-*.json`
covers every shipped bundle. The upload fence checks earlier attempts' upload
steps; a retry queries Apple and refuses a second uncertain upload. Each platform then
waits for processing, updates What to Test under the existing internal distribution
policy and prepares its App Store version, preserving screenshots. A version in
review or pending release is left untouched. App Review and release stay with Emil.

The protected `testflight` environment supplies `APP_BUNDLE_ID`, the ASC key,
`RC_RELEASE_CONFIGURATION` (the operator's nonsecret xcodeSettings and public
releaseConfig) and the optional Maps key. Provider and gateway credentials never
enter release bundles. `scripts/release-config.py` validates this boundary.

The public workflow also hands the exact tag, commit and run ID to the private
[operations entrypoint](https://github.com/emileberhard/RemoteCoder-deploy/blob/main/AGENTS.md).
It independently admits the tag and successful public CI before running the
Mini's gateway build and planned restart/recovery. It independently archives the
same commit locally for ad hoc iPhone and Developer ID Mac delivery, preserving
the existing semver-derived direct build numbers, cache/capacity leases and host
job cap. Direct builds never upload to ASC. It retains direct-delivery symbols
and publishes fleet catch-up when its own delivery completes. The public workflow
publishes the annotated GitHub release after store preparation, independently of
direct delivery. Every resumable mutation rechecks current tag admission. Apps and gateway
preserve their existing protocol compatibility, so upload has no gateway-version
ordering dependency. Public contributions never execute on personal runners.

`just setup` prepares optional local identity overrides; it generates no project.
Local development/install commands retain their source, cache and device leases.
`docs/release-pipeline.md` records the ownership decision and retry contracts.

## Engineering invariants

The app stays smooth on the phone because of the rules below, and most
performance regressions break one of them in a change that looks harmless.
Each rule names the owner that already implements it; extend that owner rather
than adding a parallel path. The area files and `docs/system-architecture.md`
hold the details. Smoothness outranks accessibility polish and minor UX
details, and AppKit, UIKit or lower-level APIs are welcome wherever they
measurably beat SwiftUI.

**Main actor**
- The main actor applies prepared state and does not parse, decode or perform
  I/O. Markdown and syntax highlighting run on `RenderedMessageStore`'s render
  actor; gateway notifications are filtered and decoded by the `@concurrent`
  pump in `GatewayEventPump`; images go through the `ImagePreparation` actor;
  checkpoints are written by the `ConversationCheckpointStore` actor. Streaming
  delivers many deltas a second, so per-delta main-thread work shows up directly
  as hitches and heat.
- `ConversationSession` paces snapshot publication: live-only updates (streamed
  deltas and plan and diff updates) publish at most once per
  `streamingPublicationInterval` (80 ms), and every other change publishes
  without waiting for it. Each publication costs the main actor
  several milliseconds of SwiftUI work, so do not add a path that publishes per
  delta.
- `ChatScreenModel.streamItems` always holds the latest snapshot but notifies
  observers only when rows change, not when a streaming message's text grows.
  That text reaches its bubble through `RenderedMessageStore`, so the
  transcript body does not re-run per delta. A row's captured message can
  therefore lag while it streams; a view or action that needs the live text
  reads the render entry while the message streams
  (`ChatMessage.markdownSource(rendered:)`).

**Work proportional to change**
- A streaming update costs work proportional to the new text, not to the
  message or the transcript. The Markdown parse re-splits only the tail and
  reuses settled blocks. When changing the splitter, keep the chunked-equivalence
  test in `StreamingRenderingTests` passing.
- Projections memoize derived per-row values by their inputs, as
  `CondensedPathCache` does for sidebar paths.
- Everything that grows is bounded: stream buffers, the history window
  (`HistoryWindow`), caches (`RenderedMessageStore`, `RecentConversationCache`,
  `HistoryPageCache`),
  concurrent reads (`HistoryReadScheduler`, the workspace's
  `refreshConcurrency`), gateway queues and mounted transcript rows. A new
  queue, cache or fan-out needs an explicit limit and a drop or eviction policy.

**SwiftUI invalidation**
- Observation tracks every property a `body` reads, so read the narrowest
  state. A bubble observes only its own render entry, and the closed drawer
  reads no live sidebar state.
- View inputs must be cheap to compare and must stop changing once settled.
  SwiftUI diffs inputs with `==`. `RenderedMarkdownBlock` therefore compares by
  render version. Never make that comparison content-based, and never use the
  version as `ForEach` identity. Clocks, timelines and animations stop when
  nothing is moving.
- Streaming text never animates per revision. Bubbles animate geometry and new
  blocks' opacity only (`.contentTransition(.identity)`).
- Each observation has one owner. Transcript visibility comes from a single
  `onScrollTargetVisibilityChange` on iOS and `AppKitTranscriptContainer`'s
  bounded native row index on Mac; do not add per-row visibility tracking.
  iPhone HTML occurrences track visibility only for first live-page admission;
  transcript visibility and already-live page retention remain row-owned. The
  iOS transcript stays eager and windowed. Mac virtualizes separate row hosts
  over bounded logical geometry, with native estimate correction and stable
  coordinates. Cached-height placement must not remeasure or replace unchanged
  roots. Read
  `docs/system-architecture.md` (*History and live state*) for the mechanism and
  the prohibitions in `RemoteCoder/AGENTS.md` before changing layout or
  scrolling.
- A control action never switches what a window presents inside the action.
  On iOS 27, an Observation `willSet` that runs inside a SwiftUI control
  action, after the action has already queued a graph transaction, flushes the
  graph synchronously. A body evaluated there reads the old value and misses
  the store, so a drawer tap left the previous conversation on screen.
  `ChatWorkspaceModel.switchConversation` commits on its own main-actor turn,
  the latest switch wins, and `supersedePendingNavigation` cancels it. New Chat,
  the host picker and model or account moves still commit inside their actions.

**Concurrency and state**
- Swift 6.4 strict concurrency applies project-wide. Actors own shared mutable
  state (`GatewayClient`, stores, schedulers). Models are `@Observable
  @MainActor final class`, never `ObservableObject`; they are owned with
  `@State` and passed as plain or `@Bindable` references. Non-Sendable
  dependencies and caches are `@ObservationIgnored`.
- `@unchecked Sendable` and `nonisolated(unsafe)` are reserved for SDK
  boundaries: real-time audio callbacks, delegates, and SDK types not yet
  annotated `Sendable`. The safety argument must be local and visible, such as
  a lock owned by the type, an immutable box, or a callback that runs
  synchronously. Never use them to silence a diagnostic.
- Every long-lived task has an owner that cancels it: host retirement, scene
  backgrounding or teardown. Actors are reentrant, so after each `await`,
  recheck the fence, generation or revision before publishing. A late result
  must never overwrite newer state; `ConversationSession` and
  `RenderedMessageStore` publish only results matching their current identity
  and revision.
- Persist on meaningful events, not on every change. Checkpoint saves coalesce
  (1 s when idle, 5 s during an active turn). Sends, acknowledgements,
  completion, backgrounding and eviction flush immediately.
- No force unwrapping: use `guard let`, `if let` or a thrown error. Use the
  SwiftUI lifecycle; `App.swift`'s delegate adaptor exists only for APIs that
  require one.

**Measuring**
- Measure before and after on the cabled test iPhone, not in the simulator; the
  test iPad is the second device for its layout and for parallel traces.
  Compare traces only from the same device.
  `just perf-trace record <label> --device <UDID>` records Instruments on
  the primary service host the test devices are cabled to and summarizes CPU time by thread, Core
  Animation commits, GPU time and hitches; its `motion` block limits them to the
  transcript's `TranscriptScroll` signposts and gives Apple's hitch rate.
  `--frames` ranks the main thread's top functions by self time and `--callers`
  attributes system work to app frames. Drive the journey with
  `dev-tools/perf-sim` or by hand: XCTest-based drivers (agent-device, XCUITest,
  Xcode device interaction) snapshot the app on its main thread. The
  `perf-sim` replay's magnitudes are not yet field-calibrated; read
  [`docs/performance-replay.md`](docs/performance-replay.md) before relying on them.
  The detector also includes accessibility user-testing snapshot and MIG frames
  outside `/Developer/Library`. `perf-trace` reports main-thread CPU with and
  without automation and their CPU share and rejects a trace when automation exceeds
  1% of app CPU or main-thread CPU, or when an observed automation share is unknown.
  `dev-tools/streaming-motion-report` measures streaming jitter from a screen
  recording.
- `perf-trace record --template` selects `Time Profiler` (default),
  `Processor Trace`, `Swift Concurrency`, `System Trace`, `File Activity`, or
  `Allocations`; repeat `--instrument` to add Apple instruments. Processor
  Trace defaults to 5 seconds and requires A18+/M4+ hardware plus the device's
  Developer → Processor Trace setting. Both cabled test devices are older and
  cannot record it. Single-process attachment requires a debuggable install
  signed with `get-task-allow`; distribution builds are excluded from attach
  discovery. Mac recording also needs Developer Tools profiling access.
  Other templates retain Time Profiler for the XCTest-driver rejection.
  File Activity reports logical bytes and operations by exported path (an
  unavailable path stays unknown), System Trace reports blocked thread time,
  Swift Concurrency reports task states and actor queues, and Processor Trace
  reports observed function-call intervals and self cycles. Processor Trace
  backtraces resolve by UUID through the same dSYMs; its elapsed self duration
  can include off-CPU waits, so use self cycles to rank CPU work. Unsupported export
  tables, including allocation events on current Xcode, stay unavailable. Each
  measurement that hits a guard reports `exceeds export limit` in `exportFailures`;
  other measurements remain available. Recording, its post-processing and exports
  share the quarter-memory bound for xctrace and Python combined, using the larger
  of resident memory and physical footprint per process. A recording has its
  requested duration plus 120 seconds to finish; each export has 120 seconds.
  Each xctrace process owns a private TMPDIR removed after it is reaped, including
  on failure. The XML parser detaches consumed rows, interns frames, and checks its
  own budget while reducing the table. Sampled-frame and journey analysis share
  the measurement boundary; unavailable frame details preserve app CPU totals.
  `--frames` includes UUID/address/source and inline-frame details alongside
  the existing frame aggregates. Device builds mirror their matching dSYMs to
  the configured tracing host under leased `RemoteCoder-Build/runs` retention;
  published release symbols remain in the deployment owner's symbol retention.
  A trace without app CPU samples fails with a diagnostic. On a device that
  records only the kernel, verify the app is foreground and unlocked, then
  repair its profiling services before collecting another measurement.
- Low Power Mode and serious or critical thermal states set
  `AppEnergyPolicy.conservesEnergy`, which switches rendering and prefetch
  paths. A hot phone therefore runs different code, not just slower code.
  Compare traces only within the same energy state. `AppEnergyMonitor` logs
  that state at launch and on every change (category `Energy`), so uploaded
  app logs show which state a period ran in.
- Known dead end: on iOS, `OSLogStore` ignores `position(date:)` and reverse
  enumeration (Apple DTS r.87416514, r.87622922), and predicates do not shorten
  its scan, so every read enumerates the whole process lifetime. App logs reach
  the host through `AppLogger` at the call instead; never read them back.

## System invariants

These hold across the app and the gateway. Each is detailed in the area files.

- **Unknown stays unknown.** An unavailable or unread value (usage, question
  coverage, external activity, timestamps, settings readback, token usage) is
  reported as unknown or absent, never as zero, empty, idle or a guess.
- **Identity is exact.** Thread ids are unique only within one gateway, so the
  app addresses conversations by host and thread (`ConversationAddress`). A
  Claude launch never falls through to a fresh session, a history read never
  invents a turn id for a running prompt, and a notification tap never falls
  back to a guessed host.
- **Latency is telemetry, not restart authority.** Slow application RPCs and
  socket-probe failures never restart the gateway. A failing Claude preflight
  never changes the top-level `status` or removes `codexPid`, which installs
  gate on through the authenticated `/health` contract.
- **Turns have no wall-clock cap** in either provider. A turn ends when the
  agent ends it, the process dies or the user interrupts.
- **Planned restarts interrupt and resume exact work.** A gateway SIGTERM
  (deploy, installer handoff, `just gateway-restart`) interrupts active turns at
  once, and the replacement resumes each exact Codex turn in the host-default
  runtime and each Claude thread in the host-default profile. Retiring a legacy
  enrollment transfers its exact interrupted work into the default recovery
  journal before committing adoption. Nothing waits for a turn to finish, and
  nothing substitutes a new thread or guesses an identity.
- **Secrets stay on the hosts.** Never log or commit the gateway bearer or any
  token. When the optional router is enabled, it owns speech and title provider
  keys; each configured gateway holds one router key. `scripts/release-config.py` limits release bundles
  to public fields and development installs to public fields plus the gateway
  token.
- **macOS permissions have separate owners.** SimpleMDM owns supported TCC
  grants. Local Network has no per-app MDM grant; the gateway's LaunchAgent and
  cold-start launcher keep its bundle association and selected LaunchServices
  registration current. A new-version LAN read proves that consent persisted.
- **One owner per concern.** One transcript owner (`ConversationSession`), one
  external-event router (`ExternalEventRouter`), one agent-tool registry for both
  providers, one Liquid Glass entry point (`AppGlass`, guarded by
  `scripts/lint-glass`), one haptic catalog (`HapticService`, guarded by
  `scripts/lint-haptics`), one voice call (`VoiceCallCenter`, whose
  `CallSystemBridge` owns the `ConversationManager`) and one place for platform
  imports (`Platform/`, `Services/`, guarded by `scripts/lint-platform-imports`).
  Extend the owner; do not add a parallel path. `docs/glossary.md` names each
  owner, and `docs/system-architecture.md` (*iOS ownership layers*) shows how
  they nest.

## Observability

[`docs/host-observability.md`](docs/host-observability.md) is the logging and
diagnosis contract; read it before investigating a past gateway, reconnect,
notification, Voice Mode or iOS lifecycle incident. All host records live under
`~/Library/Logs/remote-coder/`: the daily gateway journal, tracing logs,
uploaded iOS OSLog segments, per-call voice logs, ChatGPT
desktop-reconciliation decisions, deployment logs and launchd redirects. Query
the journal with `just gateway-journal ...`, and use
`just gateway-desktop-journal ...` to see why the shared-Codex launcher did or
did not stop and reopen ChatGPT. Never log the gateway bearer token. App
lifecycle evidence goes through `AppLogger` at `.notice` or higher; a plain
`os.Logger` `.debug` is for high-frequency stream noise the journal already
captures.

## Documentation map

Open the focused source before changing that part of the system:

- [`docs/glossary.md`](docs/glossary.md): the vocabulary, each term's owning
  type and contract doc. Rename code, docs and copy together when a meaning
  changes.
- [`docs/system-architecture.md`](docs/system-architecture.md): end-to-end
  topology, iOS ownership layers, providers, composer drafts and attachments,
  history and live state, lifecycle and recovery, voice paths, speech relay,
  persistence contracts.
- [`docs/repository-model.md`](docs/repository-model.md): repository
  boundaries, Git topology and release flow.
- [`docs/host-observability.md`](docs/host-observability.md): logs, the journal
  and the retrospective diagnosis workflow.
- [`host-daemon-rs/AGENTS.md`](host-daemon-rs/AGENTS.md): the shared
  app-server, gateway connections, runtime package, restart and recovery
  contracts.
- [`host-daemon-rs/README.md`](host-daemon-rs/README.md): gateway and runtime
  configuration, installation and local operation.
- [`docs/owned-operations.md`](docs/owned-operations.md): operation ownership,
  build receipts, leases, installation credentials and persistence.
- Feature contracts: [`docs/conversation-agents.md`](docs/conversation-agents.md),
  [`docs/automations.md`](docs/automations.md),
  [`docs/async-questions.md`](docs/async-questions.md),
  [`docs/remote-files.md`](docs/remote-files.md),
  [`docs/provider-accounts.md`](docs/provider-accounts.md),
  [`docs/provider-health.md`](docs/provider-health.md),
  [`docs/usage-status.md`](docs/usage-status.md),
  [`docs/persistence-energy.md`](docs/persistence-energy.md),
  [`docs/haptics.md`](docs/haptics.md),
  [`docs/directory-quick-switch.md`](docs/directory-quick-switch.md),
  [`docs/reasoning-picker-motion.md`](docs/reasoning-picker-motion.md),
  [`docs/mermaid-rendering.md`](docs/mermaid-rendering.md),
  [`docs/html-visuals.md`](docs/html-visuals.md),
  [`docs/link-chips.md`](docs/link-chips.md),
  [`docs/live-navigation.md`](docs/live-navigation.md) (LPSE wake, encrypted
  event stream, headless Google session, tracer gate), and
  [`agent-calls/README.md`](agent-calls/README.md) (agent-initiated calls).
- [`docs/codex/compatibility.json`](docs/codex/compatibility.json): the exact
  approved ChatGPT/Codex/runtime identity and public acceptance requirements;
  host-specific evidence stays in the private operations repository.
  [`docs/compatibility-register.md`](docs/compatibility-register.md) lists the
  compatibility paths the app and gateway still carry and their removal
  conditions.
- Protocol drift: compare exact fork revisions with
  `git -C <codex-source-checkout> diff <old> <new> -- codex-rs/app-server-protocol/`;
  `CODEX_BIN=<candidate>/bin/codex just codex-schema` generates an ignored
  `build/codex-schema/<version>/` for inspecting the candidate wire schema.
- Current upstream Codex behavior: the fork's
  `codex-rs/app-server-protocol/src/protocol/` types, the generated schema, and
  `codex-rs/app-server/README.md` (upstream notes plus the fork's integration
  protocol sections; upstream removed its full guide in #43421), plus
  `live-official-docs`.
- Private plans, acceptance records and incident evidence stay in the private
  archive or deployment repository. Current code and these contract docs win.

## References

APIs and platform guidance change every release, so prefer these live sources
over memory or copied snapshots. Use the `live-official-docs` skill
(`official-docs apple search|fetch|symbol`) for current Apple API contracts,
and the `swift-development` skill's performance, concurrency and scrolling
references for technique.

Codex upstream:
- [OpenAI Codex CLI (official repo: source + docs)](https://github.com/openai/codex)
- [Codex `app-server` source code](https://github.com/openai/codex/tree/main/codex-rs/app-server)
- [`codex-rs/app-server-protocol` (wire types and generated schema)](https://github.com/openai/codex/tree/main/codex-rs/app-server-protocol)

Performance and responsiveness:
- [Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)
- [Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness) and [Understanding hangs in your app](https://developer.apple.com/documentation/xcode/understanding-hangs-in-your-app)
- [Improving your app's performance](https://developer.apple.com/documentation/xcode/improving-your-app-s-performance), Apple's performance hub
- WWDC26 [Profile, fix, and verify: Improve app responsiveness with Instruments](https://developer.apple.com/videos/play/wwdc2026/268/), WWDC25 [Optimize SwiftUI performance with Instruments](https://developer.apple.com/videos/play/wwdc2025/306/), WWDC23 [Demystify SwiftUI performance](https://developer.apple.com/videos/play/wwdc2023/10160/)
- WWDC26 [Dive into lazy stacks and scrolling with SwiftUI](https://developer.apple.com/videos/play/wwdc2026/321/): general background; iOS stays eager and Mac owns native virtualization as described in `RemoteCoder/AGENTS.md`

State and concurrency:
- [Observation](https://developer.apple.com/documentation/observation) and [Managing model data in your app](https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app)
- [The Swift Programming Language: Concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/), the [Swift 6 migration guide](https://www.swift.org/migration/documentation/migrationguide/), and WWDC25 [Embracing Swift concurrency](https://developer.apple.com/videos/play/wwdc2025/268/)
- Gateway (Rust): the [Tokio tutorial](https://tokio.rs/tokio/tutorial), especially [Channels](https://tokio.rs/tokio/tutorial/channels) on bounded backpressure
