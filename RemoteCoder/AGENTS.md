# iOS App Agent Context

Maintainers: configured hosts, devices and private operational prerequisites live
in the [private operations entrypoint](https://github.com/emileberhard/RemoteCoder-deploy/blob/main/AGENTS.md).

Rules for the iOS client: this directory, `Shared/`,
`RemoteCoderLiveActivities/` and the test targets. The root `AGENTS.md` also
applies, including its engineering invariants. For Swift and SwiftUI technique,
use the `swift-development` skill; this file records only RemoteCoder's
ownership, contracts and known failure modes. `docs/system-architecture.md`
holds the detailed history, recovery, voice and persistence contracts.

## Verify

- The root file decides which checks a change needs. `just install-dev`
  and `just verify` also run `scripts/lint-glass`,
  `scripts/lint-haptics` and `scripts/lint-platform-imports`, which enforce the
  shared glass and haptic entry points and the platform-import boundary below.
- `just ios-ui-test` explicitly drives the multi-host drawer. It opens the drawer from
  `open-conversations`, proves rows from more than one gateway are listed
  (`conversation-row-<host uuid>|<thread id>`), and selects one row per host,
  asserting that `active-host` follows the row's owner. It needs a simulator
  that already has several gateways with cached conversations, so it has its
  own scheme and stays out of the default Mac-native suite. `just ios-simulator-test` runs the
  remaining app-hosted integration tests only when the root policy calls for them.
  HTML visual fault tests that spin WebContent processes are opt-in through
  `RC_HTML_VISUAL_FAULT_TESTS=1` in the hosted test process environment (for
  example its test scheme), only on an isolated GUI test host. Never enable
  them on a live service host. Select that host explicitly with
  `RC_IOS_BUILD_HOST=<configured-gui-test-host>`.
- App layout: `App/` (scenes, `RemoteCoderAppModel`, `ExternalEventRouter`,
  intents), `Workspace/` (workspace, `ChatWindowModel`, per-target registry and
  flows), `Chat/` (`ChatTargetModel`, `ChatScreenModel` and their owners), `UI/`
  (SwiftUI; `Chat/`, `Conversations/`, `Agents/`, `Accounts/`, `Files/`,
  `Settings/`, `DirectoryPicker/`, `DesignSystem/`), `Services/` (needs SpeechKit
  or WebRTC but not UIKit: voice calls, speech, transcription, file and account
  clients) and `Platform/iOS/` (iOS-only bridges: system calls, notifications,
  Live Activities, Live Navigation, audio capture, haptics playback, camera).
  `Platform/macOS/` holds the Mac arm of each same-named seam (a null
  `VoiceCall`, the source-list history sidebar, Quick Look file presentation,
  `ForegroundOnlyBackgroundExecution`), `RemoteCoderMacApp`, its
  `RemoteCoderMacAppDelegate` (owner of the app model, `AttentionCenter`,
  `QuickEntry`, `InterfaceZoom` and `AppKeyMonitor`; launch and termination,
  APNs tokens, the notification-center delegate and the Dock menu) and the Mac
  attention surfaces. Shared code
  calls the seam; a plain `#if os(iOS)` is only for a single modifier or
  property with no Mac counterpart.
  `lint-platform-imports` rejects UIKit, ActivityKit, CallKit, PushKit,
  LiveCommunicationKit, CoreHaptics and GoogleNavigation imports outside
  `Platform/`, `Services/`, the extension roots and its named bridge list, and
  any UI framework import in `Core/`. Its `SEAM_DEBT` list is debt to shrink,
  not a place to add files.
- An indefinitely repeating symbol animation goes through `WorkingSymbol`;
  `scripts/lint-symbol-effects` enforces this in `just verify`:
  the iOS arm runs UIKit's variable-color effect on a `UIImageView` and the
  Mac arm draws the symbol still. A SwiftUI `.symbolEffect` that repeats
  re-renders its window every frame on both platforms. On macOS 27 one working
  sidebar row cost about 40% app CPU plus as much again in WindowServer, also
  while another app was frontmost, and the same effect on an AppKit
  `NSImageView` still makes about 18 Core Animation commits a second per
  symbol. On iPadOS 27 a working row in the persistent sidebar held the app at
  about 118 commits a second while a reply streamed. The UIKit effect runs on
  the render-box animation thread; with the other 1 October changes the same
  window fell to 70 commits a second. The composer's spinner runs in the
  render server with no app commits. The timeline's `ThinkingDots` do too: on
  iOS they are discrete Core Animation keyframes on three layers, and the Mac
  arm draws them still. A running `TimelineView`, even a periodic one, keeps
  the display link re-evaluating the view graph; the earlier SwiftUI dots cost
  about 2 s of main-thread time per 41 s streamed reply (October 2026,
  perf-sim), and the UIKit symbol effect's first use took a 160–350 ms frame.
  Use neither for a repeating transcript decoration. Mac decorations
  stop while macOS reports their window occluded: `WindowVisibility` feeds the
  occlusion state into `visualsVisible`. Hiding the app occludes the window,
  but with Stage Manager on, a covered window stays visible as a live
  thumbnail and keeps animating.
- The Mac interface zoom is `InterfaceZoom`: View → Actual Size (⌘0), Zoom In
  (⌘+ and ⌘= through `AppKeyMonitor`, preserving the active layout’s Shift
  translation) and Zoom Out (⌘−), 80–200 %, persisted
  per Mac. `InterfaceZoomCommands` is app-level and separate from the
  window-level `ChatCommand` list. The delegate's zoom reaches every window,
  Settings and Quick Entry as `\.interfaceScale`; on iOS it is always 1.
  macOS has no Dynamic Type, so shared and Mac UI set fonts with
  `scaledFont(_:)`, fixed control frames and readable widths with
  `scaledFrame`, and metrics with `@InterfaceScaledMetric`
  (`UI/DesignSystem/InterfaceScale.swift`); `scripts/lint-interface-scale`
  rejects `.font(` and `@ScaledMetric` outside `Platform/iOS/`. Other derived
  sizes (ring diameters, the sidebar column width, the composer's `NSTextView`
  font) multiply by `interfaceScale` themselves. Menus, the toolbar and other
  system chrome stay native size.
- `Core/Sources/RemoteCoderCore/` owns platform-independent production sources.
  Both the app target and the Swift package compile those exact files; do not
  copy them back into the app or introduce a test-only implementation. Add pure
  logic tests under `Core/Tests/RemoteCoderCoreTests/`. Keep actual UIKit/SwiftUI
  hosting and iOS SDK integration tests under `RemoteCoderTests/`.

## Public configuration

`Config/RemoteCoder.xcconfig` owns example bundle, App Group, CloudKit and signing
defaults; ignored `Config/Local.xcconfig` supplies operator overrides. Derive
extension identifiers and runtime group/container access from the same settings.
No private runtime seed or Maps key is required to compile basic chat. Maps stays
unavailable without a key. Gate speech on `host/info.speechAvailable` and resolve
automation authority through reported physical `hostname`/`automationsAuthority`,
never a personal hostname or display-name heuristic. Missing capability evidence
stays unavailable. Keep the full maintainer values in the private operations
entrypoint linked above.

## Workspace and hosts (`Workspace/`, `Chat/`)

- `docs/system-architecture.md`, *iOS ownership layers*, draws the tree and
  lists each invariant's owner. `RemoteCoderApp` holds one `@State` root in
  `App.swift`, `RemoteCoderAppModel`, which owns the `ChatWorkspaceModel`, the
  `VoiceCallCenter`, the `ExternalEventRouter` and the device-wide services.
  The chat root (`ChatRootView`) owns bootstrap and teardown and forwards scene
  phase, notification taps and token updates.
- `ChatWorkspaceModel` owns one `ChatTargetModel` per configured execution target
  (one per host), through `ExecutionTargetRegistry`.
  - A model's host, gateway client, history and metadata services,
    conversation index, `HostDirectories` and Live Activity service are fixed
    for its lifetime. Switching hosts only changes which model is presented;
    other models keep their socket, draft, selected conversation and running
    turns.
  - A hidden model with no running turn, voice call or open drawer stays off
    the network: it defers the foreground refresh and its LAN move until it is
    shown. Fan-outs start with the visible model.
  - Each scene's `ChatWindowModel` owns its own selected target, drawer state
    and one `ChatScreenModel` per target. A screen shows one unsent draft
    (`newChatDraftID`); windows do not own drafts, and at most one screen per
    target holds a given draft.
    The key window's selection is mirrored into `HostStore.activeHostID`, the
    persisted last-used host, so Shortcuts, direct exec and workspace
    navigation agree on it. Both providers use the physical host default.
  - The workspace records the visible conversation's `ConversationAddress`, or
    its absence for New Chat, and bootstrap reopens it from the persisted
    history headers (the gateway only when the header is not cached). A
    launching notification tap or any navigation before the header arrives
    supersedes the restore, and nothing is recorded until it has settled.
  - `models` is the one authoritative, observed registry. Replacing a model
    (an endpoint or token edit keeps the host id) invalidates the views bound to
    it. There is deliberately no second lookup cache.
  - `reconcileHosts()` adds models for new hosts and relabels renamed ones
    (`GatewayHostConfiguration.hasSameConnection` ignores the display name). It
    retires a model whose endpoint or token changed instead of rebinding it.
- `HostStore` syncs the host list through iCloud Keychain (`HostDirectory`,
  contract in `docs/owned-operations.md`, *Credentials and transport*). A host
  absent on one device is added, never deleted elsewhere; only an explicit
  deletion's tombstone removes it. Installation tokens, incoming-call identity
  and the active host stay per device.
- **Synced preferences.** `SyncedPreferenceStore` (owned by the workspace)
  replicates the user defaults keys in `ChatWorkspaceModel.syncedPreferenceKeys`
  through every host's `preferences/*` (host-daemon-rs `AGENTS.md`). Each
  host's `SyncedPreferenceExchange` reads and pushes when it connects, and the
  workspace asks the connected hosts again on app activation and on every
  change to the replica, including one received from another host; a
  disconnected host catches up when it connects. The defaults keys stay the one
  local value store, so owners keep writing them normally: the store diffs the
  synced keys against its versioned replica on each defaults change, and the
  newest change per key wins on every device. A value present before a device
  first synced is adopted at version 0 and never published, because earlier
  versions wrote defaults into these keys; it stays on that device until a
  change made anywhere replaces it.
  - Persist only a user's choice to a synced key. A fallback or default the
    app computes stays in memory (`VoiceCall.effectiveVoice`,
    `AppThemeStorage.loadSelectedThemeID`); writing it would overwrite the
    choice on every other device.
  - A value from another device is written to defaults, then
    `RemoteCoderAppModel` reloads the owners that cache it in memory. An open
    blank chat keeps its setup; a changed new-chat default applies to the
    next new chat. A new
    synced key needs its owner's reload there unless every reader reads
    defaults on demand. A reload applies the owner's default for an absent
    or unparseable value and writes nothing back: owners apply reloads to
    their in-memory state, not through the setters that persist a choice.
  - Device-local by design: notifications, haptics, Mac zoom and quick entry,
    working directory per host (host ids are per device), drawer
    folds and filter, and push and installation identity.
- **Retirement is fenced synchronously.**
  - `ChatTargetModel.beginRetirement()` runs before the model leaves the
    registry. It marks the model retired, closes its `OwnedTasks` set to new
    work and cancels every task in it (bootstrap, warm-up, timeline-seed,
    history invalidation and the rest; a slot clears itself when its task ends
    and a replaced task never clears its successor's slot), and cancels the
    `TurnDispatcher`'s sends, steers and Stops. It ends a voice call only if that host
    owned it. `retire()` then closes the socket, the host directories and the
    Live Activity, and joins every admitted task, replaced ones included.
  - Every suspension point in `prepareIfNeeded`, `handleScenePhaseActive` and
    turn dispatch rechecks the fence on resume. Late work therefore cannot
    restart polling, send a turn, or publish into the replacement that now owns
    the address.
  - Old and new models share host-scoped files, so this ordering is what stops a
    predecessor from overwriting its successor's state.
  - After admitted work and draft submissions drain, target retirement awaits
    `ComposerDraftStore.retire()`. The store finishes pending saves, retires its
    persistence actor and releases the context/container owner. Later storage
    operations fail with the typed retired error; synchronous editor operations
    surface that error without applying changes.
- Foreground work carries a scene generation. A pass that resumes after the app
  went to background stops instead of re-arming prefetch, polling and
  transcript refresh, and `handleScenePhaseBackground` cancels the fan-out.
  Every scene phase also starts a workspace pass that supersedes the previous
  one. Each phase change runs in its own task, and the background pass awaits
  each host in turn, so a pass still in flight when the app returns must stop
  before it backgrounds the remaining hosts; one once disconnected a hidden
  host's socket while the app was on screen. `.stopLoops` runs only while
  the reducer's scene is not live, so a late background batch cannot stop the
  loops a reactivation started.
- Bootstrap, pull-to-refresh, drawer visibility and scene-phase fan-out run at
  most `refreshConcurrency` hosts at a time (`BoundedFanOut`), key target first,
  on a sliding window: each worker takes the next host as it finishes, so one sleeping
  laptop delays only itself. A failing host keeps its cached rows and owns its
  error. Every fan-out task is owned, so `teardown()` can cancel it.
- `ConversationAddress` (host UUID + thread id) addresses everything, because
  thread ids are unique only within one gateway. Every row, selection check, pin
  command and action route carries the host. The pure
  `ConversationSidebarProjection` ranks rows below a Pinned header
  (`ConversationDrawerRank`) or groups them into project sections, with the
  composite address as a stable tie-break, and hides the host label while only
  one host is configured.
- Host-local state lives under `RemoteCoder/hosts/<host uuid>/`
  (`HostStorage`) or behind a host-suffixed defaults key. That covers
  the conversation index, conversation metadata, thread-header cache, token
  usage, usage snapshot, voice history, working directory and the conversation
  marks replica (pins, read state, purposes and settlements).
- `HostScopedStateMigration` splits pre-multi-host state once, moving only items
  with one provable owner. Anything ambiguous is reported as a limitation, never
  copied onto every host.
  - It is synchronous and runs from `ChatWorkspaceModel.init`, before any
    consumer can read host state. A migration that once ran later was silently
    overwritten by the very stores it meant to seed.
  - The pin and working-directory defaults initialize synchronously. The
    conversation-index actor defers its one-time disk load to its first isolated
    operation.
  - It reads through `ConversationHeaderStore.cachedThreadIDs` and
    `ConversationIndex.legacyEntriesSynchronously` and adopts into the real
    per-host files, so the live actors load already-migrated state.
- There is no shared working-directory fallback. `LocalConfiguration.codexWorkdir` is one
  machine's path, so only the host that owned pre-multi-host state adopts it.
  Other hosts resolve their own remote home
  (`adoptRemoteHomeAsWorkingDirectoryIfUnset`), and the header offers
  "Choose Folder" until they have one.
- Device-wide services stay single but are host-aware:
  - `AccountRetirementMigration` imports every UUID enrollment folder into its
    host before target construction, off the main actor. Preserve draft identity,
    setup and import receipts; merge checkpoints through their existing owner.
    Discover folders independently of loaded hosts; release each host after its
    import attempt. Journal checkpoint imports before consuming sources.
    Honor earlier Claude completion; reclaim completed
    folders only when no protected recovery bytes remain. Restart cancelled
    imports before admitting their hosts' models.
    Independent New Chat slots and restored windows retain their setup.
    Preserve pending mark IDs and order. Scope old read-all operations with the
    gateway's immutable retirement scopes, including the default scope once
    before model admission. Keep cached marks metadata, but require a full marks
    read advertising `supportsRetiredScopeRead` before its read coverage becomes
    known or pending edits flush; a delta cannot clear that requirement. Failed imports retain sources, stop after
    three attempts and surface a workspace issue. Old serialized
    addresses never restore an enrollment connection.
  - **Completion routing.** `TaskCompletionRouting` sends a completion tap to
    the host the payload names, and the payload always names one. If that host
    was deleted, the tap is unresolved, because another gateway with the same
    thread id is a different conversation. There is no lookup by thread id and
    no fallback to the visible host's smart match. Question alerts use the same
    routing; tapping one opens the conversation and reveals the card.
  - **Notification presentation.** Broker/APNs delivery is the sole alert
    source; socket lifecycle and replay update state without creating banners.
    `ForegroundNotificationPresentation` and the workspace use one bounded,
    persisted event ledger for proven owners; unknown host never
    deduplicates distinct deliveries. `CompletionNotificationOverlay` attaches
    one non-key, touch-passthrough window to the SwiftUI scene, above sheets and
    full-screen covers; expiry starts when its banner renders and pauses while
    it is touched. A swipe in any direction, projected by its release velocity,
    dismisses it, and the UIKit pan cancels the banner's button, so only a tap
    opens the conversation. VoiceOver gets Dismiss and Escape. Foreground alerts,
    including generic and malformed payloads, use this in-app surface. Exact
    open host/thread matches stay silent. Explicit audio may
    play its sound without another visual surface. Inactive/background delivery
    uses the system surface; activation and socket replay never create banners.
    UIKit state is sampled after off-main payload preparation, and inactivity
    clears the banner synchronously. Notification taps own a task/generation,
    prepare the exact thread without changing selection, then commit behind a
    navigation fence. A newer tap or explicit navigation invalidates old work
    (`supersedePendingNavigation`). On the Mac, "active" means frontmost
    (`NSApplication.isActive`) and the foreground surface is the system banner
    (the Mac arm of `ForegroundNotificationSurface`); exact open matches still
    stay silent.
  - **Mac attention surfaces.** `AttentionCenter` observes
    `ChatWorkspaceModel.attentionInputs`, publishes the pure `AttentionSummary`
    only when it changes, without reading selection, loading, project or
    captured drawer state, and sets the Dock badge to the known count of unseen
    questions that no settlement covers (`docs/async-questions.md`,
    *Attention*; no badge while no count is known or the count is zero). The
    Dock menu and the menu bar item (`AttentionStatusItem`) list at most eight
    conversations, those needing you before running ones, both classified by
    `ConversationDrawerRank`, so a request that settlement covers never needs
    you; `AttentionCenter` rechecks when the next uncovered request turns
    three days old and when the system clock changes. They name the hosts
    whose activity is unknown instead of counting them as idle.
    Every action goes through `ExternalEventRouter`. The menu bar item is an
    AppKit `NSStatusItem` that changes its image only when "needs you" flips and hosts
    the panel only while it is open, in the non-activating `FloatingPanel` that
    quick entry also uses: it takes key focus without activating the app and
    closes when it loses it. A SwiftUI `MenuBarExtra` re-rendered its label in a
    loop with the menu bar's appearance, costing up to 364 ms of main-thread
    time per second while the transcript scrolled.
  - **Live Activities.** `ActiveTasksLiveActivityScope` keeps one aggregate Live
    Activity per host, so an idle host cannot end another's.
  - **Audio.** Audio has one route. `ChatTargetModel.ownsAudioRoute` gates
    spoken replies to the host on screen, and hiding or retiring a host stops
    the reply it is speaking. Hiding a host completes its in-flight
    dictation into its own draft and releases the microphone. The voice surface
    follows `VoiceCall.callOwner`, the target whose thread the
    call is bound to, not the sidebar selection. `RemoteCoderAppModel` creates
    the one `VoiceCallCenter` and passes it to the workspace and every model;
    its `CallSystemBridge` owns the `ConversationManager`.
  - **Logs.** `DiagnosticsOutbox` follows the visible host.
  - **Field telemetry.** `RemoteCoderAppModel` creates the one
    `TelemetryContext`, which projects existing state for
    `ProcessResourceSampler` and owns only that observation. Features never
    report their state to telemetry; extend the projection instead. See
    [field telemetry](../docs/host-observability.md#field-telemetry).

## Gateway client and history (Core `Gateway/`, `Conversations/History/`, `Wire/`)

- `GatewayClient` is the actor that owns the WebSocket JSON-RPC connection.
  It uses `CodexAppServerV2.JSONRPC.*` envelopes and v2 models for `thread/*`,
  `turn/*` and `command/exec`.
  - Each host's `GatewayRoutes` orders the gateway's published `lanEndpoint`
    first on Wi-Fi or Ethernet, then the configured address, then the relay.
    `GatewayClient` races them, replaces a stalled route with a standby
    connection, and hands idle connections to a preferred route on connect,
    foreground, the idle edge, every network path change and every 30 s off
    LAN, all without reporting a disconnect. `GatewayRoutes` owns the gateway's route
    sessions, and gateway HTTP, including account requests and log uploads,
    goes through `GatewayRoutes.send`. Speech follows
    `GatewayRoutes.preferredRoute()` through SpeechKit sessions that the
    route's `SpeechRelayTransport` configures and pins
    (`docs/system-architecture.md`, *LAN route*, *Relay route*, *Switching
    routes* and *Speech relay*).
  - Timeouts are per request, so one slow call cannot tear down unrelated work.
    Ordinary RPCs get a short timeout and history reads a larger one.
    `thread/start`, `thread/resume` and `thread/fork` allow up to 150 s, because
    Codex may create a shell snapshot and initialize MCP during setup.
  - Cancelling or timing out a sent request removes its local waiter and, only
    when that socket's `daemon/ready` advertises `capabilities.cancelRequest`, sends `$/cancelRequest`
    with the exact request ID on the same connection generation. The gateway
    alone decides whether the request is cancellable; commands and passthrough
    requests ignore it. A terminal `requestCancelled` response needs no local
    waiter.
    `GatewayRequestRecovery` owns at most three capacity retries with exponential
    backoff and jitter inside the original request deadline. Only typed retryable
    capacity errors qualify, proving that work was not admitted; cancellation
    stops recovery. Prefetch and foreground callers share the same request and
    recovery policy when their reads coalesce.
  - The notification stream is a bounded `AsyncStream`. It lets the app reattach to remote turns after reconnect,
    even turns this process did not start.
  - `TurnRegistry` retains the last known agent grouping when an activity
    snapshot reports `agentOwnersCoverage: unavailable`, merging positive incoming
    links over retained ones. `ConversationActivity` derives parent activity from
    current child execution coverage; an idle child retains its grouping without
    implying work, and unknown child activity stays unknown. Complete ownership
    replaces it, including an empty map. An absent coverage field means complete
    for older gateways.
  - Claude content subscriptions come from the existing `ConversationSessions`
    retained-set owner, including live weak bindings. Selection, binding,
    eviction and invalidation publish revisioned intent to this connection.
    One owned sync task serializes replacements and settles the latest intent
    before initialization and reads proceed. Successful sets are acknowledged;
    rejection/timeout leaves an explicit failed state and never tears down the
    socket or blocks history/replay reads. An unchanged rejected set is not
    retried on that connection; a changed valid intent or reconnect can retry.
    Unknown-method codes (`-32601`, or older gateways' `-32600`) mark the
    connection unsupported until reconnect, preserving legacy content fanout.
    The compatibility register owns its removal condition. Stale results cannot
    acknowledge a different intent. The 64-thread/512-byte ID checks reject
    locally before sending, without truncation or blocking initialization/reads.
- `DeviceToolHost` (Core `Gateway/`) owns one running device operation across all
  host connections. Platform tools are injected; iOS registers
  `take_photo`, and the Mac declares an empty list.
  - Every connection declares tools after initialization. A declaration failure
    is non-fatal. Invokes and cancels are notifications; the
    receive loop awaits only admission, never tool execution or result delivery.
  - Operations check their deadline before starting and retain exclusivity until
    cancellation cleanup finishes. Cancel and disconnect apply only to the exact
    connection generation. Results use that generation and never reconnect to
    deliver into a replacement connection.
  - `AgentPhotoCapture` (`Platform/iOS/Camera/`) requires an active scene and
    camera permission. It captures back then front for `both`, using the chosen
    back lens and front wide. Its short-lived video-only session leaves the
    shared audio session unchanged and runs on a dedicated serial executor.
    `ImagePreparation` encodes bounded inline JPEGs. Both captures finish before
    `GatewayUploadClient` uploads originals to the invoking gateway, reserving
    eight seconds before the operation deadline for result delivery. Results
    contain images only, in capture order; upload failures stay in `detail`.
- `GatewayHistoryService` is the actor that owns history pagination for
  both providers, including forks.
  - One thread-wide `HistoryWindow` holds fifty-item `thread/items/list` pages
    and `thread/turns/list` metadata behind a single older/newer cursor pair.
  - `HistoryWindow`, `HistoryPageCache` and `HistoryReadScheduler` bound
    retained pages, bytes and concurrent reads.
  - Every history read starts with `ConversationSession.beginHistoryRead()`,
    which captures its base window and start order. Tail and reset reads apply
    only in start order; directional pages rely on their cursors.
  - Browsing never resumes a thread or requests full history.
- `Core/Sources/RemoteCoderCore/Wire/AppServer/` holds wire models for the app-server
  protocol v2, namespaced under the empty enum `CodexAppServerV2` to avoid
  Foundation collisions (`Thread`, `Notification`). They are the source of truth
  for gateway messages (`CodexAppServerV2.JSONRPC.Message`) and live
  notifications (`item/started`, `item/completed`, `turn/plan/updated`, …).
  `JSONValue` carries protocol fields that are intentionally arbitrary JSON.
- History for both providers uses thread-wide `thread/items/list` pages and
  `thread/turns/list` metadata with opaque directional cursors, including
  forks. Live notifications stay authoritative for current activity. Fork boundaries come from canonical turn
  identity, never a full-history reverse lookup.
- `ConversationIndex` is the actor-backed store mapping Codex thread ids to
  local conversation UUIDs, so resumes and completion routing never rely on
  heuristics.
- `ConversationMetadataService` owns acknowledged metadata and a durable local
  outbox, through typed `conversation/metadata/read|update` RPCs that replaced
  the remote Python whole-map writer. The gateway
  owns `~/.remote-coder/session-metadata-v2.json`, revisions, idempotency and
  cross-process locking. Stale edits need explicit conflict resolution.
- `ConversationHeaderStore` is the actor-backed, per-host cache of known
  `ConversationHeader` values and the last successful refresh. Its retained window
  holds at most 1,024 root conversations; a delegated agent thread is admitted
  only while it is protected (visible, live or asking), and the saved window is
  restored as saved, so an open child reopens offline. Protected threads precede
  pins, then the browsed page, then recent headers, so a page never evicts a pin.
  `ConversationList` owns that policy; the store applies the count bound when
  it loads a file. Previews keep at most 512 characters at the header boundary, which
  bounds each row. Eviction persists incomplete coverage, never a complete or empty
  list. Older/search discovery advances each provider's own cursor and promotes
  the fetched page into the window; a manual refresh returns to newer coverage.
  Missing pins remain exact-address open controls while their headers are unread.
  Protected-header recovery reads at most 32 addresses per pass and backs off
  failed admissions from 30 s to 10 min in a bounded 1,024-entry map; explicit
  manual refresh clears that delay. Stored ancestry is unresolved/root/child;
  only definitive evidence survives as root or child, independently of temporary
  classification-cache eviction. Native spawn/parent evidence remains native.
- **Notification pump.** The global notification stream is consumed off the
  main actor.
  - `GatewayNotificationRouting` filters uninteresting methods, extracts turn
    identity and decodes typed payloads in a `@concurrent` pump. The pump hands
    every turn event straight to its `ConversationSession`; the main actor sees
    only lifecycle events (`turn/started`, `turn/completed`, `item/started`,
    `item/completed`) and non-turn events. Streaming deltas never touch it, and
    transcript snapshots reach it only through the selected session's snapshot
    stream. Session mutators therefore return nothing, with two kinds of
    exception: `submit` returns its snapshot so a send shows its row before
    the transcript scrolls to it, and `merge` and the question merges return one
    because their callers read its content.
  - Each target model owns one `GatewayEventPump`, which holds the pump task, the
    generation, a monotonic notification cursor and gap recovery, and hands
    events to the model through `GatewayEventSink`. The pump replays after
    it on every restart and advances it to the replay response's latest sequence
    after applying the batch. Disconnect replay routes its whole batch off-main,
    then applies the routed events in order, one main-actor apply per event.
  - The stream is `bufferingNewest(512)` and can drop older stamped frames. The
    client finishes the stream once buffered values drain, keeps the lowest
    dropped sequence as a replay floor and emits a `historyGap` connection
    event; the pump enqueues the gap and, on its restart, reads the floor from
    the client and replays from just before it. The same event stream reports
    connects and disconnects to the model, so nothing polls the client.
  - Active turns are inferred from lifecycle notifications and the pushed
    activity snapshot, so history spinners and timelines stay live after a
    force-quit and relaunch.
- **Lifecycle.**
  - Each model's lifecycle is one `TargetLifecycle` reducer (Core/Workspace).
    Scene phase, presentation (`setPresentation`), the active-work count, a
    voice call, grace expiry and retirement are its events, and the model
    performs the effects it returns. `BackgroundExecution` is the platform
    seam: the iOS arm owns the background assertion and the grace timer, and the
    macOS arm never backgrounds, so its model keeps its connection.
  - On `.background` with active tasks and no voice call, a 25 s background
    grace keeps sockets up for quick app switches. An idle model disconnects at
    once, and an active voice call keeps the connection.
  - While `.active`, an incremental refresh loop keeps the history list at most
    15 s stale.
  - The same loop warms every unsettled drawer conversation in rank order
    (`ConversationDrawerRank`; delegated agent threads, and probe threads the
    drawer hides while they are not running, excluded) at background
    priority, running turns included, so a visual an agent posts in a
    conversation that is not shown is prepared by the next pass that sees its
    header revision move; there is no per-item hook. Each gets its opening tail
    in the history page cache, trusted while `HistoryWarmLedger` holds a read of
    that exact header revision, or without a ledger entry while the stored tail
    is newer than the thread's `updatedAt`. The warmer then awaits preparation
    of the tail's HTML visuals in chunks of at most 16, and the conversation is
    warm only once every visual is stored or recorded unpreparable for the
    current width and theme. An incomplete attempt is retried from the stored
    tail on the next pass; an interrupted one ends the pass. The Mac prepares no
    visuals ahead, so there preparation reports unsupported and the warm covers
    history only, with no preparation context. The top two, while
    no turn runs there, also get a session and pre-rendered Markdown in
    `RecentConversationCache`, but only into free slots, so warming never
    evicts a conversation the user opened, and their agent lists are read
    without a cached agents model, running turns included, so the subagents
    pill is there on open. Keep the limit well below `HistoryWarmLedger`'s
    capacity and the page cache budget: an all-unsettled pass (about 160 chats)
    rewarmed evicted ledger entries in a circle and filled the 64 MiB page
    cache.

## Conversation state and transcript

- **One owner.**
  - `ConversationSession` (Core `Conversations/`) is the sole transcript owner.
    Live and replayed notifications, pending submissions and bounded history
    merge into synchronous `ConversationState` transitions. `turn/start` returns
    only the turn id, so nothing but the pump writes a second transcript.
  - The main actor publishes only snapshots matching its selected actor
    identity and revision.
- `ConversationProjection` derives action groups between user/assistant
  boundaries; media the agent took in (an image view or a tool call's
  `rcMedia`) are boundary rows too.
  - Do not restore mutable segment anchors, read-baseline message replacement,
    or separate live and history timeline writers.
  - Exact `clientUserMessageId`/`clientId` reconciliation preserves the local
    row and presentation identity across early empty pages and lost
    acknowledgements.
  - Re-projection is per turn. `ConversationState.turns` is a `TurnTable` that
    stamps every turn write with a process-wide unique counter. A window change
    that moves its tail reach or newest turn bumps `windowStamp`; any other
    coverage change re-stamps only the turns it covers differently. Turn inserts
    or removals bump `membershipStamp`.
    `ConversationSession` owns one `ConversationProjection.Memo` and threads it
    through `render`, which re-projects only turns whose stamp changed. Any
    change to a global input (conversation and thread identity, working
    directory, expanded anchors, window, order, membership or steer and queue
    submission status) discards the whole memo, and the memo holds at most one entry per
    current turn.
  - Per-turn projection may read only its own turn and those global inputs.
    Question inventory, summary mapping and edge placement belong to the
    assembly pass. Never write back an unchanged turn: every write re-stamps it
    and forces a re-projection. History merges and checkpoint restores store
    through `TurnTable.storeIfChanged`, so a repeated read re-projects only the
    turns it changed; live events write directly because they always change
    their turn and must not pay a whole-turn comparison per delta.
- Codex item notifications and native pages share `startedAtOrdinal`. Completion
  updates content without moving an item's first position; older
  completed-only recordings fall back to recorded order. A positioned turn's
  place in `ConversationState.order` follows its earliest item ordinal, never
  arrival, so a late replay or a stale checkpoint cannot put an older
  positioned turn after the live one. A turn without ordinals stays after the
  highest-ordinal turn that preceded it.
  Claude joins gateway identities with provider UUID/message-block ids through
  its durable index. Both adapters feed the same owner.
- Timeline liveness comes only from runtime gateway and processing state.
  Provider history may keep `inProgress` after an interruption, and that alone
  must never animate "Thinking". A turn missing from authoritative activity
  snapshots for at least one second clears stale turn state, even when
  transcript recovery fails.
- A send reacts at the tap. `ChatScreenModel.dispatch` clears the composer
  (`ComposerDraftStore.beginSending`) and publishes the local row before
  saving anything or contacting the gateway, then saves the submission
  (`ConversationSession.persistSubmission`) before the gateway sees it, so
  recovery never sends it twice. Until that save succeeds, draft saves keep the
  outgoing text, so a crash loses nothing. A failed save removes the row; once
  no earlier send can still fail, the failed messages return in the order sent,
  ahead of anything typed since and after any IME composition. An ordinary
  message reads "Sending" only while the gateway has not accepted it after
  0.5 s, then "Not sent" (rejected) or "Unconfirmed" (uncertain).
- A steer appears once. Both providers take it only after the running tool
  batch finishes, and the only proof is the canonical `userMessage` whose
  `clientId` matches; a `turn/steer` response means only that the gateway
  handed it over. Until then the local row is not an action-group boundary: it
  renders after the turn's live group, so running work stays in that group,
  and reads "Steer pending" (active turn), "Not sent" (rejected) or
  "Unconfirmed" (uncertain, or the turn ended first). The canonical item makes
  it a "Steered" boundary at its received position.
- Stop interrupts, then continues with the input the turn never took. Both
  providers discard a stopped turn's untaken steers. `TurnDispatcher` retains
  the exact turn's continuation until its matching `turn/completed`, successful
  full Stop response (including cleanup), and all already in-flight steer RPCs
  settle. A failed or cancelled Stop never continues. Only accepted, untaken
  messages marked `wasSteered` can continue; the original unconfirmed prompt
  cannot. One steer keeps its client identity; several merge into one message
  that replaces their rows (`ConversationState.takeDiscardedSteers`). If
  quiescence or retirement revokes dispatch while that merge persists, the
  merged receipt persists as "Not sent", retaining its input and attachments
  across Keep Open and cold recovery. With no such steer, Codex reads its server
  queue and starts the first FIFO entry,
  including messages queued by another device. Failed queue reads stay unknown.
  Stop with nothing pending ends the work; retirement cancels the continuation.
- A queued message (Codex only) lives in Codex's server-owned thread queue,
  never in an app-side execution queue. Its submission carries a queue receipt;
  its row stays in its own `local-` turn below every turn that starts before it
  (`ConversationState.ensureTurn`) and reads "Queueing", "Queued", "Not sent"
  or "Unconfirmed". `thread/queue/add` is not idempotent, so an uncertain add
  is never resent. Membership comes only from `thread/queue/list`, matched by
  `clientUserMessageId` and read after `thread/queue/changed`, on opening and
  after a failed action, behind a read fence. Absence unconfirms a receipt only
  when the same read confirms the thread idle, because a started entry leaves
  the queue before its canonical user item arrives. A restored receipt is
  unconfirmed until listed. The canonical `userMessage` with the matching
  `clientId` moves the row into its turn as an ordinary first message. Stop
  pauses the queue (Codex skips dispatch after an interrupt); a queued row
  offers Send Now (`thread/queue/start`, only while no turn runs) and Remove
  from Queue (`thread/queue/delete`).
- Action-group durations use their own observed boundaries; a user message
  bounds them when the agent received it (`completedAtMs`), not when it was
  sent. Missing timestamps stay unknown.
- Live agent timeline bubbles show tool calls, commands, file changes and
  plan/diff updates while a job runs, then fold into an "agent worked for X"
  summary. The timeline uses `item/started`/`item/completed` and filters
  high-frequency deltas and internal events. Event rows use compact spacing and
  caption-scale type.
- `ConversationAgentsModel` owns one shared refresh for each retained conversation.
  Selection, inspector, sheet and warmer share it and reuse successful reads for
  15 s; explicit refresh and agent actions bypass freshness. Up to 32 callers
  can await that refresh; further callers reuse its eventual published state.
  All waiters share that RPC's capacity recovery within its original request
  deadline, and the RPC is cancelled when its last waiter leaves.
  Cancelling the last waiter cancels its RPC. The automatic selection probe waits
  for the transcript tail; explicit details can read immediately. Failed reads
  retain old rows with an error, and unread lists never show No Agents. The 15 s
  freshness window only controls reads; the UI never changes just because it
  elapsed.
- **Questions** (`request_user_input_async`) render as `QuestionCard` rows. Read
  `docs/async-questions.md` before changing them.
  - The host owns resolution. `QuestionInventory` is its epoch- and
    revision-scoped replica in `ConversationSession`, and pagination only
    controls row visibility.
  - `QuestionEditor` owns one address-scoped form. Ordinary submission receipts
    own sending, admission and confirmation. Partial replies keep original
    indices, and all answer text goes through the standard `turn/steer` or
    `turn/start` path.
  - The earliest actionable question drives the composer banner and the
    separate drawer badge. Off-page questions open an address-bound sheet.
    Close changes presentation only; Dismiss commits host state without sending
    model input.
  - Selection requests only newly added scopes. Binding a session without ready
    question coverage also requests that exact thread, because prior attention
    reads may have run before the session existed. Ready sessions reuse their
    replica; host invalidations and reconnect retain their full refresh paths.
  - Unknown state offers Refresh, never an inferred pending prompt. Summary
    previews never pin an unpositioned question to the transcript tail.
- Only the final assistant bubble of a completed turn, with its history tail
  loaded, offers **Fork from here**. The server cutoff includes the whole turn,
  so user bubbles, intermediate replies, active turns and pages with newer items
  must not offer it.
- `ConversationCheckpointStore` persists canonical checkpoints with revision and
  generation guards. Derived timelines are not persisted. The legacy timeline
  reader keeps old local activity for migration and rollback, but all new
  writes go to the checkpoint store.
- **Transcript.** `docs/system-architecture.md`, *History and live state*, owns
  the mechanism: identity, mounting window, scroll intent, follow mode, edge rows
  and rendering. Read it before changing layout or scrolling. This file keeps only
  what must not come back:
  - `ChatTranscriptView` (`UI/Chat/Transcript/`) owns history and follow policy,
    plus the iOS mounted window, keyed by `.id(model.transcriptIdentity)`. On iOS it owns the
    SwiftUI scroll surface; on Mac `AppKitTranscriptContainer` owns the native
    scroll surface and transient geometry. The identity changes
    only on explicit switches (resume, fork, new chat), never when a draft gains a
    session id mid-turn, and a switch publishes identity and `streamItems` in one
    main-actor tick.
  - iOS keeps its eager, bounded `TranscriptLayout`, never `LazyVStack`:
    SwiftUI lazy estimates previously stranded tall transcripts in blank space.
    Mac passes the bounded loaded source to native logical geometry and hosts
    only the viewport/overscan and active owners. Its explicit estimates are
    corrected by the native scroll owner; never eagerly measure the loaded
    history to populate the height cache.
  - Do not reintroduce per-delta SwiftUI scroll corrections, persistent pixel
    anchors or competing scroll owners. iOS retains identity-based
    `ScrollPosition`, without content-offset writes, `scrollTo(edge:)` or nested
    scroll-target layouts. Its jump button's only UIKit reach is
    `TranscriptScrollHalt`, which never reads or sets an offset.
    On Mac the container alone writes clip bounds for commands, committed
    size-change follow and canonical-row restoration after layout. Its index
    and offsets remain unobserved. Composer paging uses `TranscriptScrollHalt`
    to reach that same container and notify policy once before moving.
  - Visibility has one owner per platform: one `onScrollTargetVisibilityChange`
    on iOS, and the container's bounded row index on Mac. iOS retains its four
    scroll-geometry projections and reading-row/latest-edge observers.
    Recording reading frames in `TranscriptLayout` instead was measured and
    rejected (2026-10-20): reading a `LayoutValueKey` there makes SwiftUI
    re-measure every row on each parent update (6 to 120 per scroll loop),
    which cancels the AttributeGraph time saved. Mac
    owns a `TranscriptLogicalRow` per loaded row and one `NSHostingView` per
    admitted `TranscriptRow.id`, diffed by
    `TranscriptRowInputs`. Unchanged inputs keep their roots. Each row reports
    only its measured size; the container owns cached heights and native
    placement, without a SwiftUI document layout, mailbox or origin anchor.
    Row-local rendering must trigger commits even without a representable
    update. Prepends extend document bounds upward around the first surviving
    reading row, keeping previous content frames exact. Boundary headers may
    move above the new prefix. Interior growth moves only later rows, never
    replacing or explicitly laying out unchanged roots. Environment invalidation belongs
    to `TranscriptHostEnvironment`; new row environment dependencies must be
    represented there unless their existing observable owner updates them.
    Native display-linked sampling emits only membership changes and semantic
    height/threshold changes.
    `TranscriptVisibility` owns bounded per-row state. Only visibility is
    observed; growth animation samples the unobserved steady flag when a render
    revision changes. Only entering or leaving rows change visibility; scroll
    phase changes steady flags only for visible rows. The membership set and row-state registry are
    unobserved, and rows evicted from the logical source are pruned. Native runway decisions use the
    first visible index position and cached prefix budgets. Follow and
    phase policy stay outside transcript-body observation. Mac has no
    `scrollTargetLayout`, `ScrollPosition` or SwiftUI scroll-geometry modifiers.
  - Mac row hosts contain no `.help` or `.tooltip`: native dynamic tooltip
    hit testing walks hosted trees on each wheel event. Tooltips on the jump
    button and other chrome stay outside those hosts. The document uses its
    row index to hit-test only the row under the pointer, caching the weak
    result by point and host/root/layout revision. Input and scrolling clear
    the cache. Preserve selection,
    clicks, menus, drag/drop and horizontal overflow. Route only vertical wheel
    hit tests to the native document; never override `scrollWheel` on the scroll,
    clip or document view. Harness-only responsive-scrolling opt-out is for
    synthetic input and does not compile into production.
  - Mac admits visible/command rows before one viewport of preparation,
    retaining hosts until two viewports away. Speculative hosts share a 96-host
    cap; visible and pinned owners take precedence. Admission stops after four
    hosts or 4 ms of measured synchronous work per display frame. One fenced
    task prepares at most 32 desired message renders. No idle full-window
    preload or SwiftUI reveal barrier remains. Commands require the target's
    current host measurement, not an older cached height. iOS retains its
    idle-only batches and following budget.
  - `TranscriptRowPresentation` retains code folding, timeline expansion,
    Mermaid source choice and question presentation while a logical row stays
    loaded. Answer drafts remain in `QuestionEditor`. Active presentations,
    first responder and the last interaction pin their host; partial previews
    must not inherit or prune canonical row presentation. Cancellation and
    teardown stop preparation, native sampling and input work and restore
    cursor rectangles.
  - Bubbles observe only their `RenderedMessageStore` entry through the store
    subscript. The screen and drawer must not read the render dictionary.
  - Never make `RenderedMarkdownBlock` comparison content-based or use its
    version as `ForEach` identity. Streaming text never animates per revision
    (`contentTransition(.identity)`), and an assistant message without a render
    shows a blank line, never raw Markdown. `RenderedMessageStore` keeps its
    serial worker, source and state matching, retirement, deadlines and bounds
    together.
  - `dev-tools/AGENTS.md` documents the streaming-motion measurement.
- **HTML visuals.** `docs/html-visuals.md` owns the contract. Successful canonical
  tool items carry `rcVisual` and project a `publishedVisual` boundary without
  an authored assistant message. Within the loaded turn, the latest successful
  publication with exactly the same title replaces its earlier automatic row;
  a completed standalone assistant embed claims its named digest. The gateway
  owns publication success and the publisher owns title validation. Keep placements
  memoized per item and include publication rows in warming and near demand.
  The workspace
  `HTMLVisualRenderer` owns what windows share: page admission, the raster
  budget and the snapshot, height and raster caches. Each `ChatScreenModel`
  owns one `HTMLVisualPreparation` with its layout context, demand, lane, waits
  and preparation surface, so window and conversation state never leak into
  another window's preparation.
  - A `WebPage` backs at most one `WebView`. Only the host that claimed a
    preparation surface renders it; never render a shared page from a second
    view.
  - Readiness waits are bounded by `renderReadinessTimeout` and are recovery,
    not proof. Pixel demand (awaited presentable visuals and the near set
    around the visible rows) is planned nearest first to fit the raster
    budget and pinned; reveal waits need geometry only, and speculative
    warming never decodes. Energy conservation drops only speculative work;
    the preparation host feeds the policy to admission before preparing.
  - Opening a conversation never waits for HTML visuals. A cold block shows
    its placeholder until it can draw, and only a placeholder a visible row
    actually showed fades out; never animate warm content, the live/snapshot
    handoff or the block's height.
  - The renderer never evicts a raster that is pinned or still held outside
    its cache. Hold an `HTMLVisualPreparedRaster` only while presenting it;
    any other reference keeps its pixels in the budget. Never store one
    directly in `@State`: on the iPad, rasters cleared from `@State` stayed
    alive in offscreen transcript rows and exhausted the budget, so the
    occurrence keeps it in its `PresentedRaster` holder.
  - A superseded raster (a newer capture is stored) stays drawable but is not
    prepared: decide readiness with `currentRaster`, draw with
    `presentableRaster`.
  - Sharp rasters come from their own 16 MiP budget and belong to the
    presenting occurrence's `PresentedRaster`. Request one only while the
    transcript is idle, so motion never commits a new image, and drop it when
    the row leaves visibility.
  - The screen cancels its preparation demand when it resets rendering or
    retires. A new caller of preparation work must keep that fence.
- **Images.** `ImagePreparation` (`Services/Images/`) is the one serial actor
  for app decoded-image work: display thumbnails and the device tool's bounded JPEGs.
  The shared camera actor prepares its own bounded preview thumbnails because
  the capture extension does not compile the app's image services.
  - Thumbnails decode at display size and have no full-resolution fallback.
  - Composer photos are files. The picker, composer camera, Camera Control,
    locked capture, paste, Mac drop and share sheet all enter `FileAttachmentImports`; no path sends images inline in
    `turn/start`. `UploadStaging` passes every staged file through
    `AgentImageFiles` (Core `Files/`), which converts HEIF, TIFF and camera
    RAW, detected by content, to JPEG and leaves everything else untouched.
    Attachments keep their selection order however staging finishes.
  - A draft saved by an earlier build may hold `legacyImage`; resuming the draft
    uploads its bytes as a file in its place (see the compatibility register).
    `AttachmentThumbnail` reserves its aspect ratio before loading.

## Chat screen and composer (`UI/Chat/`, `Chat/`)

- `ChatRootView(workspace:sceneValue:)` is the scene root. It attaches its
  `ChatWindowModel` on appear and detaches it on disappear, and owns workspace
  bootstrap and teardown and forwards scene phase, settings changes,
  notification taps and APNs token updates, so every host reacts, not just the
  presented one. `ChatScreen` renders the window's selected `ChatScreenModel`
  (composer, drawer, alerts, transcript subscription). The transcript is
  identified by host and conversation.
- **Header.** `ChatHeader` is the one header, shared by the chat toolbar
  (`ChatScreenToolbar`) and Voice Mode; each supplies its leading and trailing
  controls.
  - The header groups the working folder and host name in one centered,
    two-line control. That control (`active-host`, "Running on <host>") exposes
    the full folder as its accessibility value and opens the directory picker.
    It shows "Choose Folder" when the host has no working directory. Host
    selection is available in both the drawer and the directory picker.
  - A visible clock control (`open-conversations`) opens the drawer. A
    horizontal drag also works, but a gesture alone is unreachable for VoiceOver
    and UI automation.
  - New chat (`new-chat`) starts a new chat on tap. Holding it, or its "New Chat
    in Home" accessibility action, starts one in the host's remote home folder.
    The Mac `TapHoldButton` is a plain click, so there only the accessibility
    action remains.
  - "Speak replies" lives in Settings → Chat.
  - Picking a different working directory immediately starts a fresh
    conversation, so a session never spans repositories. On an unsent draft
    it changes that draft's folder instead.
- **Mac window toolbar.** `ChatScreenChrome` is the platform seam for the
  header: the iOS arm keeps `ChatScreenToolbar` as a top inset, and the Mac arm
  puts the chat into the detail column's window toolbar instead.
  - The title is the conversation's sidebar title (or "New Chat"), and the
    subtitle reads "host · condensed folder" (or "Choose Folder").
  - Items: Back to the parent while an agent child is shown; a folder pulldown
    whose click opens the directory picker and whose menu lists every host's
    favorites; Stop, always present and enabled only for a stoppable turn
    (the composer's `TurnStops` path); New Chat, whose click keeps the folder
    and whose menu offers New Chat in Home and one entry per host; and the inspector toggle.
  - It is a customizable `toolbar(id:)` with stable item ids, grouped with
    `ToolbarSpacer`, on system toolbar glass. `AppMenu(trigger: .toolbarItem)`
    leaves a toolbar menu in the system style. The connection edge glow appears
    only while disconnected. Find spans the detail column below the toolbar.
- **Conversation details.** `ConversationDetailsPresentation` presents a
  conversation's agents: the agents sheet on iOS, and on the Mac a full-height
  trailing inspector, applied outside the split view. The inspector also shows
  the host, folder, model, reasoning and context usage; an unread value reads
  Unknown. Its open state is per window (`@SceneStorage`), and `ChatWindowActions`
  publishes it to the View menu (⌥⌘I). The subagents pill opens it.
- User and assistant bubbles render Markdown blocks. Block gaps, heading
  margins and list spacing read `interfaceScale` in the rendering views; zoom
  changes layout without reparsing Markdown or changing block versions.
  User bubbles use a system
  surface with only a subtle theme tint, so contrast stays native in light and
  dark mode.
  - On the Mac, `TranscriptInteractions` adds the desktop affordances: message
    text is selectable, the bubble menu offers Copy (plain text from the
    rendered blocks), Copy as Markdown, Share and Fork from Here, a code block's
    menu offers Copy Code and Save As… (`CodeSnippetFile` names the file from
    the fence language) and its header drags the code out as text, and a file
    chip's menu adds Quick Look for files the opener shows in Quick Look. The
    iOS arm offers Copy, Copy as Markdown and Select Text. One transcript-owned
    sheet presents selectable plain text; transcript text keeps its context menu.
  - The transcript column is at most `ReadableContentWidth.transcript` wide and
    centered in the scroll view; on iOS that width is unbounded.
- **Composer (`ChatComposerView`).**
  - The multi-line field is the `ComposerTextInput` seam: a `UITextView` on iOS
    and an `NSTextView` bridge on the Mac, because the Mac field editor consumes
    ⌘V and marked IME text before SwiftUI can act on them.
  - `ComposerPaste` (Core) is the one paste policy for ⌘V, the attachment
    menu's Paste from Clipboard and drops. File URLs become file attachments
    through the Choose File path and suppress everything else. Otherwise images
    attach, and text of `ComposerPastedText.attachmentThreshold` (1,500) or more
    trimmed characters becomes an inline pasted-text chip at the selection;
    shorter text remains ordinary inline text. `ComposerDocument` owns the
    ordered main-actor buffer and all range edits, adopting native TextKit 2
    storage while mounted. Serialize only at persistence and send boundaries.
  - On the Mac, Return sends through `onSend`, steering when a turn is running.
    On iOS only a hardware keyboard's Return sends, through a priority
    `UIKeyCommand`; the on-screen Return key inserts a newline, so a slip
    beside the space bar never sends a half-written message.
  - On the Mac the composer's text view is an ordinary key view, so SwiftUI
    focus tracks it, it is the window's default focus, and Tab and Shift-Tab
    leave it. Paste is enabled whenever the clipboard holds attachable content,
    even with no text. When a printable key or ⌘V arrives while no editable text
    view is first responder, `AppKeyMonitor` moves focus to the key window's
    composer first; the sidebar keeps type-select, and Space and control keys pass
    through. Switching conversations keeps composer focus.
  - While a Codex turn runs and the draft is an ordinary message, the send
    control is an `AppMenu` with a primary action: a tap or Return steers, and
    a long press (click and hold on the Mac) offers Steer and Queue. Queue keeps
    the keyboard up and is also a named accessibility action.
    Shift- or Option-Return inserts a newline, and Return never sends while IME
    text is marked. Up Arrow in an empty field inserts the conversation's last
    sent prompt for editing (`SentPromptRecall`: nothing when that prompt is
    not loaded or contained only image/file attachments). v2 recalls restore
    inline chips; earlier pasted-text attachments expand as plain text.
    Esc stops a stoppable turn through the
    same `stopTurn` path as ⌘. and Stop; otherwise it continues up the responder
    chain.
  - On the Mac, files, folders and images dropped on the transcript or the
    composer attach through the same paths (`composerAttachmentDrop` and the
    text view's own drag handling), and the composer shows an accent outline
    while a drop is over the chat.
  - Pending images and files are uniform tiles
    (`ComposerMetrics.attachmentTileHeight`: 64 points on iOS, 48 on the Mac),
    scaled with Dynamic Type, in one horizontal strip above the field. The
    composer grows by one row however many are added. Each tile has a corner
    remove control with a `ControlMetrics.minimumTarget` hit area, and the whole
    strip is a composer control hit region, so it scrolls.
  - The attachment menu offers camera, photo library, file import and paste.
  - **Choose File** attaches any file, or a folder as a zip. `UploadStaging`
    copies it locally and `GatewayUploadClient` streams it to the gateway's
    resumable `/uploads/<id>` session. Four files upload at once. An
    interrupted upload waits and continues from the gateway's offset after a
    backoff, a network change or the app becoming active; on iOS,
    `ContinuedUploadProcessing` keeps uploads running in a
    `BGContinuedProcessingTask` after the person leaves the app. The tile shows
    progress, paused, Uploaded, or a failure with Retry, and sending waits
    until every file is on the host. The message then carries
    `AttachedFilesPromptBlock`, the absolute host paths as plain text after the
    typed message, which is the whole provider handoff
    (`docs/system-architecture.md`, *File attachments*).
  - **Share sheet.** `RemoteCoderShareExtension` lists RemoteCoder for any
    shared content. It moves each shared file into a share in the app group's
    `SharedItemsInbox` (Core `Files/`), writes the manifest last and opens
    `remotecoder://chat/share?id=…` through the responder chain's
    `UIApplication`; Apple offers share extensions no supported way to open
    their app. The router delivers `.sharedItems` to the key screen, which
    starts a New Chat in the host's home folder and, once that draft is ready,
    claims the share off the main actor by moving it out of the group, so it
    attaches once and an interrupted hand-off leaves it in the inbox. Files
    enter `FileAttachmentImports` as deferred imports that delete the claimed
    copy after staging; links and text follow `ComposerPastedText`. Generic
    plain text, or text whose provider prefers inline presentation, arrives as
    text; typed text documents such as source files arrive as files. Nothing is
    sent. A new share removes
    unclaimed shares older than `SharedItemsInbox.unclaimedLifetime`.
  - **Camera Control.** `ChatComposerView` is the app's sole camera presenter
    and attachment owner, backed by `ComposerPresentations.camera`. Take Photo
    uses the current draft; the unlocked intent opens a home-folder New Chat and
    requests this presentation once its draft is ready. Host availability does
    not gate attachment; offline uploads use the existing staging queue.
    `CameraCaptureView` and `CameraCaptureModel` are shared with
    `RemoteCoderCaptureExtension`. Hardware capture interaction stays enabled
    throughout presentation, including busy states and review; presses there
    are ignored. Only the app provides Close; the system dismisses the extension.
    `CameraCaptureSession` owns the serial AVFoundation session, full-quality
    original writes, readiness, lenses and zoom, with at most two requests in
    flight and responsive/fast capture enabled where supported.
    `CameraCaptureModel` owns and joins per-shot thumbnail and add-only Photos
    tasks on `CameraPhotoProcessing`, separate from the capture executor. Save
    failures belong to their shot and do not block attachment. Done and removal
    wait for those tasks before transferring or deleting files. Selection is
    bounded to 24 photos with 160-pixel tray thumbnails (at most 2.5 MB of RGBA
    pixels); review loads at most 512-pixel images for visible cells and releases
    them on disappearance. Removing a shot deletes its temporary folder and
    frees its slot. In-app Done transfers files to `FileAttachmentImports` and
    deletes the batch directory. Camera-roll copies survive removal and Close.
    The extension alone writes the ordered `CameraCaptureBatch` confirmation
    manifest at Done before requesting unlock and app handoff. Failed handoff
    retains confirmed files for retry. `LockedCameraCaptureImports` owns session
    discovery, expiry, ordered transfer and invalidation; unconfirmed sessions
    never attach. The screen owns its receiver until draft navigation or
    retirement. Receiver replacement joins its predecessor, and cancelled
    admission restores moved files. Neither camera entry point sends a message.
  - Settings, input and action controls share one neutral glass surface. The
    focused iOS composer keeps its multiline editor above the action row.
    Unfocused, it folds that same editor to one line between the leading
    attachment control and the trailing actions, and
    gently narrows when space permits. `ComposerInputLayout` keeps the leading
    group bottom-left in both arrangements, retaining every control and its touch
    target. Narrow windows and accessibility text sizes keep separate input and
    action rows. The Mac keeps its multiline layout when focus changes. Focus and
    dictation transitions animate the surface together and respect Reduce Motion;
    managed work alone never resizes it. Its maximum width is
    `ReadableContentWidth.composer`: 600 points on iOS, the transcript's readable
    width on the Mac. Action controls
    are native buttons with `ControlMetrics.minimumTarget` targets (44 points on
    iOS, 28 on the Mac) and `ComposerMetrics` glyph sizes. Every icon button has
    an accessibility label and a `tooltip`.
  - Working state is a spinner in the existing send control (static dots with
    Reduce Motion), and typing restores the steering arrow. A separate status
    row appears only when sending is blocked.
  - Drafts in managed active turns use `ComposerSendButton`'s steering state.
    Externally active sessions stay read-only. The history row and composer
    share `ConversationActivityIndicator`.
  - While the visible conversation has a known running turn, Stop appears
    first in the trailing action group, directly after the row's spacer in the
    stacked layout and directly after the input in the inline folded layout.
    Existing controls keep their positions, so a tap meant for them cannot end
    the turn. It interrupts that
    exact turn through `TurnDispatcher` and Core's `TurnStops` and stays
    disabled until the turn leaves the active turns. An activity read
    requested after the gateway acknowledged the Stop that still lists the
    turn enables it again.
  - A failed Stop shows on its own conversation's composer
    (`TurnStops.failure`), in provider-neutral text. It stays silent only when
    the gateway reports `turnNotRunning`; a Stop that could not be saved, a
    pending resume or unreachable agents always show.
  - The mic button dictates into the draft through `VoiceInputController`.
    While recording, the composer becomes a Voice Memos-style scrolling
    waveform, white bars on red. The Voice Mode button presents the full-screen
    voice UI.
  - Stop and Voice Mode go through `SlideToConfirmButton`. On iOS a tap never
    acts. Touch-down reveals the "Swipe up to …" guide track, the thumb follows
    the finger, and lifting or cancelling the touch collapses it at once; no
    guide outlives the contact. An upward flick from the button confirms, and
    dragging the thumb its full 64-point travel arms it ("Release to …"). Its
    UIKit `UIControl` owns the touch; VoiceOver activation acts directly. The
    Mac arm is a plain button.
  - A compact context-window gauge appears in the upper-right group before
    reasoning and Fast on iOS, and beside the attachment controls on Mac, when
    the active thread reports typed token usage, for both providers. Ring and
    popover show one quantity, how full the window is, and turn amber at 75 %
    and red at 90 %, as both providers' automatic compaction nears. The popover
    adds used/available tokens and that the agent compacts automatically. It
    reads `last`, because `total` accumulates over the thread's life and
    re-counts cache reads, and would pin the gauge at full after a few turns.
- **Model, reasoning and Fast controls.** The composer always shows the selected
  model, reasoning effort and Fast state.
  - Model opens a native menu. On iOS, reasoning is a gauge that opens the
    screen-level floating slider on tap or hold
    (`UI/Chat/Composer/ReasoningPickerOverlay.swift`,
    `docs/reasoning-picker-motion.md`). The Mac arm of
    `ConversationSettingsControls` shows reasoning as a native menu of
    `ReasoningSelection.choices(among:)` for the visible levels, labelled with
    the gauge and the current level, and has no slider. The Mac model and
    reasoning menus combine their accessibility children before applying the
    control label and current value, keeping one native menu control each.
  - `ModelPickerPreferences` (owned by `ChatWorkspaceModel`, injected into the
    environment) is the one owner of model and effort visibility. It persists
    each change and tells the workspace once. `ReasoningEffortVisibility` holds
    each provider's visible levels. Max and Ultra start hidden, selections
    clamp to the visible range, and the slider and gauge share it.
  - Fast is an icon-only solid bolt aligned with the gauge: muted when off,
    tinted when on, and dimmed and disabled for models without a fast tier,
    which on Claude is every model except Opus. Its accessible value names the
    state. Activation uses the shared rigid-on/
    soft-off haptics and native press feedback, with no glyph swap or bounce.
  - Settings sync silently in the background, so taps never insert an indicator
    or resize the composer. The controls reflow at narrow widths and
    accessibility text sizes.
  - Reasoning is remembered per model. Settings hold a default reasoning level
    for new chats, per-chat model and reasoning restore from session metadata,
    and changes persist immediately for active sessions.
- **Codex model catalog.**
  - Codex models come from the app-server's paginated `model/list`
    (`includeHidden: true`), fetched through the gateway per execution target
    (physical host).
  - `CodexModelCatalogService` persists the last good list as
    `codex-models.json` in that target's storage directory. It refreshes on each
    gateway connection until one refresh succeeds, and on demand from Settings →
    Chat → Codex models or the composer's Retry.
  - Construction leaves an unread cache unknown. `ChatTargetModel` owns its
    asynchronous cache restoration; a storage actor reads, decodes, prepares and
    writes snapshots away from the main actor. Voice Mode and its configuration
    queries await restoration before validating or projecting models. Final
    workspace teardown retires targets, cancelling and joining their work.
  - When a refresh fails, returns no models or never finishes paginating, the
    last good list stays with a visible error. There is no built-in fallback
    list.
  - Settings derives its catalog source from the same new-conversation target
    resolver. With no host it asks for one; with configured hosts and an
    unavailable host it keeps the catalog unavailable.
    A resolved source with an unread catalog remains Not loaded.
  - `CodexModelCatalog` derives each option from the wire model: `displayName`;
    the known `supportedReasoningEfforts`, dropping unknown ones; Fast from a
    `priority` service tier or a `fast` additional speed tier; and text-only from
    `inputModalities`, which blocks image sends.
  - Models advertising `availableAccessPrograms.cyber: ["daybreakBlue", …]`
    automatically request Daybreak Blue on app-started `turn/start` calls.
    Settings shows a Daybreak Blue badge and the composer a small shield.
    This is derived per execution target, never a stored toggle or a model-id
    allowlist. Missing metadata preserves automatic upstream behavior.
  - Rows with `modelProvider`/`modelProviderName` run on a gateway external
    provider. `ModelOption.modelProvider` keeps it, pickers show
    `pickerTitle` (`Model · Provider`), and an existing conversation's picker
    offers only models of its own model provider. New chats send only the
    model; the gateway resolves its provider.
  - `ModelVisibility` stores per-model overrides by id and is read
    through `ModelPickerPreferences`, separately for each provider. New Codex models appear
    unless the host marks them `hidden`, and hidden ones can be opted in.
    Claude Code models use the same visibility policy with all families shown
    by default; Settings → Chat → Claude Code models edits their alias IDs.
- **Model defaults and restoration.**
  - `NewChatDefaults` owns independent new-chat model and reasoning policies:
    last manually selected (the default) or a fixed choice in Settings.
  - A new chat uses the saved or fixed choice when it is visible. Otherwise it
    uses `NewChatDefaults.initialCodexModelID` (`gpt-6-sol`) when the host
    reports it and it is visible, then the host's `isDefault` model, then the
    first visible one. Claude uses its preferred visible family, then the first
    visible family in catalog order, without switching provider when all are hidden.
    Settings explains any substitution of a hidden or
    unreported preference, and the stored preference stays unchanged.
  - A refresh re-resolves a new chat's resolved default when that model is no
    longer visible or reported. A model chosen in the composer, the voice picker
    or a shortcut stays, even when hidden, until the host stops reporting it or
    Settings hides it.
  - With no list yet, a new Codex chat has no model: the composer says why,
    offers Retry and blocks sending.
  - Opening a conversation keeps its model even when it is hidden or missing
    from the list; a missing model keeps only its reported effort.
  - Only explicit composer or voice-picker actions record manual preferences.
    Applying a resolved default, switching a new chat's provider, and
    opening a conversation never change them.
  - `docs/system-architecture.md` has the restoration and synchronization
    ordering.
- Reasoning summaries are always requested as `detailed`. Core omits the summary
  only when its model catalog sets `supports_reasoning_summary_parameter: false`.
  A model absent from that catalog, such as a resumed `gpt-5.3-codex-spark`
  thread, is still sent `summary: detailed`.
- **Claude models.** Claude offers Claude Fable, Claude Opus, Claude Sonnet and
  Claude Haiku, passing the CLI aliases `fable`, `opus`, `sonnet` and `haiku`,
  so versions follow the installed CLI's defaults. Saved numbered selections resolve to the same
  family. All four stop at `max` reasoning, which is what `claude --effort`
  accepts. Only Opus offers Fast, Claude Code's fast mode, sent as the `fast`
  service tier like a Codex model's. Fable is the
  initial Claude-family choice; new chats otherwise follow the configured model
  policy.
- **Providers.** Picking a model picks the provider for a new chat; an existing
  chat's provider comes from its thread id.
- Deep links: `remotecoder://chat/new` starts a new chat and focuses the
  composer. `remotecoder://chat/voice` opens Voice Mode on the current
  conversation. `remotecoder://chat/voice?fresh=1` first starts a fresh chat with
  app defaults. `remotecoder://chat/call?id=` presents that exact voice call
  while it is live and is otherwise dropped.
- Task-completion notifications are broker-backed and toggled in Settings. The
  iOS and Mac apps register for remote notifications (the Mac through
  `com.apple.developer.aps-environment`, both from `RC_APNS_ENVIRONMENT`),
  register their device with every host
  through `DeviceRegistration` (one per host, fed by `PushTokenSources`, fenced
  by connection generation, failure shown on the host's Settings row). iOS
  shows a small in-app banner when other sessions finish; the Mac shows the
  system banner. With "Speak replies" on, every assistant message is queued in
  `VoiceOutputController`.
  Foreground presentation uses the scene's single in-app overlay. A refused
  cover dismissal can offer a retry only while active in the same scene epoch;
  inactivity clears it. Warm OS taps whose refused dismissal finishes before
  activation may have no retry banner. That activation-order edge remains a
  physical-device validation gap; there is no second pending-banner queue.
  Notification taps resolve the recorded host and thread, ignoring retired
  enrollment fields, then recheck that owner after loading before committing
  selection or question focus. Explicit navigation supersedes the pending tap.
- On `.inactive`/`.background`, `ChatTargetModel` requests the host's Live
  Activity from its prepared gateway snapshot when work runs or attention waits,
  and registers its push token. `daemon/liveActivity` and
  `daemon/liveActivity/changed` carry the same host aggregate used for APNs,
  including both providers, with an epoch and revision. The gateway authors
  every later update and ends it once nothing on that host runs or waits for
  you.
- Settings include an appearance theme picker (`AppThemeStore`) for subtle
  glass, message, sheet and status tinting.

## Conversation drawer (`UI/Conversations/`)

- Threads marked with the existing `automation` purpose appear in a collapsible
  Automations section between Pinned and Chats/projects, even when settled.
  Pinned automations stay in Pinned; automation rows carry a small clock-arrow
  symbol on both platforms. Membership comes only from the authoritative purpose.
  A scheduled follow-up in a user-created conversation does not change its purpose.
  Automations starts expanded, persists its fold per device and reveals matching
  rows while searching, like Pinned. Expanded, it lists its first five rows in
  drawer rank plus the selected row, and a "Show N more" item reveals the rest.
- One drawer lists every gateway's conversations together, addressed by
  `ConversationAddress`, with cwd badges, relative timestamps and
  active/resuming state. Selecting a row selects its host, and rows show the
  host name once several hosts exist. The new-chat control is a menu whose
  primary action targets the selected host and whose items name every
  destination. Errors are attributed per host.
- `ConversationHistoryView` is the one conversation list. `ChatSidebarContainer`
  shows it as a persistent `NavigationSplitView` sidebar at regular width (iPad
  and the Mac) and as the drawer with its pan gesture at compact width.
  `ChatCommands` builds the menu bar from the key window's `ChatWindowActions`,
  which `ChatWindowActionsPublisher` publishes through an equatable view with
  `focusedSceneValue`. `ChatWindowCommandState` holds menu values and enabled
  commands; the identity-compared performer resolves current actions when run.
  Draft edits that leave this state unchanged do not republish the menus.
  `ChatCommand` is the one list of command titles and
  shortcuts for the menus and the ⌘K `CommandPalette`. Go-menu order comes from
  `ConversationSidebarNavigation` over the sidebar projection, resolved only
  when a command runs. Positions and Previous/Next follow the visible rows;
  ⌘K and Next Needing Attention read the projection with every fold open. Find in Conversation (`TranscriptFind`) matches loaded
  message text with `TranscriptSearch` off the main actor, only when the query
  or transcript identity changes, and jumps with `revealTranscriptRow(_:)`.
- `ConversationHistoryView` owns the snapshot observation, the captured layout
  (held by `ChatScreen` as `drawerLayout`, so window commands can walk the
  displayed order) and the pin prompts. The `ConversationHistoryList` seam
  presents it: the iOS arm uses opaque content-surface rows under headline
  section headers whose trailing chevron folds Pinned, each project, Automations and
  Settled, and the
  Mac arm is a `List(selection:)` source list with a Pinned
  `Section(isExpanded:)`, an Automations `Section(isExpanded:)`, a Chats
  `Section` below them, and, in Projects, one `Section(isExpanded:)` per
  project, then a Settled `Section(isExpanded:)`
  whose selected row stays visible below it while folded; no glass,
  fonts from `sidebarRowSize`, and a bottom bar with the compact usage ring,
  the View Options menu (sort, Unread Only, Mark All as Read,
  Collapse and Expand), status messages and settle undo.
  - A Mac row keeps one height: a reserved leading unread dot, the title and a
    compact date (projected through `ConversationSidebarDateCache`, keyed by
    date and current day, bounded to 2,048 labels),
    then the provider mark, the folder name, the bare host name once several
    hosts are configured, and a symbol-sized status (questions, working, needs
    input, unknown, probably done). The full host and path are the row's tooltip.
  - The Mac selection mirrors the snapshot's selected row. Choosing a row, by
    click, arrow keys or type-select, calls `switchConversation(to:)` through
    `ChatScreen`. A row that another window shows brings that window forward
    instead. Any choice that does not switch restores the shown row. A click
    then focuses the composer, and arrow keys keep focus in the list. Rows draw
    their question count themselves: on macOS 27 a `.badge` on a `List` row
    makes that row ignore clicks and its context menu. The selection context
    menu's primary action, Return or double-click, focuses the composer, and
    the menu adds "Open in New Window"
    (`ConversationWindowValue.conversation`). ⌫ settles the selected rows
    that are not running, with Undo, or unsettles them when every selected row is
    settled. Hovering a row that can be settled replaces its date with a
    checkmark button that settles it.
  - The sidebar filter field (`.searchable`, sidebar placement) writes
    `ChatWindowModel.drawerQuery`, which the projection applies: every
    whitespace-separated term must match the title, folder or, while it is
    shown, the host name. It never reorders rows, ignores every fold (its
    sections show no disclosure while filtering), and a section without
    matches disappears. `ConversationSidebarSections`
    regroups the flat items into `Section`s.
  - Selecting several rows gives the context menu batch Mark as Read and
    Settle N Chats, or Unsettle N Chats when every selected row is settled;
    only a single selection opens a conversation.
  - The Mac sidebar recaptures its layout when its window becomes key
    (`WindowActivations`) or becomes visible after occlusion. Visibility does
    not require key status: uncovering a non-key window refreshes its rows too.
    Rows keep their captured order while you are looking at them.
- The drawer stays mounted while closed, so every chat model change would
  otherwise rerun its projection over the whole history.
  `ConversationHistoryView` reads `ChatWorkspaceModel.sidebarSnapshot(arrangedBy:in:)`
  when its open, visible observation task starts and then through that task’s
  `Observations` loop. A closed or occluded drawer keeps its last snapshot and
  invalidates its captured layout; returning reads current state before awaiting
  observed changes. Its `body` reads live sidebar state
  only while open with no snapshot yet, so the first drag after launch shows
  rows instead of a spinner. Apart from the sort, the projection stays linear
  in the row count, formatting each per-host working directory once per path.
  It emits one flat list with the Pinned, Automations, Chats, project and Settled headers and
  "Show N more" items as items, so a row keeps its `ForEach` identity when a pin moves it
  between sections and slides instead of crossfading; only the Mac arm
  regroups the items into `Section`s.
- Unsent drafts sit outside that item list in `ConversationSidebarSnapshot.drafts`,
  so they never take a rank, join ⌘K or move rows. A Drafts section leads the
  drawer, newest first, three until "Show N more" or a search reveals the rest,
  and labels the rows below it Chats. A draft row opens on tap through
  `ChatWorkspaceModel.openUnsentDraft`, which commits on its own main-actor turn
  like `switchConversation`. Discard is a trailing swipe and an accessibility
  action on iOS and a context menu on the Mac; it shares the drawer's undo bar.
  Mac draft rows are plain buttons outside the `List` selection, and iOS draft
  rows have no lifted row menu.
- Opening the drawer captures a `ConversationDrawerLayout`: every row's
  `ConversationDrawerRank`. Captured rows keep it until the next opening, so a
  completing turn or a changing badge never moves a row under the finger.
  New rows keep their first admitted rank. Order changes wait while scrolling, swiping or
  showing a row menu; content changes apply immediately. Snapshot assignment
  owns the smooth reorder animation and rising rows draw above their neighbours.
  Pinning or unpinning changes order through the same assignment, and so does
  any change to a row's settlement mark, from this app, another device or an
  agent, and any settle, unsettle or undo here, which bumps
  `ConversationList.settlementEdits`: the projection replaces that row's
  captured rank. Settlement from activity or the three-day automatic settle
  waits for the next capture.
  See *Conversation drawer order* in `docs/system-architecture.md`. The Mac sidebar is open whenever it
  is visible, so its capture lasts until it is hidden and shown again.
- The View Options button (`ConversationDrawerFilterButton`) opens a popover,
  not a sheet, with the Priority and Projects views, Unread Only, Select, Mark
  All as Read and Collapse All and Expand All. The Mac's View
  menu and command palette offer Collapse All Sections and Expand All Sections
  as separate stateless commands, so publishing window actions never computes
  the projection. Settle Conversation likewise reads only its own
  conversation's state through `ChatWorkspaceModel.settlement(of:capturedIn:)`.
  The view, filter,
  folded projects and the Pinned, Automations and Settled folds are device preferences in
  `ConversationDrawerPreferences`; Collapse/Expand All includes the displayed
  Pinned, Automations and Settled folds, and the present projects only in
  Projects mode. Pinning a chat unfolds Pinned;
  revealed "Show N more" sections, revealed Automations rows and the Settled
  row limit belong to the window and reset when the drawer opens.
- Probably done is a gateway suggestion in the marks replica, queried by
  `ConversationMarks.isProbablyDone`: no purpose or pin and activity at or before
  `doneThrough`. It is a badge only and never changes the row's rank. Its green
  outline checkmark updates immediately on both platforms, except on live rows
  or the Settled shelf. Unsettle clears it.
- Conversation marks have one owner per target: `ConversationList` holds a
  `ConversationMarksReplica`, applies changes optimistically, persists them
  with `ConversationMarksStore` and sends them in order through
  `ConversationMarksRemote`. `ChatTargetModel` reads the gateway's marks on
  every connection (`marksSync`) and applies `conversation/marks/changed`
  deltas. Native `thread/archived` drops the thread's header like a deletion
  and `thread/unarchived` refreshes the list; the app has no Archive. Never
  keep a second copy of pins, read state or settlement beside it. Settle and
  Unsettle are offered only once the target's acknowledged marks document has
  `schemaVersion >= 2`, because an older gateway rejects the whole pending
  batch. Workspace actions (`markRead`, `settle`) act on the conversation's own
  address.
- Standard refreshes fetch the latest 30 conversations and merge them into the
  persisted cache instead of replacing it, so older known conversations stay
  listed. Pull-to-refresh (iOS) requests up to 200 through cursor pagination, then
  merges and persists them.
- Rows have a context menu to pin, rename, unpin, regenerate an unpinned row's
  name through `conversation/title/regenerate`, mark as read or unread, fork,
  settle (not while it is running) or unsettle, and copy a reference. On iOS a
  leading swipe toggles read state and a trailing swipe settles or unsettles.
  A settle from the drawer or sidebar offers Undo for five seconds, which
  restores the prior pin and unread state. Settle Conversation (⇧⌘S, in the
  Mac's Conversation menu and the ⌘K palette) settles or unsettles the open
  conversation; it uses the captured settlement only while the drawer or
  sidebar is visible, and running it again is its undo.
  A Codex thread in the host's default context copies ChatGPT Desktop's
  `codex://threads/<id>` link, which that Mac's desktop app opens (upstream
  `/app` builds the same form). Claude threads copy the exact gateway thread ID. Neither names the host.
  - On iOS, UIKit owns the menu. `ScrollItemContextMenu<ConversationAddress>` installs one
    `UIContextMenuInteraction` on the list's scroll view, per-row anchors mark
    each row's frame, and UIKit builds a menu once when it opens. Do not move
    it back to SwiftUI `.contextMenu`: SwiftUI rebuilds a visible menu after
    every view-graph update, including touch dispatch, and a rebuild between
    touch-down and lift-off drops the item's tap.
  - The lift animates a window snapshot of the row while the row itself is
    hidden until the interaction ends. The floating header and the bottom
    status messages mark themselves with `ScrollItemMenuObstruction`; the
    snapshot leaves out the part of a row they cover, and a press there opens
    nothing. The row's `.accessibilityActions` list the same items.
- A row's title is its local pin name, then the provider thread's `name`, then
  its `preview`. `thread/name/updated` retitles the cached row on its own host,
  so producers such as automations name their threads through
  `thread/name/set` instead of teaching the app their prompt format.
- There is no close button: the scrim tap or a leftward drag closes the drawer.
- `ConversationDrawer` is gesture-owned, not a scroll view.
  - One `DrawerPanGesture` (`UIGestureRecognizerRepresentable`) owns horizontal
    drags. Vertical-only scroll views wait for it to fail, and it waits for
    horizontally scrollable descendants. The first gesture therefore opens or
    closes the drawer even during transcript momentum, and the panel scrolls on
    its first touch, including during the settle.
  - `DrawerMotion` owns progress: 1:1 drag, a velocity-carrying spring on
    release, and `isOpen` requests from the current position.
  - Both panels move in whole device pixels (`pixelAligned`). A sub-pixel
    offset re-rounds UIKit-backed descendants by a pixel per frame, which
    re-wraps or truncates text that fits within a pixel during the slide.
  - Never wrap the transcript or history list in another scroll view to animate
    the drawer. A moving UIKit scroll view captures the next touch and swallows
    the gesture.
- The header floats over the list in a `safeAreaBar` with a soft top scroll edge
  effect and the chat header's 44-point glass controls: Settings, View Options,
  the usage capsule and New Conversation (Done while selecting). Selection
  replaces the bottom status area with a Mark as Read and Settle bar, which
  offers Unsettle when every selected row is settled.
- Claude and Codex usage rings in `UI/Accounts/UsageDetailsView.swift` share a
  glass capsule. Each shows its selected subscription's logo and remaining
  weekly allowance; the inner 5-hour arc appears only while on pace to run out.
  - When a router is configured, Claude subscriptions come from llm-router, deduplicated by router account ID
    across hosts. The newest successful router list is authoritative wholesale.
    The app owns quota staleness. Selection publishes only after
    router confirmation and never changes a conversation's host-default target.
    Failover's active account is distinct from the selected preference.
  - Native Claude uses its CLI login; router mode delegates account creation,
    removal, sign-in and reconnect to llm-router. Without a router, its
    account-management and speech features remain unavailable.
    Codex usage follows the selected host default. Missing usage stays unknown.
  - `AccountDirectory` owns Codex reset redemption; `ClaudeAccountDirectory`
    owns Claude redemption. Their `AccountResetRedemptions` persists one pending
    attempt per subscription before submission. Retry retains its host, offer
    and host-default gateway account ID across restarts; keys serialize as lowercase
    UUID strings. A definitely refused retry keeps Retry and adds Forget.
    Missing accounts and host changes only cancel work, preserving same-key
    Retry. Forget preserves the unknown outcome in copy. Claude reset
    freshness uses the reset observation, separately from inference usage.
    Pending work holds `BackgroundExecution` through scene backgrounding; only
    termination, execution expiry or its own host retirement cancels it. Other
    hosts' changes and Claude preference selection never cancel redemption.
  - See `docs/usage-status.md` and `docs/provider-accounts.md`.

## Other screens and shared UI

- **Directory picker (`UI/DirectoryPicker/`).**
  - It browses the remote home tree. `HostDirectories` reads the home path
    once per connection from the gateway's `host/info` and keeps its immediate
    children warm. Its timer refreshes only while one of the host's models is
    visible. A read superseded by a reconnect retries on the new connection.
  - `HostDirectories.lastKnownHomePath` is the one home path every view and
    working-directory default reads (`ChatTargetModel.remoteHomePath`). It
    persists per host, so paths show relative to home at launch and while the
    host is offline; never keep another copy of it.
  - The host's gateway owns its favorites. `HostDirectories` keeps a replica:
    the last acknowledged list plus pending add and remove changes, cached in
    defaults, so favorites show before connecting and a change made offline
    is sent on the next connection. Every target of the host shares that
    replica, reads the list over the host connection whenever it connects and
    applies `directory/favorites/changed`. Hidden targets run no event pump,
    so the app becoming active and the picker opening also reread every
    host's list. Only `-32602` drops a sent batch (the replica admits only
    paths the gateway accepts); any other failure keeps it for the next of
    those triggers or an edit, with no timed retry.
  - Favorites form a compact two-column grid, one column at large text sizes,
    and stay in the tree so their children remain browsable. The grid lists
    every host's favorites (`ChatWorkspaceModel.favoriteFolders`), each named
    with its host when more than one is configured; choosing another host's
    favorite switches to that host (`selectFavorite`). Tree rows are
    compact with separate disclosure controls.
  - On iOS, the picker owns one `ScrollItemContextMenu<DirectoryMenuID>`,
    sharing the drawer's UIKit interaction. Cell anchors resolve the exact press;
    never attach SwiftUI `.contextMenu` to cells inside the grid's single List row.
    Favorite and Browse presentation IDs stay distinct even for the same host/path.
    Preview and actions are captured together at opening; accessibility exposes
    the same actions. Mac keeps native SwiftUI menus through the platform seam.
  - The chat picker's host switcher is backed by `ChatWorkspaceModel.select`,
    and each folder tree and its selection callback stay bound to one host
    model. The voice picker stays bound to its call owner.
  - The header uses `DirectoryQuickSwitchPresentation`: tap opens the picker,
    and hold, slide and release previews then selects a favorite on any host.
    `TapHoldButton` owns the continuous touch and captures the source frame
    when its hold begins; UIKit movement tolerance cancels a displaced contact
    before recognition. Header controls apply one shared press response; see
    `docs/directory-quick-switch.md`. The Mac `TapHoldButton` is a plain click
    with no hold.
- **Glass.** `UI/DesignSystem/AppGlass.swift` is the only Liquid Glass entry point.
  - `.appGlass(role, in:, interactive:)` styles control-layer surfaces that
    float over content, with the theme's translucent accent tint and a hairline
    stroke. `.appContentSurface(role, in:)` styles content-layer
    surfaces (rows, chips, cards) with an opaque premixed theme fill and stroke
    on both platforms. Banners and floating file status use `.appGlass`.
    `GlassRole` is `standard` or `selected`, and the tint mix and opacities are
    private to that file.
  - `.buttonStyle(.appGlass)` is tinted glass on iOS and untinted system glass
    on the Mac, where the accent belongs to primary actions.
  - `scripts/lint-glass` rejects raw `.glassEffect(` and
    `.buttonStyle(.glass/.glassProminent)`.
  - Reuse `GlassToolbarControl` for toolbar and menu capsules.
- **Settings.** `SettingsView` is one `TabView` of `SettingsPane`s, and
  `SettingsChrome` is its seam. On iOS it is a sheet from the chat screen with
  sidebar-adaptable tabs, the system sheet background and a close button.
  Settings presentation uses the system sheet transition, with no matched zoom
  source or custom presentation animation. On the Mac it exists only as the
  `Settings` scene (⌘,): toolbar panes, the last pane restored from
  `settings.selectedPane`, and no in-window settings sheet; the usage ring's
  All Accounts opens its Accounts pane. The Mac omits the iPhone-only Haptics,
  Location and Voice Mode sections.
- **Platform metrics.** Shared views take sizes from `ControlMetrics` (minimum
  hit target, row insets), `TypeMetrics` (fixed symbol sizes, scaled to the
  Mac's 13-point body, and the code font) and `ReadableContentWidth` instead of
  literal 44-point frames and fixed font sizes. Icon-only buttons add
  `.tooltip(_:)`, a Mac tooltip that does nothing on iOS. Do not use `.help` in
  shared views: on iOS it sets the accessibility hint.
- **Haptics.** `docs/haptics.md` owns the tactile vocabulary, press/preview
  behavior, audio policy, Standard/Strong tuning, the device comparison page and
  verification. All app feedback goes through `HapticService` and the
  `HapticEvent` catalog; do not add raw generators or per-screen pattern
  constants. New native menus use `AppMenu`. Preserve native menus and the
  reasoning gesture bridge when adding control coverage. `scripts/lint-haptics`
  enforces these boundaries.

## Voice Mode (`Services/RealtimeVoice/`, `UI/Chat/VoiceMode/`)

The gateway side is in `host-daemon-rs/AGENTS.md`; both paths are in
`docs/system-architecture.md`, *Voice paths*.

- `VoiceModeView` is a neutral call surface. It shows the model, reasoning and
  Fast state, plus a compact status and labelled Mute, Speaker and red
  End call controls. Chat minimizes without hanging up, and Transcript opens the
  available call transcript in a sheet. Selected controls reflect
  call-confirmed mute and route state, and connection failures offer
  Try Again. `VoiceModeComponents` add reconnect, voice selection, the
  continuous transcript and animated speaking/listening state.
- Voice Mode opens an outgoing LiveCommunicationKit conversation automatically.
  There is no push-to-talk, local VAD, local transcription or synthesized reply
  path. Dismissing the full-screen surface does not end the call; Lock Screen
  and Dynamic Island controls stay authoritative in the background.
- `VoiceCallCenter` (app-owned) holds the one call, addressed by
  `ConversationAddress`. `VoiceCall` owns the WebRTC peer connection,
  `CallSystemBridge` the iOS 27 `ConversationManager` and
  `CallAudioRoute` the audio route (`Platform/iOS/SystemCalls/`).
  LiveCommunicationKit is the only call lifecycle: system and in-app mute and end flow through the same conversation
  actions, and WebRTC audio starts only after the system activates the call
  audio session.
- `CallSystemBridge` creates its `ConversationManager` lazily and replaces it
  before every new outgoing or incoming conversation while no conversation is
  live or being created, and ignores every callback from a replaced manager,
  including its audio activation. An activation already forwarded to
  `RTCAudioSession` is balanced exactly once, on its own deactivation or just
  before replacement, so WebRTC's activation count stays even when a quick
  retry outruns the old deactivation. When media services
  restart while the app is suspended, callservicesd can keep a stale audio
  session ID for the app and never activate call audio again in that process
  (Apple DTS, FB23709940). LiveCommunicationKit never re-sends its
  provider configuration, and iOS 27's own stale-ID check compares only the
  app's unchanged ID, so a new manager is the only public way to refresh it.
  Do not return to one app-lifetime manager, and never activate the audio
  session from the app. A fulfilled start or join that gets no `didActivate`
  within 5 s (normally under 1 s) fails visibly instead of leaving a silent call.
- The WebRTC audio session uses `.playAndRecord` with `.voiceChat`, HFP, system
  input routing, echo cancellation, gain control and noise suppression. Unlike
  dictation, Voice Mode never pins the built-in microphone, so AirPods and
  Bluetooth follow system call behavior.
- The app sends only SDP and control metadata through the gateway. Audio flows
  directly between WebRTC and OpenAI's realtime service; transcripts and
  handoffs arrive as app-server notifications. The call's `@concurrent`
  pump drops every other method and decodes realtime payloads off the main
  actor, which receives only decoded voice events, in order.
- Realtime audio is a replaceable transport over the canonical agent thread.
  Minimizing keeps the `RTCPeerConnection` alive. A hosted call cannot be
  reattached once it ends, so the app resumes the same logical session by
  reusing its stable `realtimeSessionId` and starting a new WebRTC call with
  reconstructed context.
- Reconstructed context merges dated canonical chat messages with voice-only
  transcript entries persisted in the host's `realtime-voice-history.json`
  (`RealtimeVoiceHistoryStore`). Its writes coalesce for up to 5 s and flush at
  call teardown, backgrounding and host retirement; an undecodable file is set
  aside, never overwritten. Reconstruction then applies the desktop client's V3
  bound: the newest 128 role-bearing items within 8,192 estimated UTF-8 tokens. Keep transcript notifications attached until
  `voice/session/stop` is accepted; app-server separately routes any remaining
  transcript tail through its agent handoff. This applies to direct Codex
  threads and to Claude's shadow thread.
- Entering Voice Mode in an existing chat resumes that same agent session. A
  fresh chat creates one provisional agent thread, and a failed fresh attempt
  removes only that provisional row. Do not reintroduce an allow-list of
  "voice threads": it once made resumed calls silently create unrelated
  sessions.
- The composer voice button preserves the current conversation. Only entry
  points that set `startsFreshVoiceChat` start a fresh chat: the Voice Mode App
  Intent. A resumed call whose chat has no loaded messages reads the thread's
  canonical tail before starting, the same read reconnect uses; an empty
  screen is unknown, not empty, so it never starts GPT Live on that alone. Only
  a tail read that finds no messages starts without chat context, which a
  fresh call hung up before anyone spoke leaves behind, and a failed read
  fails the call visibly. `just voice-probe-resume-context` compiles the iOS history
  builder into the headless WebRTC probe and verifies remembered context in
  returned speech.
- A displaced call receives `voice/session/preempted` and shuts down
  locally without retrying.
- An agent-ended call (`voice/session/agentEnded`, sent for `end_voice_call` and
  the gateway's farewell close) ends the system conversation
  as `.remoteEnded` and is never auto-reconnected. The call matches the
  gateway's stable error text `voice call already ended by the agent`. A
  reconnect there once resurrected a call the model had just hung up.
- `thread/realtime/error` with `terminal: false` records a diagnostic and leaves
  the call open without retrying output. Missing `terminal` remains terminal.
  `RealtimeVoiceTranscriptState` seals an open generated assistant partial once and
  clears its live caption while preserving caller text. `VoiceCall` returns to
  listening with the same call identity. After that interruption, assistant
  Done seals only accumulated delta text; its uncorrelated final text never
  imports or replaces content. Done without a partial has no text effect.
  This policy survives new deltas, finals, errors and same-provider recovery.
  An error without open assistant output neither activates nor clears this policy.
  A delayed Done may split display segments; these segments identify neither
  provider turns nor playback. Final-only assistant text and revisions are
  unsupported after activation until a fresh provider session.
  The first matching SDP receipt for each native connection resets this policy,
  seals any old assistant partial and preserves historical entries and caller
  text. The gateway starts a new provider WebRTC session for that connection;
  Core emits its SDP after provider creation and before transcript fanout. A
  local start attempt, its RPC acknowledgement and ICE recovery do not reset it.
  The existing resume-history policy still collapses consecutive equal role/text
  entries independently of the local transcript's distinct display segments.
  `thread/realtime/closed` retains its provider reason: only legacy
  `transport_closed` automatically reconnects. `providerClosed: true` is
  authoritative even when its reason equals a reserved legacy string such as
  `transport_closed` or `requested`; an omitted flag preserves legacy behavior.
  Provider termination and unknown or missing reasons end the call without
  reconstructing context. Local `requested` stops and provider `close_requested`
  or `remote_hangup` close normally; expiry, safety, lost and unknown closure fail.
  The gateway independently fences the exact logical session against automatic
  reclaim, protecting older clients too; a new explicit user start remains valid.

## Speech output and dictation (`Services/Speech/`, `Services/Transcription/`)

- `GatewaySpeechAccess` is the app's only speech-credential path. Each chat
  model binds it to its host, which hands SpeechKit a `.relay` at
  `<gateway>/speech/<provider>` with the host's bearer. The app carries no
  provider keys.
  - `explain(_:provider:)` turns SpeechKit's `relayRejected(kind:)`, bare or
    wrapped in `RealtimeDictationError.connectionFailed` or `.streamFailed`,
    into an error naming the host, provider and cause. SpeechKit raises that
    error only for the relay's rejection marker. Other failures pass through
    unchanged.
  - Settings cannot know which providers a gateway has configured, so a missing
    key surfaces when speech starts, as an error naming the host and provider.
- `VoiceOutputController` (`@Observable @MainActor`) queues replies for Gemini
  3.1 Flash TTS Preview through the host's relay; `SpeechPreferences` owns
  "Speak replies".
  - One streaming Gemini request both adapts Markdown-rich text for listening
    and generates speech; there is no separate text post-processing model call.
  - SpeechKit uses the low-latency Generate Content stream and starts playback
    early only when measured delivery can stay uninterrupted; otherwise it
    buffers to completion.
  - The prompt is friendly and casual. It tells Gemini not to read Markdown
    syntax, raw links, code, diffs or terminal output aloud, and to point the
    listener back to the chat.
  - Spoken replies are independent of Voice Mode, whose audio arrives over
    WebRTC.
- **Shared library opt-in.** The workspace owns `SharedDictationLibrary`; the
  device-local choice is off by default. It freezes a shared chat plan and
  journals original microphone buffers before provider resampling. Connected model/language controls edit the shared profile; composer UI contains no library status. The workspace owns and drains utility-priority original sealing independently of stop-to-text delivery. The shared
  capture and provider recovery recording use one UUID but separate lifetimes:
  draft receipts never authorize archival deletion. Unconfirmed owners remain
  held; recovery of a known other-account capture is fenced. The 512 MiB spool
  never evicts unpublished originals. See `docs/unified-dictation.md` for
  ownership, signing and delivery gates.
- **Dictation.** Composer dictation streams PCM16 mono to the selected realtime
  model, ElevenLabs Scribe v2 Realtime by default, through one SpeechKit
  `RealtimeDictation` per dictation. SpeechKit owns its connection, bounded
  audio queue, final commit and finalization wait.
  - `RealtimeTranscription.make` owns the model-to-provider configuration and
    returns the provider-neutral `RealtimeTranscriptionSession` with its gateway
    provider. The session reports the sample rate the microphone must deliver
    (24 kHz for OpenAI realtime, 16 kHz elsewhere), and the capture sink
    resamples to it.
  - The writer opens, capture starts and the `RealtimeDictation` starts
    connecting, with nothing waiting on the network. Each chunk goes to the
    writer, then to the dictation, so an offline dictation still records.
  - At stop, `RealtimeDictation.finish()` succeeds only once the provider
    finalizes the final commit. Any `RealtimeDictationError`, including a failed
    connect, an early stream end and a finalization timeout, makes
    `VoiceInputController` transcribe the saved recording once with the
    provider's batch model before reporting the failure. A cancellation keeps
    the recording and propagates.
  - A stop that arrives while the start is still running cancels the start and
    waits for it: capture it already opened is stopped and its audio kept, and a
    start that captured nothing ends quietly and discards its empty recording.
    Any failed start keeps its recording only when it holds audio
    (`closeAfterFailedStart`).
  - Azure Speech streams through `ProgressiveRealtimeTranscriptionSession` as a
    progressive WAV upload that finishes on stop, with a longer finalization
    timeout.
- **Saved recordings.** Every dictation is written as it is spoken to
  SpeechKit's `DictationRecordingStore` (`DictationRecordingStore.app` in
  `DictationRecordings.swift`: Application Support
  `RemoteCoder/dictation-recordings`, owner `ExecutionTarget`, at most 5 kept
  for 7 days). It is the provider recovery copy: the PCM16 chunks sent to the
  realtime session are the chunks saved, and batch transcription uploads it as
  WAV, or AAC above the smaller of SpeechKit's engine limit
  (`TranscriptionEngine.maximumAudioByteCount`) and the speech relay's audio cap
  (`GatewaySpeechAccess.maximumRelayedAudioByteCount`, under the gateway's
  64 MiB request body limit).
  - The writer owns write failures. `append` never throws; SpeechKit logs the
    first failure once and saves no later audio. `finish()` throws
    `IncompleteDictationRecording` when a prefix was saved, which stays
    recoverable while the batch fallback refuses it, and the cause itself when
    nothing was saved.
  - `VoiceInputController` finishes the writer before any network call. The
    dictation session discards the audio only after `ComposerDraftStore.appendDictation`
    has saved the text together with its `DictationReceipt` and `flush()`
    succeeds. A crash, kill, failed transcription or failed save leaves the
    recording in the store. `appendDictation` throws instead of reporting, so a
    text that never reached the draft can never authorize a discard.
  - `DictationSession` (`ChatScreenModel`) lists this target's recordings
    when the chat becomes visible, when the scene becomes active and after a
    failed dictation. It discards recordings whose receipt is saved
    (`hasSavedReceipt` ignores pending changes, which a failed save leaves
    behind) and shows the rest as composer tiles that transcribe into the
    current draft. A failed tile reads "Tap to retry" and raises the voice
    error alert; a tile whose recording no longer exists is dropped. A deleted
    tile's recording is excluded from listings until its discard finishes,
    which then restarts the refresh.
  - Receipts expire by age, once older than the recordings' 7-day retention.
    Never remove one because its recording is missing from `recordings()`: the
    list omits recordings still being written and recordings whose owner no
    longer decodes, so the text could be inserted twice after a relaunch.
    `appendDictation` skips the text when its receipt already exists, because
    SwiftData's `.unique` upserts rather than rejecting a duplicate.
- `RemoteCoderTranscriptionService` transcribes saved recordings with batch
  models. A streaming model selected there uses its provider's closest batch
  model. The app keeps no per-engine upload limits:
  a saved recording is capped by SpeechKit's engine limit and the relay's audio
  cap.
- `TranscriptionSettings.swift` is the catalog: `TranscriptionProvider`
  (ElevenLabs, OpenAI, Google Gemini, AssemblyAI, Azure Speech) to
  `TranscriptionModel`, each with a `capture` mode.
  - Settings expose Provider, Model and Language. English & Swedish conditions
    automatic detection through SpeechKit, while single languages stay pinned.
  - The legacy raw values `elevenLabsScribeV2Realtime`, `openAIGPT4oMini` and
    `gemini35Flash` must keep decoding.
- `VoiceInputController` (`@Observable @MainActor`) runs permission prompts, the
  recording lifecycle, and conversion into composer text. It is the only writer
  of `isRecording` and `isTranscribing`; the view model calls its `mark…`
  methods.
- `AudioRecorder` drives a `CaptureAudioSession` (`AVCaptureAudioSession` on iOS:
  recording-only `AVAudioSession`, prefers the built-in
  microphone), delivers PCM16 mono chunks to one `PCM16CaptureOutput`, and tears
  down reliably so repeated taps work. For dictation that output appends each
  chunk to the recording writer and then to the `RealtimeDictation`. It pauses
  on interruptions and route changes, and resumes when an interruption ends with
  `shouldResume` or an input route returns.
- The `audio` and `voip` background modes keep dictation and LiveCommunicationKit
  calls running in the background.

## Live Activities and widgets (`Platform/iOS/LiveActivities/`, `RemoteCoderLiveActivities/`)

- `ActiveTasksLiveActivityService` is the actor that keeps one aggregate Live
  Activity per gateway host. The app requests it with the gateway's complete initial content and registers
  its push token; the initial content uses the gateway's relevance score,
  keeping attention above running-only hosts. The host's gateway authors every update and ends it, so it stays
  current while the app is suspended. The app ends it itself only when Live
  Activities are disabled or the host is retired. It touches only activities
  carrying its own host id, plus host-less ones from earlier builds.
- `RemoteCoderActiveTasksAttributes` carries the count of running root
  conversations (`activeTaskCount`), up to three `attention` rows (thread,
  account, title, `finishedUnread` or `question`, completion time) and
  `attentionCount`. `attention` is optional for activities from earlier builds. Its `hostID`/`hostName` are optional so older activities still
  decode; those count as legacy and are only ever retired.
  `Shared/AppExtensionContract/` is its single owner, compiled into the app and
  the extension.
- `RemoteCoderActiveTasksWidget` shows only what waits for you. A Lock Screen
  row is a conversation with an unread finished turn: an accent dot, or an
  orange bubble when it also asked a question you have not seen. It shows the
  title and completion time and links to that conversation; `+N more` covers the rest. Running work is
  only a count in the header's corner, inside a ring that turns when the count
  changes. The Dynamic Island's expanded view shows the lead row; compact and
  minimal show the question symbol, else the waiting count, else the running
  ring. Content is always visible, never `privacySensitive`. The glyph is
  `Assets.xcassets/LiveActivityAppGlyph.imageset`.
- `RemoteCoderVoiceCallWidget` renders the call activity Voice Mode's intent
  starts: host name and call timer. A tap opens `remotecoder://chat/call?id=`,
  which presents only that exact call while it is live, never starting one.
  Its `RemoteCoderVoiceCallAttributes` carry no content state, so nothing
  updates it while the call runs.
- `RemoteCoderLiveActivitiesBundle` registers the active-tasks and voice-call
  Live Activities and `RemoteCoderCameraControl`, whose `CameraCaptureIntent` makes RemoteCoder
  available to Camera Control, Control Center, the Lock Screen and Action button.
  App Intents provide New Chat and Voice Mode quick actions.
- The app's generated Info.plist sets `NSSupportsLiveActivities=YES`.

## App Intents and quick actions (`App/`, `Shared/`)

- `RemoteCoderCameraCaptureIntent` lives in `Shared/AppExtensionContract/` and
  compiles into the app, widget and capture extension. `REMOTE_CODER_APP` gates
  its app-only workspace dependency and `.quickAction(.camera)` routing.
  The system chooses the app or capture extension; the intent uses no app
  context and is not listed in `RemoteCoderAppShortcuts`. The Mac excludes
  the intent and shared viewfinder sources.
- The shipping intents are `RemoteCoderVoiceChatIntent` ("Voice Mode") and
  `RemoteCoderNewChatIntent` ("New Chat") in `App/RemoteCoderQuickActions.swift`.
  Both declare iOS 27 `allowedExecutionTargets: [.main]`, so execution and
  default-setting reads belong to the main app.
  - New Chat is a launcher: `supportedModes: [.foreground(.immediate)]`, and
    `perform()` only enqueues a request.
  - Voice Mode adopts the iOS 27 `@AppIntent(schema: .phone.startCall)`
    schema as an `AudioRecordingIntent` with
    `supportedModes: [.background, .foreground(.dynamic)]`. Its `destination`
    is the model (`CodexModelEntity`, a `.phone.phonePerson` entity) and its
    `audioVisualMode` rejects video. The schema is what lets callservicesd
    validate user intent for the outgoing `StartConversationAction`; without
    it a background start fails with CallKit `invalidAction`. `perform()`
    starts the call itself through `ChatWorkspaceModel.startFreshVoiceCall`,
    so Siri and the Action Button start it on a locked device. AppIntents
    traps an `AudioRecordingIntent` whose `perform()` leaves an active audio
    session without a Live Activity, and only a `LiveActivityIntent` may
    request one from the background, so the intent adopts both.
    `VoiceCall.startWithLiveActivity` requests the call's
    `VoiceCallLiveActivity` under the call's own id in the same main-actor
    step that reserves the call, before any audio, and also when the intent
    rejoins a live call; it fails the intent when Live Activities are off.
    That call's teardown ends only its own activity, and `VoiceCall` ends any
    a crashed process left behind before its first intent start. On an unlocked
    device it then enqueues `.presentVoiceCall` with that call's id and
    continues in the foreground. The router can hold that request for up to
    60 s, so it shows the call only while that exact call is live, through a
    `VoiceModeEntry.presentCall` cover whose task never starts a call: a call
    hung up before the app came forward stays ended. A start that
    fails before `perform()` returns is thrown to Siri or Shortcuts. Its default
    `authenticationPolicy` lets anyone holding the locked phone start a call.
- `App/RemoteCoderAppShortcuts.swift` is the single `AppShortcutsProvider`, which
  puts the intents in Siri, Spotlight and the Action Button picker; without it
  they are reachable only from inside the Shortcuts app. Every phrase
  must interpolate `\(.applicationName)`; App Intents silently drops phrases
  without it. Voice Mode is listed first, because the first entry gets priority
  presentation.
- **One request shape, one transport.**
  - `Shared/AppExtensionContract/RemoteCoderDeepLinks.swift` owns `RemoteCoderQuickAction`,
    `RemoteCoderQuickActionRequest` and the `remotecoder://` vocabulary. It
    compiles into the app, the widget and the share extension.
  - Intents and deep links both produce a request and hand it to
    `ChatWorkspaceModel.events`, the `ExternalEventRouter`. It holds the
    latest event in memory for at most 60 s and delivers it once, to the
    key screen while its scene is `.active`. An `.open` event goes to the
    screen presenting that address, else the only screen, else a new window
    where supported. A completion-notification tap does not expire; it waits
    for navigation to be ready. There is no app-group event queue: shared
    files wait in the share inbox, and only their share id travels as an event.
  - Do not add a second queue or URL parser in an extension.
- Each stable `ChatRootView` registers its attached window with the router and
  reports activity through `WindowActivity`, including while no selected screen
  exists. The selected `ChatScreen` supplies presentation actions; the root owns
  no-screen preparation and the opening event slot, and detach unregisters the
  window. `ChatRootView` owns `onOpenURL` and the locked-camera user-activity
  handoff to `.lockedCameraCaptures`. Workspace bootstrap, scene lifecycle, notification
  routing and teardown belong to the stable `ChatRootView` root, which runs
  before a host's chat model exists. The selected screen never owns
  workspace startup or teardown.
- **Windows.** Both apps declare `WindowGroup(for: ConversationWindowValue.self)`.
  The iPhone and iPad run one window (`UIApplicationSupportsMultipleScenes` is
  false in `Project.swift`). The Mac runs one conversation per window, with
  native window tabs and the sidebar in every window: ⇧⌘N opens a window, ⌘T
  opens a tab through `WindowTabbing` (AppKit `addTabbedWindow`; SwiftUI has no
  tabbing API), and the app keeps running after its last window closes.
  - Each scene attaches its own `ChatWindowModel` with its own selection and
    screens. A window without a value is the primary one; a window
    opened with a value performs that `.open` once on its own screen.
  - On the Mac, `WindowSceneValueMirror` keeps the scene value equal to what
    the window presents: its conversation, the unsent draft it shows
    (`.unsentDraft`), or no value for the primary window's new chat. `openWindow(value:)` therefore brings
    the window already presenting a conversation forward, and
    `switchConversation(to:)` does the same through
    `ExternalEventRouter.focusWindow(presenting:besides:)`.
  - Workspace operations (send, model picker, new chat, navigation) act on the
    key window, and its selection is mirrored into `HostStore.activeHostID`.
    `WindowActivity` owns key tracking. On iOS the key screen is the scene
    that last became `.active`. On the Mac every open window is active and the
    key window follows `appearsActive`, because all visible Mac windows report
    `.active`. Anything that sends from its own window (the quick-entry panel)
    makes that window key first.
  - An async operation that finishes after the key window changed still
    resolves through the new key window.
  - Each window's sidebar reads `sidebarSnapshot(arrangedBy:in:)` for its own
    window, so it highlights that window's conversation.
  - The router's `openWindow` is attached only where the device supports
    multiple windows.
  - Mac surfaces outside a window (Dock menu, menu bar item, notification
    taps, quick entry's Open in Window) deliver through
    `ExternalEventRouter.summon`. It opens a window when none is open, and it
    always opens one for `.open(.newChat)`. Open RemoteCoder calls
    `openMainWindow` only while no `ChatWindowModel` is attached; that includes
    the gateway configuration and loading states. Main windows and the Settings
    window attach the openers, so they exist even when only Settings was
    restored.
- **Quick entry (Mac).** `QuickEntry` in `Platform/macOS/` is the one owner of
  the ⌃⌥Space hotkey and its panel. `GlobalHotKey` uses Carbon
  `RegisterEventHotKey`, which works in the App Sandbox without an entitlement
  or TCC grant; a global `NSEvent` monitor would need Accessibility. The Chat
  settings toggle registers and unregisters it, and `stop()` runs on
  termination. Each opening attaches its own `ChatWindowModel` on a fixed draft
  slot, makes it the key window while the non-activating `FloatingPanel` is
  key (`setWindowKey`), sends through `workspace.send(from:)` and detaches it on
  close. Open in Window delivers `.open(.conversation(address))` through the
  router; the panel's screen never registers with it. Do not add a second send
  path for the panel.
- **Voice Mode intent parameters: Model, Reasoning Effort, Fast Mode.**
  - `App/CodexIntentOptions.swift` projects the same visible new-chat models the
    composer offers, and `VoiceModeIntentOptions.swift` filters effort and speed
    with `IntentParameterDependency`.
  - `perform()` passes the raw choices (model id or App Default, effort or
    App Default, and Fast Mode) to `startFreshVoiceCall`, which restores the
    cached accounts and model list before the shared `prepareVoiceCall` validates
    them. A cold background launch with no usable cache can fail with an unloaded model list, and
    the error reaches Siri or Shortcuts.
  - The entity query resolves ids through the full catalog, so an explicitly
    chosen model that is hidden in Settings still runs. An id the host no longer
    reports keeps its identity and fails visibly at processing, as does App
    Default with no loaded model list.
  - Processing derives the provider from the raw id and validates once. Errors
    name the cause: an unavailable host, a model list not yet loaded, a model
    the host no longer reports, or no visible model.
  - The summary's static When condition names only the Claude aliases, because
    the Codex list is dynamic. For Codex models without a fast tier, Fast Mode
    offers only Off.
  - App Default model and effort resolve the new-chat settings at processing
    time. Explicit unsupported efforts fail visibly, and app-default efforts
    clamp to the model's visible range. Fast Mode is off for unsupported models.
- **Voice settings.**
  - `startsFreshVoiceChat` is the only voice flag. The Voice Mode intent sets it
    to start a new conversation and clear the chat.
  - Optional shortcut settings apply directly without rewriting new-chat
    defaults; unconfigured entry points use those defaults. Composer entry
    preserves the selected chat, model, effort and speed.
  - `prepareRealtimeVoiceConversation` always captures the selected effort;
    never silently force fresh calls to medium.
  - The composer and voice-header pickers share serialized
    `conversation/settings/update` requests. Reconnect keeps loaded thread
    settings and merges the latest acknowledged selection after every
    preparation suspension.
  - Changes stay within the conversation's provider, and switching provider
    starts a new chat. `startNewConversation()` restores the new-chat settings. A call
    already in flight is rejoined, never restarted.
