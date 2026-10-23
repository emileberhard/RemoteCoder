# RemoteCoder system architecture

Delegated-work identity, the Agents sheet, controls and history filtering are
defined in [Conversation agents](conversation-agents.md). [Glossary](glossary.md)
defines the vocabulary used here and names each term's owning type.

RemoteCoder is the integration root for one shared agent stack on each Mac. It
owns the iOS client, authenticated gateway, matched Codex package, lifecycle
installer, and public compatibility pins. The approved Codex source owns its
narrow patch set; private operator configuration and persistent repair jobs live
in the deployment repository. See [repository-model.md](repository-model.md).

This document maps the current system. Protocol details, operational commands,
and volatile release identity remain in their focused sources linked below.

The [gateway scheduling contract](owned-operations.md#gateway-scheduling)
names the owner of macOS gateway QoS, agent child priority and runtime guards.

## Per-host topology

```text
official ChatGPT macOS ───────────────┐
external Codex agents ────────────────┼─ independent Unix WebSockets
RemoteCoder iOS ─ authenticated gateway ─┤
                                      ▼
                         one managed codex app-server
                                      │
                         ~/.codex rollouts + state DB

RemoteCoder iOS ─ authenticated gateway ─ Claude Code stream runtime ─ native login or optional router
```

Each Mac owns exactly one managed Codex app-server, using `~/.codex` and its
`app-server-control/app-server-control.sock`. Native logins provide basic chat;
an explicitly configured llm-router can own provider identities instead; the gateway exposes only `default-codex` and `default-claude`
contexts ([Provider accounts](provider-accounts.md)). Sharing means sharing the
process and persisted thread store. Every client keeps a separate protocol
connection, performs its own `initialize`/`initialized` handshake and retains its
own request ids, subscriptions, notifications, and server-request ownership.

ChatGPT macOS receives the managed socket through its official external
app-server launch environment. Its app bundle remains unmodified and no private
fallback app-server may remain. Official ChatGPT remote-control clients stay on
OpenAI's client path; RemoteCoder observes their host-side threads through the
same app-server rather than emulating that upstream transport. A host listed
in the private `~/.remote-coder/host-profiles.json` has automatic Desktop management
disabled when configured. RemoteCoder never opens the app there and removes
the periodic helper, while gateway startup still publishes the managed socket
in the Aqua launchd environment for manual ChatGPT launches. Other clients share
the app-server unchanged.

RemoteCoder iOS reaches the host gateway over its authenticated WebSocket. One
downstream connection maps to one upstream app-server connection. Gateway-local
operations such as Claude history pages, `daemon/activeTurns`, command execution,
push delivery, and Claude translation do not change that connection ownership.

External Codex agents use the managed app-server proxy and therefore get their
own connection without spawning another daemon. `host-daemon-rs/AGENTS.md` owns
the topology, runtime package, restart and recovery contracts.

## iOS ownership layers

The app is a tree of owners. Each owns its state and lifetime, and a lower layer
never reaches into a higher one.

```text
RemoteCoderApp / RemoteCoderMacApp  scenes only; reads the aggregate scene phase
├─ macOS only: AttentionCenter      Dock badge and menu, menu bar item; owned by the app delegate
└─ RemoteCoderAppModel              process lifetime; owned by the app delegate on both platforms
   ├─ ChatWorkspaceModel            registry and cross-target flows
   │  ├─ ExecutionTargetRegistry ─▶ ChatTargetModel   one per physical host
   │  ├─ HostServices               one per physical host
   │  │  └─ AutomationManagement   primary service host service inventory/history, shared across windows
   │  ├─ ChatWindowModel            one per scene: selected target, drawer state, screens
   │  ├─ ExternalEventRouter        deep links, quick actions, intents and taps, routed to a screen
   │  ├─ CompletionNotificationCenter, NotificationSurfaceRegistry, PushTokenSources,
   │  │  NotificationAuthorization
   │  └─ LaunchRestore, BoundedFanOut
   ├─ VoiceCallCenter               one call per app, addressed by ConversationAddress
   ├─ AppEnergyMonitor
   └─ iOS only: IncomingCallCoordinator, LiveNavigationSetupController
Window (scene) ─ ChatRootView ─ ChatWindowModel ─ ChatScreenModel   one screen per target, the selected one shown
```

`RemoteCoderApp` holds one `@State` root in `App.swift`, the `RemoteCoderAppModel`;
the chat root (`ChatRootView`) owns bootstrap and teardown and forwards scene
phase, notification taps and token updates to it. `ChatTargetModel` owns one
target's gateway connection, activity, turns, questions, model catalog and
lifecycle, delegating to `TurnRegistry`/`ActiveJob`, `TurnDispatcher`,
`TargetLifecycle`, `GatewayEventPump`, `TranscriptRecovery`, `QuestionReplica`
and `ConversationWarmer`. `ChatScreenModel` owns what one window presents: the
conversation, its transcript subscription, the composer, the drawer and alerts,
through `HistoryEdgeReader`, `DictationSession`,
`ConversationSettingsSelection` and `ScreenAlert`. `ChatWindowModel` owns one
scene's selected target, drawer state and its `ChatScreenModel` per target; the workspace attaches it when the scene's root
appears and detaches it when the root disappears.

Deferred New Chat composer focus belongs to the window's `OwnedTasks`.
Navigation, drawer opening, covering presentations, hiding, inactivity and
detach cancel it. After the cover-dismissal wait, the request must still name
the selected screen and its exact transcript presentation before it applies focus.
`ComposerPresentations` owns the composer's sheets and popovers; the root's
focus guard reads that same state while a presentation remains open. Software
keyboard dismissal cancels a pending request while retaining Mac editor focus.
A completed send may dismiss focus only in its originating, still-presented transcript.

Rules:

- **Windows attach and detach.** A window never tears down a target or a host.
  Teardown happens on app termination (`RemoteCoderAppModel.terminate()`) or
  target retirement. The Mac closes intake, joins admitted work and delays
  termination until every live or already-retiring target has flushed its drafts, checkpoints,
  conversation marks and voice history (`ChatWorkspaceModel.flushForTermination()`).
  Save failures or operations still pending after five seconds name the affected
  host/category in one alert. Keep Open restores intake through activation/reconnect
  after the same admitted work drains; Quit Anyway accepts incomplete work.
  A SIGTERM, as the installers send, makes the quit unattended, even one already
  under way: it waits up to sixty seconds for the same flush, logs anything
  incomplete and quits without the alert, dismissing one already shown, because
  nobody would answer it; the release installer waits ninety seconds for the exit. The signal handler requests that
  quit through `RunLoop.main.perform`, never from its main-queue block: the
  delayed termination's nested run loop cannot drain the main queue while a
  main-queue block is running, so the flush would never start and the app
  would keep taking input while every main-actor task stalled. The alert runs
  from a run-loop block for the same reason: shown from a main-actor task, it
  held the main queue, so admitted work and the SIGTERM handler waited for a click.
- **"Visible" is three signals** (`TargetPresentation`). *Presented*: some window
  shows the target; it gates loops, warming, deferred refresh and observation.
  *Key*: the key window's target; it gates the audio route, spoken replies,
  haptics and the log-export host. *Leave*: each screen runs its own leave
  actions (flush the draft, finish dictation, close the file reader, cancel
  speech). With one window (iPhone, iPad and Mac) all three coincide.
- **One conversation per window.** Opening an address that is already presented
  focuses that window, because `ConversationState` owns one `HistoryWindow` and two
  viewers would evict each other's pages. Mac windows mirror what they present
  into their scene value, so `openWindow(value:)` and `switchConversation(to:)`
  bring the presenting window forward. The window's scene value is
  `ConversationWindowValue` (`.conversation(ConversationAddress)`,
  `.newChat(slot:)` or `.unsentDraft(UnsentDraftAddress)`). A secondary window
  starts on the unsent draft keyed by its slot and then mirrors the exact draft
  it shows, so restoration reopens that draft on its own target; the primary
  window has no value and `LaunchRestore` reopens its draft.
- **Workspace flows take the originating screen.** Send and question answers receive the `ChatScreenModel` that started
  them, never the key window's selection.
- **The workspace routes events to screens.** `ExternalEventRouter` holds one
  event and delivers it once to an `.active` window. An `.open` goes to the
  window already presenting the address, else the only window, else a new window
  where the platform supports several, else the key window; every other event
  goes to the key window. Quick actions and deep links expire after 60 s; a
  completion-notification tap does not, and waits until navigation is ready.
  Each window's stable `ChatRootView` owns registration and window activity even
  while its selected screen is loading or unavailable. The selected screen supplies
  its current presentation actions; replacing it never unregisters the window.
  A no-screen New Chat resolves through the existing new-conversation target owner,
  restores cached accounts only when needed and selects a ready configured target.
  It never joins unrelated target retirements or substitutes an unavailable preferred
  account. Initial and not-yet-mounted presentation events share one root-owned slot;
  newer events cancel older preparation, and detach cancels it and unregisters.
  Admission captures the workspace navigation generation before scheduling;
  queued or suspended work checks that same generation before any mutation and
  cannot supersede later navigation or adopt its generation.
- **Selection.** Each window owns its selected target, so windows present
  independent conversations. The conversation list is target-scoped and a screen
  holds only what it presents. The key target comes from the key window, and
  its selection is mirrored into `activeHostID`, the persisted last-used host,
  which workspace navigation, Shortcuts and direct exec follow.
- **Windows.** The iPad app runs one window
  (`UIApplicationSupportsMultipleScenes` is false in `Project.swift`). The Mac
  app's `WindowGroup` is keyed by `ConversationWindowValue`: New Window,
  Open in New Window and native tabs (`WindowTabbing`) each present their own
  conversation, and the focused window is the key window. Send, the model
  picker, the question editor, voice-call binding, dictation hand-off, the
  foreground-refresh throttle and observation reconciliation resolve through
  the key window rather than the originating one.

| Invariant | Owner |
|---|---|
| Retirement fence | `ChatTargetModel` (`TargetLifecycle`); the workspace rebinds screens of a retired target, and screen publishes recheck the fence |
| Scene generation | `RemoteCoderAppModel` → targets; the phase is active if any scene is active, background only when all are |
| Background grace | `TargetLifecycle` via `BackgroundExecution`, from the aggregate background |
| Audio route | The key target, if not retired: exactly one owner |
| Voice-call owner | `VoiceCallCenter` (target and address), shown by the key window's screen for the call's target (`voiceCallOwner`) |
| Notification navigation fence | `CompletionNotificationCenter`; surfaces are per scene (`NotificationSurfaceRegistry`) |
| Launch restore | `LaunchRestore` |
| Refresh fan-out | `BoundedFanOut`: key target first, then presented targets, then the rest |
| Transcript identity | `ChatScreenModel`, per screen |
| Draft ownership | `ComposerDraftStore` lookup; the current draft is held by the screen |
| Observation capture | `ConversationObservationCoordinator`, one per target, holding the threads its presenting screens want |

## iOS host ownership

The phone talks to every configured gateway at once. One `ChatWorkspaceModel`
owns one `ChatTargetModel` per execution target, and that model's host id,
`GatewayClient`, history and metadata services, `ConversationIndex` and
`HostDirectories`, plus the host's Live Activity service, are immutable for its
lifetime. Choosing another host changes only which model is presented; the
others keep their sockets, drafts, selected conversations and running turns. A
host whose endpoint or token changes is retired and replaced, never rebound, so
no thread- or turn-keyed state can cross gateways.

Retirement is a synchronous fence, not a request. Because the outgoing model and
its replacement share the same host-scoped files, the model is marked retired and
its bootstrap, warm-up and turn-dispatch tasks are cancelled *before* it leaves
the registry; closing the socket, the host directories and the Live Activity
follows asynchronously. Every suspension point in bootstrap, the foreground pass
and turn dispatch rechecks that fence when it resumes, and the foreground pass
additionally carries a scene generation, so work that resumes after the app is
backgrounded — or after its host is gone — stops rather than restarting polling,
sending a turn or publishing device-wide state. Each scene phase supersedes the
previous phase's pass, so a background pass that resumes after the app is active
again stops before backgrounding the remaining hosts. Fan-out over hosts is bounded and
slides (`BoundedFanOut`: three at a time, key target first, each worker taking the
next host as it finishes), so one unreachable gateway delays only itself.

Conversation identity is `(host uuid, thread id)`. Thread ids are unique only
within one gateway, so the merged sidebar, selection, pins, forks and completion
routes all carry the host. Rows from every host are ranked together below a Pinned
header, or grouped into project sections (see *Conversation drawer order*), with
the composite address as tie-breaker, and a host that fails
to refresh keeps its cached rows and owns its own error message. The drawer is
opened by an accessible control (`open-conversations`), not only by a horizontal
drag, and `RemoteCoderUITests` (`just ios-ui-test`) drives that path in the
simulator: it opens the drawer, requires rows from more than one gateway
(`conversation-row-<host uuid>|<thread id>`), selects one on each host, and
asserts the chat's `active-host` header follows the row's owner. It needs a
simulator with several gateways already configured, so it has its own scheme
and remains separate from the default Mac-native tests. Run it only for changes
that affect the drawer behavior it exercises.

`ConversationDrawer` owns the reveal as one normalized progress value (0 closed,
1 open) held by `DrawerMotion`. The chat moves aside as a rounded surface over
the mounted history, with an adaptive width and a visible strip for dismissal.
Only the surface mask extends through the system safe areas; the chat retains
its normal content insets. The screen's `NavigationStack` contains the drawer.
The drawer's `GeometryReader` supplies the available height to both panels,
including changes for the keyboard.
Vertical `containerRelativeFrame` sizing must not be used here: it retained the
full navigation-container height even after the drawer's available height shrank.
The chat offset, sidebar parallax, dismissal scrim and corner lift are functions
of that progress; changing it never rebuilds the stored chat and sidebar content.
Both panel offsets are rounded to whole device pixels. The sidebar's width is
fractional (76 % of the screen, clamped), and a sub-pixel offset changes how
UIKit-backed descendants, such as the history list's scroll view, round to the
pixel grid. Their width then flips by a pixel from frame to
frame, and text that fits within a pixel re-wraps or truncates while the drawer
moves: a sidebar row title jumped between two line breaks on every frame of the
slide.

The drawer is deliberately not a scroll view. It used to be a horizontal
`ScrollView` wrapping both vertical scroll views, and a moving UIKit scroll view
captures the next touch to stop itself: during the drawer's opening or closing
motion it swallowed the whole first drag on the history list or transcript, and
a coasting transcript swallowed the first horizontal swipe meant to open the
drawer. One `UIPanGestureRecognizer` (`DrawerPanGesture`, a
`UIGestureRecognizerRepresentable`) now owns horizontal drags over both panels
and is composed through its delegate's failure requirements:

- Vertical-only scroll views (transcript, history list, composer text) wait for
  the drawer pan to fail. A horizontal first gesture therefore opens or closes
  the drawer even while they decelerate, and a vertical one fails the pan and
  scrolls them.
- Horizontally scrollable descendants (horizontal overflow or bounce) take
  precedence: the drawer pan waits for theirs to fail.
- The pan begins only when the movement is horizontally dominant and the drawer
  can move in that direction.

Because nothing around the panels is a moving scroll view, whichever panel is
visible scrolls on its first touch, including during the drawer's own settle.
Rows keep their standard buttons, context menus and accessibility actions at all
times; a tap during drawer motion selects normally.

Dragging moves the progress 1:1 with the finger, and grabbing the drawer during
a settle continues from its drawn position. On release, the resting side comes
from the position plus 0.3 seconds of the release velocity, so a short flick of
about 40 points at roughly 450 points per second is enough to open or close it,
while a slow drag still rests on the nearer side. A critically
damped 200 ms SwiftUI `Spring` carries the release velocity; a display link
samples it at up to 120 Hz and stops at the resting edge instead of overshooting.
Button, conversation-selection and accessibility requests arrive through the
`isOpen` binding and use the same spring from the current position and velocity.
Reduce Motion removes their travel and the sidebar parallax. A request that
arrives during a drag ends that drag's control, so a later finger lift cannot
reopen a drawer that a selection closed. A drag that begins from the closed
state commits `isOpen = true` immediately; history refresh starts independently
and never gates movement.
Switching conversations from the drawer is refused while the composer is
recording: the drawer stays open, plays `refused` feedback and shows a transient
notice in its bottom status area. The recording waveform is not a decoration and
keeps sampling while the drawer covers the chat. It samples on the energy
policy's cadence but draws from a paused-when-idle animation timeline, gliding
the bars at display rate between samples; under energy pressure it steps once
per sample. This supersedes the 2026-09-20 pass's sleep-driven 40 Hz redraw,
which moved in visible steps on ProMotion displays.
Disclosure feedback fires on finger lift after a drawer drag, including a slow
drag released at the endpoint. It uses the shared gesture
feedback modifier in that same update, with no delayed completion pulse.

Host-local client state is per host: `RemoteCoder/hosts/<host uuid>/` (`HostStorage`
scoped by `StorageScope`) holds the conversation index, conversation metadata,
thread-header cache, usage snapshot, voice history and conversation marks
replica, and the working directory uses a host-suffixed defaults key (as pins
did before they became gateway-owned marks). A one-shot migration splits pre-multi-host state
across the configured hosts, moving only entries with exactly one provable owner
(the active host for the single working directory; the one host whose cached
history contains the thread for pins and conversation mappings) and reporting the
rest instead of copying an ambiguous mapping everywhere. Legacy files and keys
are left intact, and provider-owned data is simply refetched. The migration is
synchronous and runs while the workspace is constructed, before the first chat
model exists: the conversation index, pin store and working-directory default each
read their state once at construction, so a migration that ran afterwards was
overwritten by its own consumers. There is no shared working-directory fallback
either — the bundled path belongs to one machine, so a host without its own
resolves its remote home and the chat header offers "Choose Folder" until then.

Device-wide services remain single but become host-aware. A completion
notification resolves to the one host that knows its session; two owners ask the
user rather than opening the wrong machine's chat. An explicit host id in the
payload wins, but a payload naming a deleted host is unresolved rather than
matched by thread id against a surviving gateway, and there is no fallback to the
visible host: a thread older than every cached page is probed with `thread/read`
on each host instead. The owning host opens the conversation before it becomes
visible, so the tap never shows that host's previous conversation, which could
otherwise be marked seen. A cached session opens at once; only an uncached one
waits for a history refresh first. Broker delivery owns notification
presentation. The app accepts both Codex and Claude payloads, shows one in-app
banner in foreground, and leaves inactive/background presentation to iOS. The
socket completion path never creates a second banner, including during replay.
Before broker delivery, the gateway uses the Agents owner's bounded ancestry
lookup for completion, question, explicit tool and recovery-failure alerts.
Verified delegated children are silent; unverified ownership is journalled and
suppressed. This affects only delivery, leaving child cards and parent callbacks
intact. A root may surface a need through its own conversation.
The workspace owns a persisted 256-event ledger keyed by host and the gateway event ID.
Legacy account fields do not split delivery identity.
A scene-bound non-key window renders the one banner above sheets, Voice Mode,
and workspace loading/configuration. Only its measured banner accepts touches,
and its expiry starts after rendering. Malformed/future payloads retain delivered
copy without invented navigation. A single navigation task and generation fence
all notification reads before selection or question focus can change. Exact open-conversation matching
uses host and thread; a missing host cannot prove a match. A device
registration includes its app-configured host UUID, stored with that device's
tokens, so an alert is stamped with the host of the device it is sent to and a
rotated token cannot borrow another registration's host.
Automatic conversation alerts require the app setting and APNs
authorization/delivery; there is no separate socket-only alert channel when
permission is denied. A callback received during a transient inactive state
(for example Control Center or the lock transition) uses the system surface,
even if its conversation was visible before that transition. It never consumes
an invisible in-app banner. An alert delivered while iOS suspends the app does
not invoke the foreground callback; removing socket banners prevents a replay
alert on activation, but the foreground ledger cannot prove that iOS displayed
an earlier background delivery. Likewise, a first delayed completion received
after leaving a conversation can still alert: the current payload has no
canonical turn ID with which to prove that the attention owner already marked
that completion seen. Event IDs and wall-clock times are not parsed as proof.
Explicit
spoken notifications may play their audio with the in-app banner; generic
operator alerts also use that banner in foreground. Each
host runs its own aggregate active-tasks Live Activity, tagged with its host id.
Attention counts describe known attention and never claim complete question
coverage. Startup restores previously known question subjects from bounded
question-state discovery and saved attention rows through the existing passive
observer. Restoration readiness is separate from retained watches; absent or
unavailable required watches block empty publication and End. Question-free
sidecars do not certify the complete native history inventory. Known running and
unread state continues independently. Claude restart recovery stays unavailable until its
journal is readable and settled and resumed starts reach the turn ledger.
The host-default scope must provide fresh state before host publication;
startup discards retired scopes. Unreadable durable state or an unfinished
restoration cannot certify an empty host. A report superseded during persistence
or delivery stays unavailable until a current report replaces it.
The gateway publishes the same epoch- and revision-scoped attention snapshot
through `daemon/liveActivity` and `daemon/liveActivity/changed` and APNs. Before
inactivity the app retains that snapshot, so an attention-only activity starts
with its actual rows; the gateway owns later updates and normal End,
so an idle host may retire only its own activity (and host-less ones from
earlier builds). Audio is one route and one system conversation: spoken replies
come only from the host on screen, hiding a host completes its in-flight
dictation into its own draft and releases the microphone, a live call ends only
when *its* owning host is retired, and the voice surface presents the call's
owner rather than the sidebar selection. Log export follows the visible host.

### LAN route

A host's configured address is usually its tailnet address. When the gateway
sets `RC_CODEX_GATEWAY_LAN_PORT`, it also serves the same routes over TLS 1.3 on
`0.0.0.0`, with a persisted P-256 key and a certificate for its
`<LocalHostName>.local` name (see `host-daemon-rs/README.md`, *LAN TLS
listener*). Its authorized `/health` publishes that listener as
`lanEndpoint: {host, port, spkiSha256}`, or `null` when it is not serving.

`GatewayRoutes` (`Core/Sources/RemoteCoderCore/Hosts/`) owns the choice for one
host and is shared by its services through `HostServices`. It
learns `lanEndpoint` from `/health` after a connection, at most every ten
minutes, and caches it in the host storage directory as `lan-endpoint.json`,
tagged with the configured address it was learned from; a cache from another
address is ignored. The pure `GatewayRoutePolicy` decides:

- LAN is offered only with a learned endpoint while `NWPathMonitor` reports a
  usable Wi-Fi or wired interface. Cellular never carries it.
- `GatewayClient` races LAN first with a 2-second budget, then the
  configured address (see *Switching routes*). A LAN failure suppresses LAN for five minutes, until the
  network path identity or the endpoint changes, and relearns the endpoint over
  the configured route so a rotated key or a renamed host is picked up. The
  existing monitor compares `NWPath` snapshots and carries an opaque identity
  in `GatewayNetworkPath`. A duplicate snapshot preserves cooldown and verified
  LAN state; a different identity clears both even when local availability
  stays true.
- A failed LAN attempt closes only its own socket; only the winning route's
  socket is installed and initialized. Receive and send failures before
  `initialize` completes belong to that attempt; a late send failure from a
  replaced socket cannot disconnect its successor.
- An idle connection on the configured route moves to LAN (see *Switching
  routes*). The client requires no pending request, no running turn in a
  conversation on screen, no voice call and a foreground app, and probes LAN
  `/health` first.
- File uploads and downloads use LAN only after the current endpoint has been
  proven on this network path, and retry over the fallback routes after a LAN
  transport failure. Download application errors do not trigger transport
  fallback.

The LAN session trusts nothing but the pin: `GatewayLANTrust` accepts the
server only when the leaf certificate's P-256 SubjectPublicKeyInfo hashes to
the learned `spkiSha256`, and cancels every other challenge, so the bearer is
sent only after that handshake. A spoofed `.local` responder gets no request.
With no learned pin there is no LAN route.

### Relay route

The relay is a second way to reach the LAN listener when the configured
(tailnet) address fails, with no Tailscale on the phone, the host or the
control plane. A Stockholm VPS accepts TLS on its IPv4 literal, admits only
authenticated `CONNECT` requests for each host's relay name, and reaches each
Mac's LAN listener through that Mac's reverse SSH tunnel. Inside, the app runs
the same pinned LAN TLS, so the VPS sees only ciphertext.
[`relay-route.md`](relay-route.md) owns the server, tunnels and security
boundary.

The gateway serves its relay route on the authorized, uncached `GET /relay`
(`{proxyHost, proxyPort, proxySpkiSha256, targetHost, targetPort, username,
password}`; 404 when the host has none, 503 when its file is unreadable),
never in `/health`, which tools print. `GatewayRoutes`
reads it in the same learn cycle as `lanEndpoint` and keeps it in the device
Keychain (`KeychainGatewayCredentials`, scope `.relayRoute`), loaded on first
use inside the actor and tagged with the configured address it came from.
Only a 404 removes the cached route; any other failure keeps it. Its
sessions dial the proxy through `ProxyConfiguration(httpCONNECTProxy:)`, pin the
proxy's SPKI in a TLS verify block, answer its 407 with `applyCredential`, and
reuse `GatewayLANTrust` for the inner handshake. The relay ends at the LAN
listener, so it is offered only with a learned LAN pin.

`GatewayRoutePolicy` orders routes: LAN when it may work, then the configured
address, then the relay. Connections race them in that order (see *Switching
routes*). HTTP exchanges go through `GatewayRoutes.send`, which tries a verified LAN,
then the route the gateway connection currently uses, then the rest; it moves on
after a transport failure and stops at any gateway answer. A mutation
(`GatewayTraffic.mutation`, such as an account change) moves on only when the
failure proves the request never reached the gateway: an unresolvable or
refused host, no network, or a TLS failure the system reports. A rejected pin
cancels the challenge, and a timed-out or lost write fails too, instead of being
repeated over another route.

- The configured route and the relay fail only on a broken network path:
  timeouts, unresolvable hosts, lost connections, TLS or proxy failures, and an
  expired receive deadline. A refused connection fails at once and an HTTP
  error is the gateway's answer, so neither reorders routes by itself; when a
  later route connects in the same attempt, every route that failed before it
  is demoted whatever its error. A failure from an attempt that started before
  the latest network path change is ignored.
- A failed fallback goes behind the other one while it backs off, exponentially
  from 60 s to ten minutes; it is never dropped. A connection or exchange
  success, a new relay or a new network path clears the backoff.
- With a relay known, the configured WebSocket handshake gets 5 s instead of
  10 s; the relay gets 10 s.
- An idle connection moves to a preferred route (see *Switching routes*): from
  the configured route to a probed LAN, and from the relay to a probed LAN or a
  configured address that is not backing off.
- Settings → Hosts probes the relay's `/version` and shows whether it answers,
  so a broken fallback is visible before it is needed.

The gateway client retains request ownership through cancellation and timeout. An
abandoned request sends `$/cancelRequest` with its original JSON-RPC ID only when
that socket's `daemon/ready` advertised `capabilities.cancelRequest`; connection generations
fence delivery. The gateway decides which requests can be cancelled; non-query
and native passthrough requests ignore cancellation frames.
The local waiter ends immediately and ignores the eventual cancellation response.
`GatewayRequestRecovery` centrally retries only typed retryable capacity errors,
at most three times with 100/200/400 ms exponential backoff and 20% jitter,
within the original request timeout. Those refusals prove work was not admitted,
so retry safety comes from the gateway's error contract, without a client method
list. Cancellation ends recovery. Prefetch and foreground callers share the same
recovery policy, including when a foreground caller joins a warmer-started read.

### Switching routes

`GatewayRouteRace` connects over several routes at once, happy-eyeballs style.
Each attempt opens the WebSocket and waits for the gateway's first frame
(`daemon/ready`), which the receive loop then processes first. The first route
starts at once; the next starts when the previous fails or after its head start
(0.5 s after LAN, 1 s after the others), so a silent tailnet delays the relay by
about a second. The route's handshake timeout bounds the upgrade, and an
upgraded socket gets the request timeout more for its first frame. A gateway
that closes the socket before that frame fails as not ready and leaves the
route's backoff alone; silence and transport errors still count against the
route. The first attempt to answer wins and the rest are cancelled or closed.
Other failures reach `GatewayRoutes` for backoff.

A move between routes connects the new socket while the old one keeps serving,
then closes the old socket, installs and initializes the new one, and finishes
the notification streams without emitting `.disconnected` or counting a
disconnection. The pump sees an unchanged `disconnections` count, skips the
reconnecting report and replays from its cursor, so the glow never flashes red.
A failed installation falls back to an ordinary disconnect. Requests pending on
the old socket fail, since replaying them could repeat a side effect. Frames the
new socket delivers before the pump resubscribes are not seen live; replay
recovers the sequenced ones.

A stalled route hands over the same way. When a ping is outstanding and the
receive loop has waited without a frame for three smoothed round trips (2–4 s,
never under 1.5 round trips; 4 s before the first sample), the client races one
standby connection per unanswered ping (a network path change re-arms it), with
the stalled route last. Time the loop spends processing a frame does not count,
because URLSession delivers no pong while nothing is receiving. The client
hands over only if the old socket is still silent, nothing else replaced the
connection meanwhile, liveness checks are running and no voice call of its
target is active, checked before and after the race: the call's gateway session
belongs to the socket, so the client receives that hold when it is constructed.
An announced large frame suspends this, and the receive deadline still
disconnects when no standby connects.

An idle connection off LAN moves to a preferred route: the routes before it in
`GatewayRoutes.connectionRoutes()`, so a backing-off configured route is not
preferred over the relay. `ChatTargetModel` runs one loop that tries on
connect, foreground, presentation, every turn's end, every network path change
and every 30 s, coalescing triggers while a move is in progress and stopping in the
background. An attempt that finds requests in flight retries after 1 s, so the
move follows the startup reads instead of waiting a full interval.
An attempt first waits for any route learning in flight, so the attempt at
connect sees the LAN and relay routes the new connection is learning. A send or
turn in a conversation on screen blocks a move, because streamed deltas are not
replayed; other agents' turns do not. The client rechecks the model's eligibility
(foreground, no voice call, no running turn on screen) after the race and
before it commits. A move records the route for HTTP
traffic but, unlike a fresh connection, does not clear that route's backoff,
so a route that keeps stalling backs off further instead of flapping.

The connection event carries its route's kind, so the chat model knows which
route carries its gateway connection. On iOS the top-edge glow is green on the
LAN or configured route and blue on the relay, gray while the host restarts on
purpose and red when it is otherwise unreachable, and Settings → Hosts names the
route: "local network", "relay", or for the configured route "Tailscale" when
its address is a tailnet name or address, otherwise the address itself.

Speech, account requests and diagnostics uploads follow the routes too: speech
asks `GatewayRoutes.preferredRoute()` on each access (see *Speech relay*),
`AccountAPIClient` and the `DiagnosticsDestination` send through
`GatewayRoutes.send`, resolving the routes from the host's live chat model; an
account read that ran before a replaced host's model existed is repeated once
the model is installed. A LAN route's sessions never wait for connectivity, so
speech on a LAN that has just gone fails instead of stalling.
Live navigation uploads from the extension and credential enrollment still use
only the configured address.

Launching the app with `RC_GATEWAY_ROUTE=relay` (`SharedGatewayPolicy.forcesRelay`)
restricts every route to the relay once one is known and moves any other
connection onto it, so the relay can be tested from a device on the home
network.

## Agent providers

| Provider | Runtime | Thread identity | Shared client contract |
| --- | --- | --- | --- |
| Codex | Managed `codex app-server` | Native app-server thread id | App-server v2 requests and notifications |
| Claude | Warm `claude` stream process per active session, with native login or configured router auth | `claude_`-prefixed id | Gateway translates stream events into the same timeline/turn DTOs |

Codex is the native persistence and remote-control substrate. Claude is a
second provider owned by the gateway: it keeps Claude's resumable JSONL session
as canonical state and projects output into the same RemoteCoder UI contract.
All Claude sessions use the host-default profile. Native mode uses the user's
unmodified Claude Code login; in explicitly configured router mode, llm-router
owns subscriptions and failover. Startup consolidates retired
provider profiles into their host defaults. `accounts::codex_migration` copies
Codex rollouts, per-thread assets and rows across the pinned state, history,
queue, goals and memories databases; its schema adapter fails closed on drift.
Source homes remain cold copies. The registry is read-only migration input.
`GET /accounts` lists the two defaults and their `retiredCodexAccountIds` and
`retiredClaudeAccountIds`; either retired UUID redirects to the default gateway
at any generation. No enrollment runtime or cross-runtime inventory remains.
[Provider accounts](provider-accounts.md) owns configuration, migration, conflicts,
rollback and redirect removal.
A Claude process lives while it has a turn, a background task or a pending
scheduled wake. Once idle, it stays warm for up to ten minutes, and only the
two most recently idle processes stay warm at once. A retired process resumes
its exact session on the next message. `host-daemon-rs/AGENTS.md` owns the
details.
Provider routing is explicit from the thread id or a new thread's provider
field; gateway-only RPCs remain Codex-independent.

## Composer drafts

Uncertain sends remain unconfirmed. Before showing a delivery error, the send
owner asks the existing transcript recovery owner to reread canonical history
and reconcile the exact client message ID. A matching canonical item suppresses
the error; absence from a bounded page never proves rejection. The app never
resends uncertain input automatically. Recovery also covers a shown running turn
that this app observed rather than started.

Unguarded forwarding, gateway responses, marks/questions, unlocked call-state
publications retain the 32-frame queue and wait at most 100 ms for capacity
before dropping a client. Claude stream fanout uses immediate queue admission
to independent per-client writers; a full queue disconnects only that client.
Claude lifecycle/activity is global, while content is sent to each connection's
`conversation/subscriptions/set` threads (up to 64). A successful first set,
including an empty set, opts into filtering. Older clients that never set retain
legacy full fanout under `docs/compatibility-register.md`. Guarded control/voice fanout and voice transition notifications use
immediate bounded enqueue/drop. The sole socket writer has 750 ms to flush a
Close with code 1013, or 4012 during a planned restart. `GatewayClient` owns
client liveness, described under *Lifecycle and recovery*. These failures
reconnect the client; they never restart a gateway or agent.

A planned restart is announced with close code 4012 ("gateway restarting"): the
gateway uses it whenever it is draining after SIGTERM, or its recovery journal
records an unfinished runtime transition without an error, which covers the
installer stopping the shared daemon before the cutover. The code lives in the
private range because URLSession reports 1012 and 1013 as 1005 without a
reason. The journal's `error` therefore records only failures; recovery retry
progress goes to the gateway log. A retired-ID WebSocket that arrives while the
gateway stops is accepted and closed with 4012 too. `GatewayClient` treats the
first 4012 since its last connection as the start of a 120 s restart window
(`Timeouts.restartWindow`) that ends at the next connection; later 4012s do not
extend it, so a transition that never finishes turns red, and after the window a
4012 reads as an ordinary refusal. Failed attempts
inside the window blame no route, so the LAN route is not suspended for the
host's downtime, and surface `ClientError.gatewayRestarting`, which the drawer's
automatic list refresh defers instead of recording as an error. `GatewayClient` announces
`.restarting` and `.disconnected` on its connection events, and the pump hands
them to the chat model's `GatewayConnectivity`: `.restarting` turns the edge
glow gray and the drawer's host line into "Updating <host>…" in place of the
error. After the window the usual disconnected presentation returns, even for a
later restart the client never reconnected in between. A reconnect retries a
drawer list whose last refresh failed or was deferred.

Delivery evidence imports only canonical user items with an exact unresolved
local receipt ID. It leaves unrelated transcript metadata, order and coverage
to fenced history reads. Cache-bypassing history reads use independent scheduler
operations, so they cannot join a read started before the send; the scheduler's
existing concurrency limit still applies and other readers are not cancelled.

`ComposerSlashCommand` owns the bounded slash-command catalog and suggestions.
`/compact` runs native context compaction on the exact existing conversation and
host before the workspace's ordinary message/handoff path. It requires known
idle activity and no attachments; it creates no user message or new conversation.
The draft clears only its captured revision after admission acknowledgment.
`ConversationSession` owns transient compaction progress across screen changes:
canonical `contextCompaction` items confirm the result, and the exact turn must
finish before sending resumes. Old history does not confirm a new request.
On uncertain delivery, Refresh reads canonical history and fresh covered activity;
confirmed inactivity allows continuing with an explicitly unconfirmed result,
never a fabricated successful completion. Pending gateway compaction admission
reports unknown activity until its canonical turn is known.


Each host's `ComposerDraftStore` owns the editable draft cache and an off-main
`ComposerDraftPersistence` actor that opens, fetches and saves SwiftData. A screen
uses a cached draft immediately or keeps its draft unknown until a fenced async
load completes; presentation never waits for store I/O. The actor transfers
prepared values, and one latest-state writer retains dirty revisions until a
successful save. The editable cache holds 32 strong references; live owners may
retain more drafts. Each write prepares at most 16 dirty drafts and carries only
receipts whose draft revision is included or already durable, retaining the rest
for later batches. Retirement closes document edit admission, ends native composition,
detaches native storage and joins accepted edits and dictation receipts before its
final save. `retire()`
returns success only after persistence is released. A failed save retains its dirty
drafts, receipts and persistence actor in the exact target's registry entry; the
existing draft failure control retries that retirement. That target cannot be
replaced until it saves successfully. The affected window presents the existing
draft failure and Retry control in place; other windows and drafts remain usable.
The failure remains visible during retry and from another selected target. Sends, switches and backgrounding await `flush() -> Bool` when
durability is required; the chat model owns which `ComposerDraft` is showing. Ordered text and pasted-text references, plus separate image/file attachments, are editable user data, stored
under `RemoteCoder/hosts/<host UUID>/drafts/` in Application Support with CloudKit
disabled. The iOS 27 Codable attribute stores attachment values; external
storage keeps their payloads separate from ordinary text edits. Drafts are never
subject to transcript-cache eviction. Inline pasted-text chips open a draft-bound
editor. Save replaces only that attachment in the originating draft; an attachment
already removed or sent cannot be restored by a late edit. Sent attachments are
read-only.

`ComposerDocument` owns range edits for typing, paste, dictation, recall, restore
and explicit replacements. Its main-actor attributed buffer is the native
`NSTextStorage` while mounted; NSTextView and UITextView share that storage
through TextKit 2. There is no synchronized second editable draft. A paste is
one object-replacement character carrying its stable ID. Native selection and
deletion treat it as one unit. Mounted editors share the draft's undo manager;
chip insertion, deletion and viewer edits each create one undo group. Final
unmount clears native undo targets and retains a Foundation buffer snapshot.
Paste classification ignores surrounding whitespace for the 1,500-character
threshold, but inline text and chip payloads retain the exact clipboard text,
including indentation, spaces and line endings. Blank pasted-text runs become
ordinary text, preserving their whitespace without creating a sendable chip.
The native view retains its TextKit graph until it is released. Copy and cut
export expanded plain text. Custom
pasteboard or drag formats are outside this slice.

Model edits wait until every mounted editor finishes marked text. Deferred
edits are bounded and cancellable; dictation receipts are written only after
insertion succeeds. Sends and draft moves remain blocked until composition finishes.
Persistence snapshots ordered runs only at the coalesced save or an explicit
flush. The earlier draft text remains a readable rollback fallback. Legacy
strip pastes migrate after the body in strip order. v2 recall restores chips;
v1 recall expands their text.

Composer sizing uses native layout and a capped height. Typing reads only the
changed span and a bounded control prefix; it does not compare the whole draft
or call boundingRect for every edit.

Conversation headers use the same canonical message-text extraction as user
bubbles. Attachment prompts show their caption, first pasted line or known file
name in fallback titles and sidebar previews. Headers prepare raw Codex previews
off the main actor and retain Claude's already-prepared gateway summaries. The
version 4 header cache contains prepared previews and never decodes them again;
older cache projections are discarded because their provenance is ambiguous.

Checkpoints retain the earlier image/file keys so rollback builds can decode them.
Pasted text and host references also have readable text fallbacks for those builds;
the current decoder restores the typed body and attachment order. Inline messages
also persist ordered runs and put expanded text in the old text key. Image bytes are
encoded once. Frozen checkpoints cover both directions against main `9db89687`.

Existing chats use their exact thread ID within that host. Each New Chat is an
unsent draft keyed `new-chat:<UUID>` in its target's store. New Chat keeps the
shown draft when it is empty and otherwise moves to a fresh key, so a long
dictation never blocks another prompt; changing the folder moves the shown
draft rather than starting another. A blank unsent draft is never stored: the
save deletes its record. Each draft keeps its edit time and its `NewChatSetup`
(folder, model, reasoning and Fast). The screen records it explicitly: when the
user picks a folder, model, reasoning or Fast, when a moved draft adopts its
settings, and while a blank draft follows the defaults. Opening a draft applies
its setup without writing it back, and a defaults change in Settings skips
screens showing a draft with content. One draft is held by at most one screen
per target: opening it in another window moves the first screen to a fresh
draft. The drawer lists unsent drafts above chats, newest first, from
`ComposerDraftStore.unsentDrafts`, a summary list the store refreshes off the
main actor after open and after a save touches a non-thread draft. Discard
hides the draft at once and deletes it after the drawer's undo window, so a
draft survives if the app dies first; it is refused while that target
dictates, and edits that arrive after the deletion are dropped rather than
saved again. `LaunchRestore` records the shown draft
like a conversation, and the primary window reopens it on launch. Once its
message is durably submitted, the draft follows the local conversation and
then its server thread and drops its setup. A send clears the composer at
once, and text typed afterwards stays in the draft even if selection changes
during the send. Until the transcript durably holds the message, draft saves
store it ahead of that later text, so a crash loses neither; a failed save
returns it to the composer in the same order.
Async question lifecycle is independent of the transcript window. The host's
`questions` module owns canonical per-slot facts and durable dismissal; the existing
conversation actor owns a revisioned replica and local submission receipts. A history
summary never proves that a question is pending. See [Async questions](async-questions.md)
for the wire contract, epoch fences, recovery and tests.

Question-card replies use the same dispatch path but leave the composer's
unfinished text and attachments intact.

The composer binds directly to the selected draft through its chat model.
`ChatComposerView` follows the iOS editor's focus: focused input keeps the
multiline editor above its actions, while unfocused input folds to one line
beside them, with settings still visible above. Narrow windows and accessibility text sizes
keep the one-line input above its action row so every control still fits. The
Mac retains its multiline layout when focus changes, avoiding transcript movement
during text selection and history navigation. `AnyLayout` preserves the editor's
identity through layout changes. The placeholder stays visible while the editor
is empty, including when focused, at its regular text size. Its leading inset
matches the model name above it in both layouts. The glass surface narrows when
space permits,
reserving room for every action including Stop so activity changes never widen it.
In the inline layout, Stop appears before the attachment control so its arrival
does not move an existing control into the Stop target. One
short, smooth animation follows focus and dictation state; Reduce Motion disables
the resize animation. Dictation uses the compact waveform, while attachments,
questions and notices retain their own rows.
Edits coalesce over two seconds without resetting the delay on every keystroke, with immediate
saves on selection, backgrounding, host retirement, and submission. Load and
save failures are visible and retryable; a failed load disables editing rather
than replacing unread data. Dictation and file imports capture their
originating draft and finish there after navigation.

Opted-in built-in dictation also uses the workspace-owned `SharedDictationLibrary`
for account-fenced personal settings, original microphone journaling and immutable
result publication. `docs/unified-dictation.md` owns that contract. Draft receipts
remove only the provider recovery copy, never the separate archival original.

Dictation is recorded to SpeechKit's `DictationRecordingStore` while it is
spoken, so a crash, force-quit or failed transcription leaves the audio on disk.
The recording writer owns write failures: a failed append stops saving later
audio, and finishing reports the saved prefix as an incomplete recording, which
stays recoverable.
Dictated text is saved together with a `DictationReceipt` for its recording in
the draft store's SwiftData save, and the recording is discarded only after that
save succeeds. Only a persisted receipt counts: a failed save leaves its receipt
pending in the context, and the recording stays recoverable. A saved recording
without a saved receipt appears as a tile before the
attachments in the composer's attachment strip; tapping it transcribes into the
current draft, and ✕ deletes the audio after confirmation. A recording whose
receipt exists is discarded instead of offered again, and the draft store skips
text whose receipt already exists, so recovered text is never inserted twice.
Receipts expire only by age, after the recordings' own 7-day retention.

### File attachments

Every attachment except pasted text is a file on the host. The Photos library
picker has no selection cap and accepts images and videos; camera photos,
pasted and dropped images and files shared from other apps join the same
bounded `FileAttachmentImports` queue as deferred imports. `PickedMedia`
imports a file representation, copying the Photos-owned URL before its callback
returns, and the temporary copy is removed after durable staging, so photo and
video bytes never need to be loaded into one `Data` value. Pasted and dropped
images keep their original bytes, preferring a pasteboard type agents read.
Staging passes every file through `AgentImageFiles`, which recognizes photo
formats agents cannot view by their content (HEIF and HEIC, TIFF, camera RAW)
and converts them to a full-resolution JPEG of the same name, so agents can
view, crop and convert every photo with their own tools. Other files, including
icons and other image assets, keep their exact bytes. The shared camera preserves
the capture output's original HEIC or JPEG file until staging.
Staging runs two files at a time beside four uploads, and each file joins the
draft at its selection position, not when its staging finishes.

`ChatComposerView`, backed by `ComposerPresentations.camera`, owns every in-app
camera presentation and attachment destination. Take Photo uses the current
composer draft. The unlocked `RemoteCoderCameraCaptureIntent` opens a New Chat
in the active host's home folder and requests that same presentation once the
draft is ready. An unavailable home folder or offline host does not prevent
attachment; uploads wait in the existing staging queue. `RemoteCoderCameraControl`
registers the intent with the system; the system selects the app or
`RemoteCoderCaptureExtension` for its launch surface.

The app and extension share `CameraCaptureView` and `CameraCaptureModel`.
Hardware capture interaction stays enabled even while busy or reviewing, so
those presses are consumed without relaunching the camera. Only the app has
Close; the system dismisses the extension. `CameraCaptureSession` owns its
serial AVFoundation executor, readiness, full-quality original writes and
device-derived lenses, flash, front/back switching and zoom controls. Supported
hardware enables responsive and fast capture, with at most two requests in flight.
The capture executor never decodes thumbnails or waits for PhotoKit.

`CameraCaptureModel` owns per-shot processing tasks on `CameraPhotoProcessing`:
160-pixel tray thumbnails and add-only saves of the original photo files. Save
failures are recorded on their shot and shown without blocking attachment.
Selection is bounded to 24 shots, so retained tray RGBA pixels use at most
2.5 MB. Review images decode at the cell size up to 512 pixels and release on
disappearance. Done and removal join the applicable processing tasks before
transferring or deleting files. Removed photos free their slot and temporary
folder. In-app Done transfers the ordered files to `FileAttachmentImports` and
removes the batch directory. Close attaches nothing. Camera-roll copies remain.
`AgentPhotoCapture` retains its separate headless contract and never saves to Photos.

`RemoteCoderCaptureExtension` owns confirmation and unlock handoff. Only its
Done writes the ordered `CameraCaptureBatch` manifest in `sessionContentURL`
before `openApplication(for:)`. Failed handoff retains confirmed files for retry;
unconfirmed sessions are discarded. `ChatRootView` routes the locked user
activity through `ExternalEventRouter` to a home-folder New Chat.
`LockedCameraCaptureImports` owns initial and added-session discovery, oldest-first
session transfer, one-hour expiry and invalidation. Its receiver is screen-owned
and cancelled on draft navigation or retirement; replacement joins the old
receiver and rejected admission rolls file moves back. No camera path sends a
message automatically.

A file picked from Files is first snapshotted into the host's
`RemoteCoder/hosts/<host UUID>/upload-staging/<attachment id>/` by
`UploadStaging` (a coordinated `forUploading` read, so iCloud items download and
folders arrive zipped), because the picker's security scope ends with its
callback while the upload may outlive the view or the process. While the copy
runs the composer shows "Preparing files…" and the send gate counts the file
from the staging ledger (`fileStagings`), because the draft does not hold it
yet. The draft then holds a `ComposerFileAttachment` — named as staged, so a
folder reads `<folder>.zip` — whose placement is `staged` until
`GatewayUploadClient` has streamed the copy into the gateway's resumable
`/uploads/<attachment id>` session and the stored digest matches; the placement
becomes `uploaded` with the host's absolute path,
and the staged copy is removed only once that placement is durably saved
(`ComposerDraftStore.flush()` reports success), since the copy is the only way
back from a persisted `staged` record. Progress and failure are runtime state
on the chat model (`fileUploads`), never persisted: a relaunch or a switch back
to the draft restarts every staged upload, and a failed one offers Retry.

Each attempt asks the gateway for the upload's offset and streams the rest of
the staged copy from there in one request, with a fresh `InputStream` per route
attempt and per URLSession body request; the digest is computed once per staged
copy. A lost connection, a busy or draining gateway or a restart makes the
upload wait without its slot and continue from the gateway's offset after a
jittered backoff, a network path change or the app becoming active. After six
backoffs in a row that confirm no new bytes, only a network change, the app
becoming active or Retry continues it. A relaunch continues
from the same offset because the session is keyed by the attachment id. On iOS,
adding files or tapping Retry also submits one `BGContinuedProcessingTask`
(`ContinuedUploadProcessing`) covering every host's uploads, so they keep
running with system-shown progress after the person leaves the app. When the
system or the person ends it, running uploads pause until the app is active.
URLSession's built-in resumable uploads and background sessions do not fit:
the IETF draft needs `104` interim responses, which hyper cannot send, and an
absolute resume URL that pins the upload to one route, while background
sessions run outside the app, where the pinned LAN trust and the relay's proxy
are unavailable. The gateway's offset protocol keeps every attempt on
`GatewayRoutes.send`, so an upload continues on whichever route works.
Sending is blocked while any file is unfinished, since the prompt names paths
the agent reads immediately. Dispatch serializes each inline paste at its
composed position as `<remotecoder_pasted_text_v2 id="UUID" bytes="N">`, a newline,
the exact UTF-8 payload and a closing tag. The byte length makes literal tags
inside a paste unambiguous. A typed run containing a reserved v1, v2 paste or
v2 literal start marker uses `<remotecoder_literal_text_v2 bytes="N">`, a
newline, its exact UTF-8 text and `</remotecoder_literal_text_v2>` preceded by
a newline. Literal payloads are never parsed as chips, even when they contain
complete valid tags. Other typed runs stay byte-identical. Adjacent typed runs
coalesce only at document snapshot boundaries. `AttachedFilesPromptBlock` follows with absolute
host paths as plain text, the only form a composer attachment reaches the
provider in. The earlier v1 trailing JSON block remains readable for history.

`ChatMessage.attachments` holds immutable text, image and file presentations.
The composer and sent bubbles share compact tile summaries and display-sized
thumbnails prepared by `ImagePreparation`. An image file's composer thumbnail
comes from its staged copy and, once that is gone, from the host through
`HostImagePreviews`, as sent image files always do. Attachment-only messages use
ordinary bubbles. Text opens a selectable reader with Copy; inline images from
history open a full preview, and host paths use `HostFileOpener`.

Both providers' canonical user inputs reconstruct the tiles. Projection memoizes
summaries per user item, independently of streaming assistant updates. The exact
pasted-text envelope restores v1 tiles or v2 inline chips; older unmarked fenced pastes remain
ordinary text. The file block restores paths without inventing byte counts or
digests. Codex image inputs retain inline data or local host paths; Claude's user-item
adapter preserves base64 image blocks in both live and paged history. A provider
image ID without accessible bytes remains explicitly unavailable.
`InlineMessageContent` holds immutable prepared labels and expanded copy text.
Its equality is constant-cost. Sent inline text uses the same native attachment
provider as the composer, with full layout cached by width and typography for a
stable row height. Its typed runs use the shared inline Markdown parser on
`RenderedMessageStore`'s serial actor; the bubble observes only its own prepared
render entry. Chip payloads stay literal, and native selection expands them as
plain text. The worker also prepares expanded display text for menu Copy and
Select Text; Copy as Markdown and Share retain the expanded source.
The gateway's one `prompt_summary` removes only validated
v1/v2 envelopes before history truncation and APNs subtitle formatting. It
expands v2 literal blocks as text and replaces real pastes with `[Pasted text]`.
v2 chip-containing messages use one native selectable text layout with prepared
emphasis, code and links. Ordinary and v1 messages keep their Markdown blocks.
Removing a composer tile, or deleting an unsent draft once its undo window
ends, cancels the upload, deletes the staged copy and discards the bytes the
gateway already received; an already uploaded file stays on the host until the
gateway's 30-day sweep.

### Opening remote files

Explicit Markdown file links, attachment chips, and images, videos and file
links tapped inside HTML visuals use `HostFileOpener` (`UI/Files/`) with the
originating host, conversation and working directory captured at the
tap. It downloads before presenting a single reader
or native Quick Look controller. New taps and conversation changes cancel and
fence pending work. A delayed cancellable status surface shares the completion
banner's placement; rendering a link never downloads its target.

`HostServices.files` owns one `HostFileStore` per physical host, shared
across windows. `GatewayFileDownloadClient` streams the authenticated
`POST /files/download` response to disk through `GatewayRoutes`; this path does
not use an agent turn or Codex filesystem RPC. Immutable file leases keep the
original bytes alive for preview, sharing and export. The persisted cache
revalidates opens and offers an explicitly dated saved copy after a failed
request; it is not an archive of every path ever mentioned in a conversation.

The Markdown reader uses the shared off-main `MarkdownRendering` engine and
accessible `MarkdownBlockView` headings. HTML uses a shared interactive
SwiftUI WebKit viewer with a stable host origin, off-main leased resource reads,
JavaScript, local supporting files and normal network, form and frame behavior.
The viewer uses persistent browser storage, native dialogs, selection, zoom and
Find. Explicit non-HTML file links return to the originating remote directory
through the same opener. Other supported files use Quick Look;
unsupported files retain Save to Files and Share. The complete reference,
lifetime, preview and failure contract is in [Remote files](remote-files.md).

### Inline HTML visuals

The shared agent-tool registry exposes `publish_visual` to Codex through
`dynamicTools` on new threads and to Claude through MCP discovery. The host
publisher validates an HTML source of at most 2 MiB without host-file references and stores
an immutable read-only document under its SHA-256 digest. Outbound projection
adds `rcVisual: {digest, title}` to a successful canonical tool item for both
providers. `ConversationProjection` displays it as a `publishedVisual` row;
publication needs no model-authored embed. A completed assistant item with a
valid standalone embed in the same loaded turn claims placement instead.
The embed remains available for later reuse through `MarkdownRendering`.

`ChatWorkspaceModel.htmlVisuals` owns the renderer and shared document cache.
`HostServices.htmlVisualDocuments` is a per-physical-host actor using
`HostFileAccess.openVisual`. The existing file download endpoint resolves the
opaque digest and enforces its fixed 2 MiB cap before any body or unchanged
response; the client never constructs the gateway's storage path.
`HTMLVisualDocumentCache` verifies UTF-8 and SHA-256
on its actor, atomically retains a read-only copy and owns one bounded
persistent cache across hosts. Verified copies reopen offline; the renderer
receives only their HTML string.

`HTMLVisualRenderer` owns app-wide live-page admission, encoded layout snapshots
and memory-only height lookups. `HTMLVisualPresentationCache` owns bounded,
coalesced persistence on its actor; startup loading never gates the transcript.
`HTMLVisualEnvironment` prepares the shared theme once per relevant change.
`HTMLVisualInline` consumes existing transcript visibility and
scene state; focused controls, active pointers and expansion pin through
`TranscriptRowPresentation`. A live page runs inline JavaScript inside a
nonpersistent, storage-free WebKit sandbox with network access and no
host-file resources. Document prefetch creates
no WebPage. Energy conservation limits automatic pages to one, explicit
interaction stays within the hard three-page cap, and capture pauses while
scrolling or streaming. Intrinsic height belongs to each live occurrence,
including shrinkage, and
Mac logical row estimates reuse cached visual height. The complete publishing,
CSS theme, sandbox, offline, admission and eviction contract is in
[HTML visuals](html-visuals.md).

## History and live state

`ConversationSession` owns one conversation's canonical item records, unresolved
local submissions, page coverage, activity and publication revision. Its
`ConversationState` transitions are synchronous; no state mutation spans an
`await`. The host's `ConversationSessions` registry binds a draft to its server
thread without changing the actor or local conversation identity. Eviction targets
sixteen retained owners and protects owners with live observers or pending
submissions. Explicit presentation refreshes retention order; background lookups
of existing owners do not. Unobserved running conversations are eligible for eviction;
reopening restores their authoritative history and cached presentation. Weak
bindings preserve identity while in-flight operations still reference an evicted
owner. Selection, warming and explicit dispatch acquire sessions. Global activity,
content, replay, token usage and question attention update existing owners only;
they never acquire transcript sessions or refresh retention order. During an
asynchronous opening, live and replayed lifecycle events for an exact conversation
selected by a current screen may complete that selection's normal indexed session
admission. Selection, retirement, task cancellation and the delivering pump's
lifetime fence the admission; scene phase changes preserve a live delivery.
unselected lifecycle events retain the existing-owner path. Streamed deltas continue
direct actor ingestion without additional main-actor work.

That same registry publishes its retained Claude bindings, including externally
held weak owners, to `GatewayClient` as revisioned subscription intent. The
connection keeps one set of at most 64 IDs and one serialized update task.
Initialization, reconnect and reads settle the current subscription attempt.
A successful `conversation/subscriptions/set` acknowledges that exact set;
a rejection or timeout records an explicit failed state without disconnecting
or blocking history/replay. A changed valid intent or reconnect may retry;
reads and unchanged intent never retry a rejected set. Unknown-method codes
(`-32601`, or `-32600` from older dispatch decoders) disable scoped fanout
attempts for that connection until reconnect. Legacy content remains available
under the registered older-gateway compatibility path. Local overflow or
invalid IDs fail before sending and also leave reads available.

A rejected replacement does not replace the gateway's earlier set. The client
never claims the new thread subscribed; authoritative history and the existing
replay/prefix owner recover it. Subscription delivery changes no transcript
retention or prefix authority, and missing live text remains unknown until
history, an authoritative live start/checkpoint or canonical completion proves it.

Global busy state, drawer attention and aggregate Live Activities belong to
`TurnRegistry` and `ConversationActivity`. Question reads publish host-authoritative
counts without requiring transcript owners and merge records into existing owners.
Broker notifications and `ExternalEventRouter` retain completion delivery and
navigation ownership. Voice preparation acquires its exact conversation explicitly.
`HistoryWarmLedger` owns dirty and successful-read coverage for as many threads as
`ConversationHeaderRetention` retains, so warming every unsettled header never cycles it.
A read covers one exact header revision and the notifications seen since; a
completed warm also covers the HTML visual preparation context (width and
theme). Missing or evicted coverage requires an authoritative read. Monotonic observation
stamps prevent an earlier read from clearing later changes or eviction.
Opening without the retained actor also invalidates read coverage. A restored or
new owner accepts assistant, reasoning and plan deltas only after this owner's
live item start or observation checkpoint establishes a contiguous prefix.
Historical replay cannot establish that prefix: the gateway excludes deltas from
replay. Until a complete item arrives, the known prefix remains visible with the
turn still running.
Restarting the notification pump revokes prefix authority for incomplete items
on retained owners too, because the missed deltas are not replayable.
Claude openings explicitly request active-turn replay for lifecycle and completed
snapshots; a live-prefix checkpoint requires the separate gateway contract.

One ordered notification pump (`GatewayEventPump`) routes live and replay events into that owner.
Live turn events go from the off-main pump straight to an existing session, and only
turn and item starts and completions then hop to the main actor for busy state,
haptics and history bookkeeping. Each
target's `GatewayEventPump` owns a monotonic gateway notification cursor
(`ReplayProgress` pages the replay); pump restarts replay
after that sequence rather than using a phone-side disconnect timestamp, then
advance the cursor to the replay response's latest sequence after applying the
batch. The bounded `bufferingNewest(512)` stream may drop older stamped frames;
the gateway client finishes that stream after buffered values drain, keeps the
lowest dropped sequence as a replay floor and emits a `historyGap` connection
event, and the restarted pump reads the floor from the client and replays from
just before it.
`turn/start` returns only the turn id; the pump alone ends a turn, and speech of the
final reply belongs to a turn this model dispatched, never to a replayed or foreign one. History and
checkpoint reads merge facts by identity; an absent row in a bounded page does
not delete a local submission. A send is checkpointed before dispatch and keeps
its exact `clientUserMessageId` until a canonical `clientId` reconciles it.
Lost acknowledgements remain uncertain and never cause an automatic resend.
Completion is applied once per `(thread, turn)` identity; replayed completion
frames therefore cannot repeat the state transition or its side effects.

`ConversationProjection` derives messages and intervening action groups from
ordered item records, splitting after every user or assistant message and
every image or document the agent took in (an `imageView`, or each entry of a
tool call's `rcMedia` after its event). Canonical `contextCompaction` items also split
action groups and render as permanent transcript dividers: “Compacting context…”
with a visible, energy-aware spinner, then “Context compacted”. Their canonical
item identity and position survive completion, later messages, history paging
and checkpoint restores. Manual admission shows a provisional divider until its
canonical item arrives. Failure and unconfirmed status appear at that boundary;
Refresh remains available whenever manual compaction blocks sending, including
while its completed item awaits the turn outcome. A continuing turn resumes its
Thinking row below the completed divider. The composer has no compaction banner.
A successful compaction-only turn produces no no-reply outcome. There
are no independently mutable content boundaries. Expansion intent is owned by
`ConversationState` and follows canonical activity IDs across newly discovered
message boundaries; closing a section clears its own activity markers. Expanded
activity rows remain siblings, in the iOS scroll-target layout or the Mac native
document, rather than children reparented under a changing group ID. The session
keeps a per-turn
projection memo keyed by write stamps, so a streamed delta re-projects only its
own turn; window, order, membership and presentation changes discard the memo.
Concurrent projection returns immutable snapshots carrying owner identity and revision; MainActor accepts
only its selected owner and nondecreasing revisions. Complete UI snapshots may
coalesce, while transport gaps explicitly request history reconciliation.
The session paces publication. Live-only updates (streamed deltas and plan and
diff updates) publish at most once per
`ConversationSession.streamingPublicationInterval` (80 ms); the first after a
quiet interval publishes at once. Every other
change, including completion, failure, questions, sends and history merges,
publishes without waiting for that interval, and consecutive publications stay
at least 16 ms apart. Each publication costs the main actor about 6 ms of
SwiftUI transaction work on an iPad Pro, and publishing every delta ran at
about 22 publications a second. The interval caps that at about twelve, at the
cost of streamed text arriving in steps of up to 80 ms.
`RenderedMessageStore` has one serial rendering actor (32 messages per batch),
checks source text and streaming state before publishing, and retains reusable
entries within 2,000 renders/8 MiB of source text in addition to the presented
set. Each `ChatScreenModel` declares its loaded presentation window, including
messages awaiting mounting and incoming snapshots awaiting publication;
`ChatTargetModel` unites those windows across presenting screens. Budget
eviction skips that set, so warming cannot erase a mounted bubble or force
unchanged window messages to reparse. A presented message larger than the
reusable budget stays ready until its screen releases it; released entries
immediately become subject to eviction. Its highlighting LRU holds at most 64
entries and 1 MiB of source, and holds settled code only: an unclosed fence in
a streaming message renders as plain code until it closes or the message
settles.
A previously rendered message stays visible across deltas;
an assistant message without a render uses a blank line, never a raw-Markdown
fallback. Snapshot publication waits at most 50 ms for up to 32 missing
streaming-tail renders and then rechecks owner, thread and revision. The timeout
races a cancellable render-notification stream, not the rendering task itself,
so uncooperative rendering cannot extend the publication deadline.

Opening a conversation is a deliberate short transition, not a blank frame
followed by reflow. `RecentConversationCache` keeps the last published
presentation and composer settings of the eight most recent conversations:
presentations at publication and background warm-up, settings when a
conversation is left, and each conversation's agents model with its last list,
so a known subagents pill is present in the switch's first frame. An uncached
agents model has no summary until its first read. Each model coalesces selection,
inspector, sheet and warmer reads into one cancellable RPC, reuses successful
results within its freshness window (`RemoteCoder/AGENTS.md`), and refreshes
explicitly after actions or pull-to-refresh.
The freshness window only controls reads and never changes UI state on elapsed
time. Coalesced callers share one RPC and its capacity recovery within the
original request deadline, regardless of which surface requested it first.
The automatic probe waits until the tail finishes loading; opening details can
read immediately. The last departing caller cancels the shared RPC. Failed
reads preserve earlier agents with their error; unread lists
never become a current No Agents result. Selection requests only newly added
question scopes. A newly bound session without ready question coverage requests
its exact thread, including when an earlier attention read preceded transcript
ownership. Sessions with ready replicas need no binding read; invalidations and
reconnect retain full refresh.
A switch shows that presentation in the same main-actor tick as the identity
change, but only when its latest eight messages already have renders, so no
placeholder bubble can grow afterwards; otherwise the opening publication waits
at most 150 ms for those renders, with the same urgent queue reordering and
cancellable deadline as the streaming tail. The session's authoritative
snapshot and settings restore then replace the seed; an empty snapshot does not.
Memory pressure keeps only the visible conversation's entry. iOS initially mounts
a content-budgeted tail that never extends past its latest turn. Its boundary is
fixed at the first render, so a send during the delay appends to it. The mounted
window runs from one stable row ID to the end. Mac admits native hosts around
the viewport while retaining bounded logical geometry for the loaded source.

On iOS, earlier rows mount in idle batches of 25 turns
(`HistoryEdgeReader.turnBatch`), capped at 80 rows or 160,000 bytes plus a per-row cost.
The runway becomes short when the prefix above the first visible row has fewer
than 12 turns, 80,000 bytes and 40 rows, or when it spans fewer than two viewports.
The first batch waits 350 ms;
slices contain at most 16 rows, two turns or 8,000 bytes, a frame apart. Any user scroll
or animation pauses mounting. A pending older page waits until the loaded
backlog fills a batch unless the reader is within two viewports. Following
mounts at most the latest batch and trims after growth to one and a half batches;
at scroll rest, reading also trims an unused prefix after it exceeds that budget.
It retains a full batch above the first visible row and restores the existing
identity-based reading target. A pending page, restoration, or unavailable
identity alignment leaves the prefix intact. Trimming also requires measured
geometry leaving at least two and a half viewports above the reader; missing
geometry or a shorter retained batch leaves the prefix intact. This margin and
the row budgets prevent repeated trim/remount cycles.

Mac receives the complete loaded logical source, bounded by `HistoryWindow`
(2,000 entries/16 MiB, subject to page-granularity retention). Never-measured
rows have explicit bounded estimates; previously measured rows retain their
last height. Only viewport, overscan and active-owner rows acquire SwiftUI hosts.
A fast scroll or a find command can reach any loaded row without waiting for an
incrementally revealed prefix. Idle work stops after preparing nearby rows;
it does not mount or render the full loaded history.

Both platforms prepare message renders before exposing their rows. iOS keeps
its fractional reading target and rendered reveal slices. Mac uses native
visible-point preservation as measurements correct estimated geometry. A cold
jump can show unhosted space until its desired render/measurement is available;
an estimate is never emitted as visible message content. Older pages keep the
stable older-edge identity. A reader inside the runway may prefetch one batch
while the history window is at most half full (`HistoryWindow.hasRoomToPrefetch`);
after that only a visible edge pages. Speculative pages cannot evict the latest
history. Native host admission itself never fetches history.

Only user-owned geometry movement leaves following. Tracking without displacement
keeps it; layout changes do not change follow mode. No single automatic update
mounts the whole transcript. An explicit row request prioritizes its own target
and waits for its current measurement before positioning.
The transcript owns viewport and bottom-bar heights. Transcript identities
crossfade over 0.2 seconds on iOS, including under Reduce Motion; Mac switches
replace content instantly. Send requests animate; find and reveal are instant.

Each retained `ConversationSession` owns its main-actor reading position and
follow mode. The recent presentation carries a weak reference to the session,
so a cached switch initializes its first frame synchronously without extending
session retention. Each screen attaches its own weak scroll owner under its
stable surface scope. A switch or detach captures only that screen. The latest
capture writes the session's one persisted position; another screen's live
viewport remains unchanged. Owners detach with their surfaces and are bounded
by the target's eight presenting screens. Evicting the session releases its position. Mac restores the
canonical row and exact in-row offset through its native index, prioritizing
that row until its current measurement is committed. A bookmark carries native
column, scale and text-layout identity; reconstruction after reflow preserves
its row fraction, and an obsolete offset cannot escape the saved row. iOS retains
its mounted boundary and row-relative reading point through its existing scroll
owner. Empty return placeholders construct no scroll owners: first content
mounts with the resolved session state. A draft's existing content keeps its
live owners when it gains a session. iOS viewport ticks only update geometry;
bookmark capture occurs at switch, detach and idle boundaries through
`TranscriptReadingCapture`, delegated by the single visibility owner. Its frame
index is pruned with mounted row membership.

Each session also owns `TranscriptRowPresentations`: code expansion, Mermaid
source, activity detail and question presentation under canonical row identities.
Entries are acquired lazily by rendered rows and retained only within the
prepared history/live row membership. Projection prepares that membership off
the main actor, including collapsed activity rows; unchanged membership reuses
its identity, so publication prunes flags only when rows enter or leave the source.
The session's projection publication retains membership independently of its
revision-fenced per-turn memo. It seeds future preparations from published
membership and normalizes overlapping completions off the main actor. Its
monotonic publication revision rejects older results without republishing
membership. A cached switch binds these flags before measuring or restoring
the anchor, so an expanded block preserves the same line. Session eviction
releases the flags. Surface-private adapters own focus/confirmation/diagram pins
and their callbacks. Flag mutation evicts detached roots before notifying
Observation, while another window keeps its live viewport.

The workspace retains at most three detached Mac surfaces in
`TranscriptSurfaceRetention`, keyed by session position and screen scope.
An unchanged return takes the native container,
row hosts and stable follow, visibility, code-export and row-projection owners synchronously.
The native presentation retains its projection across detach, so unchanged source
items keep the revision identities used by cheap row-input equality.
It rebinds actions to the current view without replacing or measuring unchanged
roots. Detached surfaces cancel input, native lifecycle observation, timers,
display links and preparation, and release view callbacks. Source and render
publication invalidate their retained surface before applying changed values;
theme changes and memory pressure clear retention. Each surface keeps at most
96 hosts. Live rows, loading history, active compaction, questions,
image/diagram preparation and active interaction
remain outside this retention scope and rebuild from the saved session position.
Releasing the session position also releases its detached native surface.

The transcript view is keyed by `transcriptIdentity`, which changes only on
explicit switches (resume, fork, new chat) and never when a draft gains a
session id mid-turn; a switch publishes identity and items in one main-actor
tick. iOS stays eager, not a `LazyVStack`: SwiftUI lazy estimates previously
stranded tall transcripts in blank space. Mac owns estimates, exact measurements
and scroll correction in its native container. Each row uses its canonical ID:
`ForEach` on iOS and a `TranscriptLogicalRow` with a separately admitted
`TranscriptRowHost` on Mac, without a second inner identity. The bottom sentinel
retains its explicit ID. On iOS, `TranscriptLayout` shares measurements between
sizing and placement, retaining at most two proposed widths. `updateCache`
clears its measurements when the layout or any subview changes, including
streaming renders, folding, image loading and zoom. On Mac,
`TranscriptRowInputs` gates native root replacement, including fork availability,
history-edge status and queued-message Send Now availability. The row factory
runs only on admission or changed inputs/environment; retained roots hold concrete
row content rather than a builder capturing a historical transcript snapshot.
Each root contains `TranscriptRowLayout` with two cached widths. The native
container places admitted rows from cached logical geometry. `TranscriptRowProjection`
memoizes the flat rows for the current items and rejects duplicate identities
with a diagnostic while retaining the last valid projection.
On the Mac, `TranscriptViewport` sizes from the parent's proposal and supplies
no explicit alignment, so window minimum-size queries do not measure rows.
`PreparedAssistantContent` observes only its `RenderedMessageStore` entry through
the store's subscript. Its equatable inputs contain identity and presentation
state, never the raw message, so raw-only snapshots do not rebuild prepared text.
Menus and previews read the render in their own view bodies; user bubbles retain
their raw-text fallback.
The store's dictionary is unobserved and the subscript creates an entry on first
read, so a render, insertion or eviction invalidates only that message's
bubbles; removing an entry clears it first so its reader re-reads. The screen
and drawer must not read the dictionary. The jump button's only UIKit reach is
`TranscriptScrollHalt`. Its Mac arm also forwards Page Up/Down and Home/End
from the composer to native scroll commands. The transcript cancels history
restoration and enters reading mode first; End restores following latest.

Code-block line counts and the highlighted 24-line preview are prepared
by the render worker. An open fence longer than 24 lines shows only its last 24
lines at a fixed height, with the earlier-line count in the footer, and only that
tail becomes attributed text. When the fence closes or the message finishes,
the block follows the loaded rule: blocks over 40 lines fold to the 24-line
preview. Copy, Save and drag always use the full plain code. Horizontal scrolling appears only for overflow,
chosen by `ViewThatFits` during layout using the scaled text's ideal width, with
system indicators on the Mac. Code blocks do not feed measured widths back into
view state. One transcript-owned `TranscriptCodeExportPresenter` captures the
code and suggested filename for Save As; its exporter and failure alert survive
block unmounting. The Mac file-preview sheet uses the same presentation modifier
for its rendered blocks. Code, table and Mermaid cards share the themed content
surface.

Blocks contain prepared attributed strings. A streamed revision re-splits only
from the start of the previous second-to-last block, when the text before the
previous last block is unchanged, and reuses every earlier block whose source
and kind did not change; any other edit splits the whole message. Lines are
classified by scanning their leading characters: the former per-line Swift
`Regex` literals made splitting a streamed message about forty times slower. Rendered blocks compare by render version rather than content, so
SwiftUI skips a reused block without comparing its attributed text. Only the final live block receives
optimistic inline delimiter closing; escapes, code spans and completed text keep
their literal semantics. Nested unordered list indentation is retained, and
consecutive `>` lines form one quote block of inline Markdown.
Streamed text appears as it arrives, and each new block fades in. Bubble growth
uses a scoped 0.25-second smooth animation keyed to the prepared render
revision, not the incoming text length, and the block fade rides the same
animation. Only a live prepared render or a render that continues a stream
(`RenderedMessage.extendsStream`) animates: loaded history never does, while a
terminal update's last blocks still do. The animation covers
geometry and block opacity only: `contentTransition(.identity)` keeps text from
cross-animating between revisions. An opacity transition needs no text or
transcript re-measurement. The former per-word fade did both on every clock
tick; replacing it cut main-thread time during a streamed turn by 13% and peak
memory by half on an iPad Pro. Reduce Motion bypasses the animation.
On Mac, the mutable last block of a streaming assistant render disables text
selection. A block restores selection when another block follows or the render
settles; a closed code fence is already selectable. Mermaid source enables
selection through its source view.
Tables keep their horizontal scroll owner outside the selection switch. On Mac,
one table subtree reports its content width and caps the scroll viewport to that
width, so a fitting table keeps its intrinsic card width and a wide table scrolls
within the available column. iOS retains its `ViewThatFits` candidates. The
mutable tail avoids rebuilding its TextKit selection layout on geometry-animation
frames, and completion enables selection within the existing row. Earlier blocks, settled
rows and message actions retain selection and copying through their existing owners.

The transcript owns scroll intent and follow policy. Saving a user message
publishes one stable row request with a top anchor, animated over 0.5 seconds
unless Reduce Motion is on. The eager iOS `TranscriptLayout` and native Mac
placement use the same `TranscriptLayout.tailPadding` calculation to add only
the missing latest-turn height before the bottom sentinel. A send
does not reparent existing bubbles or reset local state. Reserved tail space is
not message content and remains after completion. Row requests wait for mounting
and a positive viewport; their token is acknowledged once positioning executes.
Find uses centered, immediate positioning; an anchorless timeline request
minimally exposes its header. Newer explicit commands supersede older ones.
Only user-owned movement leaves follow, and only a user scroll ending at the
loaded latest history or an explicit latest action re-arms it. A programmatic
animation ending at the bottom does not re-arm follow.

On iOS the surface remains a SwiftUI `ScrollView`, one `scrollTargetLayout`,
`TranscriptPositionBinding`, and the existing size-change anchors: bottom while
following, top while reading, with a bottom initial offset. Position writebacks
remain unobserved. One 1% target-visibility callback drives visible media, first
content and history demand, rejecting unchanged membership before scanning rows.
Four geometry projections report height, runway, viewport and bottom state.
Reading rows supply frames in the content coordinate space and the last real
row supplies its bottom edge. The jump button appears only when that real edge
is more than half the unobscured viewport below its reading bottom. It stays
outside `GlassEffectContainer` and is inserted/removed, not hidden with opacity.
The jump first uses `TranscriptScrollHalt` to cancel the UIKit pan and call
`stopScrollingAndZooming()`, then requests the bottom sentinel by identity.
There are no UIKit offset writes or per-delta SwiftUI scroll corrections.

On Mac `AppKitTranscriptContainer` owns the native scroll/clip/document views,
logical row records and height cache, the bounded host dictionary, rendering
preparation and input/command execution. `ChatTranscriptView` keeps canonical
row construction, history demand and follow policy. The container's lifetime
is the exact host-plus-transcript identity, including a retained detached return.
Each logical row keeps current
inputs, a cached height and small presentation
state. Host eviction releases the graph but retains that record; source eviction
releases both. No host reuse crosses row identities.

The native document keeps a zero frame origin and extends its bounds upward
when history is prepended. The first surviving canonical reading row retains
its exact prior minY; older-edge/group headers and new prefix rows are placed
above it. Later unchanged row frames stay exact, without subtraction/addition
drift at the common row. Interior height changes move only subsequent rows;
last-row growth moves no preceding row. Clip/document conversions own command,
animation, paging, follow, runway and restoration coordinates. The document
and hosts disable autoresizing-mask constraint translation; the document also
disables automatic subview resizing.

Host selection uses one viewport of overscan, retaining existing hosts until
they are two viewports away. Visible rows, a command/animation target, a drawn
reading anchor and pinned presentation/interaction owners take precedence over
the ordinary 96-host capacity. A viewport containing more mandatory rows raises
that bound only enough to keep those rows. Admission prioritizes a command,
then visible rows, then preparation; at most four hosts enter per display frame,
and further admissions stop after 4 ms of synchronous creation/first-layout work.
One slow row can exceed that budget; it cannot be interrupted mid-layout.
A single owned task prepares at most 32 desired message renders. Replacement,
suspension and teardown cancel/fence the task; a new command preempts unrelated
preparation. Native bounds changes and admission work keep the display link
active until the final viewport has been reconciled.

`TranscriptRowPresentation` preserves settled code expansion, timeline detail
expansion, Mermaid source choice and question
expansion/confirmation across host eviction. It is bounded by the loaded logical
source and the message's current block indices. Context-menu previews have no
canonical presentation owner, so a four-block preview cannot prune full-message
choices. Code expansion defaults to false and resets when its prepared streaming
state changes, including across host eviction; streaming code remains non-expandable.
Answer text and question flow remain in `QuestionEditor`. An open
Mermaid viewer, question field/confirmation, native first responder and last
transcript pointer interaction retain their host. The latter is one owner until
the next pointer-down, preserving selection, menus and drags. Image/diagram
resources can reload from their existing caches; transient copy feedback need
not survive host eviction. Source eviction ends these presentation lifetimes.

Logical diff/index construction remains O(N) over the bounded source when its
geometry changes. Ordinary scrolling selects indexed ranges and visits only
the small host set. SwiftUI work belongs to admitted/changed rows; unchanged
roots and layouts are untouched by native frame bookkeeping.

The captured SwiftUI environment crosses into every row. `TranscriptHostEnvironment`
compares zoom, type size, appearance/contrast, display scale, direction/locale,
scene/energy/visibility, accessibility preferences, enabled state, image source
and the theme/export owner identities. A change refreshes admitted roots and
marks offscreen heights as estimates; width changes remeasure admitted rows at
the new centered readable-column width. The shared
observable theme store continues to update its row consumers directly. Rows
inherit the transcript's URL action through that environment: host file links
reach the file opener, and web links use the system action. The bottom bar, jump
button, composer, find and code-export
presenter stay outside row hosts, so unmounting a row cannot dismiss an export.

Row hosts have no tooltips: SwiftUI dynamic tooltip hit testing otherwise walks
hosted content on scroll. The native document binary-searches its index for an
ordinary pointer/cursor hit and enters only that row host. One weak hit result
is cached by point, host identity and root/layout/frame revision; scrolling and
input clear it. Repeated unchanged cursor queries do no graph traversal. Selection, normal
click/menu/drag hit testing and horizontal code/table scrolling stay enabled.
Vertical wheel hit tests stop at the native container/document, including the
first directional event. The local monitor holds the resolved event axis through
synchronous event dispatch even when `NSApplication.currentEvent` has not come
from its queue. Scroll, clip and document classes never override `scrollWheel`;
production leaves responsive scrolling enabled. The diagnostic logs compatibility
for all three. The harness can disable it only for synthetic input's synchronous path.

Each `TranscriptRowHost` reports its fixed-width natural size with a local root
revision. Replaced-root, wrong-width and removed-host callbacks cannot publish
into current geometry. Local Observation updates, image loading and folding
therefore commit height changes without a representable update. Only changed or
width-invalidated hosts receive explicit layout requests. The container retains
one height per logical row, coalesces commit requests, derives the ordered
placements and footer from measured or estimated heights, and validates the index before changing
the document. Invalid, duplicate or unordered placement logs/counts a rejection
and keeps the previous index; it does not crash. There is no SwiftUI document
layout export, synchronized mailbox or native origin anchor. Padding is applied
once in native coordinates: 12 points above the first row, a centered readable
column with 16-point horizontal margins, and the existing footer reservation.
Row heights, tail padding and the footer round upward to backing pixels before
placement. Stable row origins and document extents share that grid, so rebasing
the document above a prepended row cannot round its maximum below the final row.
Zero-width callbacks before a host's first width proposal are unmeasured state.

A content revision changes only for actual logical membership, row inputs,
footer or environment updates. Commands wait for their required logical revision
and their target's current host measurement within 0.5 points of the proposed
width. Measurement acceptance, placement and command readiness use that same
contract; a height cached from a previous host lifetime is insufficient. No unrelated row
must be measured before a find/reveal target can execute. Size callbacks during
a native commit schedule one subsequent pass. `PerfBuild` separates logical row
and mounted-host gauges, mount/unmount and estimate-correction counts, admission
budget deferrals, hit-cache results, and row update/layout/placement spans from
the native commit/index work.

Clip bounds mark a sample dirty; one view-associated display link samples at
most once per display frame and pauses when no work or animation remains. A
binary search and the intersecting rows provide visibility in O(log N + K).
A positive intersection is visible when it covers at least 1% of the smaller
of row height and viewport height; zero-height rows and the bottom sentinel are
excluded. Unhosted and not-yet-placed rows are excluded from emitted visibility.
Only changed membership and height/near-top/bottom/latest thresholds
reach SwiftUI. Exact bounds and the index remain unobserved. The final sample
is published before idle policy runs. `TranscriptVisibility` keeps one observable
visibility flag and one unobserved steady-growth snapshot per mounted row.
Growth animation samples that snapshot when the render revision changes. Its
membership set, scrolling flag and row registry are unobserved; consumers read
only their own row state. Membership changes update
only entering/leaving rows, phase changes update only visible rows, and logical
source eviction prunes the registry. The native index caches the cumulative turn/text budgets
before each row, so the first visible position yields runway policy without
scanning the mounted rows. Ordinary visibility changes do not demand history;
edge membership changes and runway-threshold crossings do.

iOS preserves a reading target by canonical row ID and fractional `UnitPoint`.
For an intersecting eligible row with top r and height h in a viewport with top
v and height H, capture a = (r - v) / (H - h). Reject a nearly zero denominator
and anchors outside ±2; the smallest absolute anchor wins. History edges and
regroupable timeline headers do not qualify. A reader without a valid target
gets no automatic slice. iOS reasserts the captured target after its page/reveal update.

Conversation switches retain the canonical row and captured row fraction. The
initial identity target uses that fraction within 0...1 to keep the saved row
visible. The existing reading-frame and viewport projections resolve the point
against the row's current height and viewport, then issue the identity alignment
once per restoration geometry that changed by more than a point. Requests run
synchronously inside scroll-geometry actions, so the asynchronous deadline cannot
stop a geometry that never settles; after eight requests restoration ends with
`geometryUnsettled` instead of issuing another. An evicted render's placeholder reports
no reading frame; resolution waits for its rendered entry and real row geometry.
The geometry gate observes the entry's presence flag; payload-only revisions
notify its content reader without invalidating the reading-frame modifier.
`TranscriptReadingCapture` owns the bounded readiness task and restore state.
Pending restoration does not overwrite the bookmark. A requested point ends
on arrival or a subsequent idle boundary. Authoritative source removal ends
with `sourceRemoved`; real geometry still unavailable after the shared one-second
mounting-readiness bound ends with `renderUnavailable`; an exhausted request
budget ends with `geometryUnsettled`; leaving the surface
before completion ends with `detached`. These outcomes cancel the automatic
identity intent, retain the known bookmark, record the result with the session
and log it once. They cause no further automatic restore requests. A later
explicit return retries; user input or an explicit command cancels the attempt
and resumes capture of the actual viewport. Unknown source membership is not
treated as removal.
The native container uses the same terminal outcomes and readiness bound. A
missing logical row or unavailable measured host clears its pending anchor,
keeps the session bookmark and suppresses capture until explicit navigation or
a later return. Successful native restoration still ends only after the saved
row's current measurement is committed; estimate correction remains native.
A retained surface matches a saved point only when canonical row, in-row
offset, viewport fraction and layout identity agree. A bookmark captured in
another window's width therefore resolves its saved fraction in the returning
surface's layout even when both windows captured the same absolute offset.
Restoration clamps the required alignment to ±2,
limiting amplification of geometry mismatch, and logs the clamp once per mounted
return. Exact in-row restoration is unavailable where |pH - uh| > 2|H - h|,
for captured row fraction u and viewport fraction p. The nearest supported
alignment restores the same row as close to its saved point
as identity scrolling permits. When H = h, every alignment has the same origin,
so restoration uses zero. This is a limit of the shared row/viewport anchor.
iOS continues to use identity positions without content-offset writes or
persisted document-coordinate anchors.

Mac captures a private visible-point anchor from the current committed index
and current native bounds immediately before replacing geometry. It chooses
an actually drawn, intersecting canonical reading row, or a drawn structural
row when only an edge or header is visible. It stores the point's offset d
within the row, fraction u within the row and fraction v within the viewport.
Same-width commits restore y = r + d - v * H, so text already above an appended
tail does not move when its row grows. Column-width, interface zoom, dynamic
text size, locale and layout-direction changes restore the relative point with
y = r + u * h - v * H. The native owner retains that reflow anchor until the
anchor row's current host measurement reaches the committed index; explicit
navigation or user input cancels it. Both constrain the destination to reachable
bounds. Equal-height and tall rows have no fractional-target singularity.
Prepends use the current drawn point rather than a page-request-time bookmark;
reflow preserves a relative point rather than a semantic text line. Below-reader changes
leave the origin unchanged. If no drawn row survives, the old document viewport
is constrained in the new geometry without inventing a replacement target.
An animation also preserves that document viewport through coordinate-origin
changes before its next explicit motion tick. Retained conversation bookmarks
store row identity and row-relative geometry; document coordinates are recomputed.

Explicit row-command alignment retains y = r + a * h - a * H on both platforms;
an anchorless request minimally exposes its row. A Mac command waits for its
required content revision; a missing target in that committed revision is
discarded. Newer commands and user input supersede pending commands/animations.
Explicit commands take precedence in a commit; following pins the document
endpoint until user-owned bounds displacement takes over. Motionless tracking
retains follow intent while content grows and when the gesture ends. The footer reservation is part of document
height, not a second content inset. Outer safe-area chrome already defines the
native viewport. The Mac jump threshold uses the indexed last real row rather
than reserved footer space.

Native live-scroll notifications and a window/bounds-filtered local event monitor
own input provenance. Trackpad phase and momentum are distinct from layout and
programmatic bounds changes; a phase-less wheel burst has one 120 ms idle timer.
That timer detects input rest only, never layout readiness. `TranscriptScrollHalt`
attaches directly to the container; composer and responder paging notify policy
once before moving. Page Up/Down/Home enter reading mode and End requests the
actual latest history. Jump/halt cancels the current animation and drains the
interrupted gesture's remaining momentum; a new physical gesture takes over
immediately. Gesture ownership survives pointer movement outside the transcript
until momentum terminates; a fresh gesture elsewhere is never drained. The first
nonzero observed wheel sample establishes horizontal or vertical direction for
that gesture, including outside the transcript or in another app window; later
direction changes retain its routing. A fresh gesture in any window clears the
previous gesture's ownership and drain state. The
transcript takes ownership only of phased vertical input it accepts inside,
including after an outside start or suspend/resume. Halt drains that owned
gesture's remaining finger and momentum events; unrelated vertical and
horizontal momentum remain with their native targets. The
resolved event axis survives gesture termination until dispatch completes, so
zero terminal samples keep their horizontal or vertical target. Initial zero
samples have no axis and pass through to the view under the pointer.
Animation completion never impersonates user input. Cursor gating,
input monitoring, timers and display-link work stop on disappearance, occlusion
or detach and recover on resume. The native scroll role and existing hosted
controls supply the minimal accessibility surface.

The Mac keeps the existing outer toolbar and safe-area chrome. There is no
AppKit all-edge equivalent of SwiftUI's `.scrollEdgeEffectStyle(.soft)` on this
container; exact soft-edge appearance remains a visual acceptance check rather
than a claimed API equivalence. Native acceptance also covers real 120 Hz wheel
input, prepend stationarity, streaming follow, resizing/zoom, selection and
horizontal overflow. A synthetic harness run with responsive scrolling disabled
is a separate conservative measurement, not real-input acceptance. The bench's
`app` delivery uses global event coordinates, verifies the exact NSEvent window
and dispatches through NSApplication so local monitors run. The harness records
its private CGEvent window field (51) and delivery mode in every report; exact
window resolution remains a required check. Direct `send`
delivery deliberately bypasses that boundary; `queue` remains available for
comparison.

`dev-tools/streaming-motion-report` records luma changes and normalized geometric
jump/snap-back candidates. Deliberate fades and growth can change many frames per
publication, so luma counts are descriptive rather than a publish-count gate.
Regression acceptance requires no unexplained opposite-direction layout jumps
in a stable transcript crop, plus visual checks of intentional motion and
keyboard/jump-button behavior.

Codex rollout JSONL is the canonical conversation record. The rebuildable
app-server projection persists item starts and completions for paginated
threads. `startedAtOrdinal` is the first source position, shared by lifecycle
notifications and item pages; completion never moves the item. Item lifecycle
versions preserve the latest snapshot inside a fork's immutable source prefix.
The item cursor contract is versioned; incompatible old cursors are rejected.
Older completed-only records retain their recorded ordinal as a deterministic
fallback, which does not establish their exact start order.

The iOS history service keeps one thread-wide `HistoryWindow` for both
providers. It reads fifty items per page through descending
`thread/items/list` without `turnId`, and turn metadata through
`thread/turns/list` with `itemsView: notLoaded` until every turn in the window
has its metadata. The window holds one older and one newer cursor: a page's
`nextCursor` continues past its last entry and its `backwardsCursor` reverses
from its first. An absent `startedAtOrdinal` (Claude) keeps page order. The
oldest turn may be partial and shows only the entries the window covers.
Steering, intermediate commentary and async questions appear only where their
paged entries place them. The transcript demands older history when the top
edge row becomes visible, or when a reader inside the runway has less than one
batch loaded above the mounted window and the window has room.
The transcript records a pending read only when `HistoryEdgeReader` actually
starts one; while the opening still owns the conversation the reader refuses,
and the transcript demands again when the screen's read target becomes
available rather than retrying on every update.
`HistoryEdgeReader` owns those reads and, after opening, a prefetch of up to
eight pages that stops once a batch of turns is loaded or the window is half
full. The tail read takes 50 items and later pages up to
100. At 2,000 entries or 16 MiB of measured page data,
eviction is away from the requested edge, so reading older evicts the newest
pages and exposes a newer edge. A page a merge changes is measured again before
eviction. A tail splice trims the pages below it, and a trimmed page keeps no
newer cursor, because its old cursor would skip the entries the tail replaced;
it leaves with the tail when eviction drops the tail. A tail read splices onto
the window only while the window reaches the tail, so passive refreshes never
move a reader who is far back. Sending or jumping to the latest from far back
resets the window to the latest history: the stored tail window first, then a
gateway tail read that bypasses the page cache. If that read fails, the error
shows as it does for opening; until one succeeds, even if backgrounding
cancelled it, the next send, jump or reconnect reads the tail again. A reader who scrolls to a newer edge keeps reading: the edge pages
newer and the transcript does not resume following. Each session numbers its
history reads when they start, and a tail or reset read applies only if it
started after the last one applied, so an older read that answers late cannot
replace newer coverage. A `historyCursorInvalid`
error resets the window to the tail, and `-32003` halves the next page. A
failed edge retries after reconnect; the start of the thread shows no row.
Overlapping responses update item content without duplicate presentation, and
a response whose cursor no longer matches the window is dropped. A single
oversized page may display but is not cached. Conversation state retains the
window's turns and its newest 32 known turns, plus active turns and local
submissions, and drops turns older than the window's first turn. While the
window is far back, turns outside it stay hidden until the reader returns to
the tail. Acknowledgement and completion change status without evicting a
recent turn that history has not covered yet. A live item's retention passes to
history only when the window holds an equally new or newer completion; an
unadopted response or older item version cannot release it. Live rows are
bounded per turn to 200 items/4 MiB for both providers, with an explicit reload
edge after eviction that re-reads the tail. Only a tail read clears that edge; a
directional page does not. Unique local records and unresolved
submissions are protected. Encoded bytes bound retained payload, not decoded
heap usage. A streamed delta that starts an item on a known turn re-checks
only that turn's live bound; a delta that only grows an item defers the byte
bound to the turn's next item or lifecycle event. Turn retention runs on
lifecycle events, new turns and merges. The
window stores its derived turns, so reading them during streaming costs
nothing.

`HistoryPageCache` owns a 16 MiB memory/64 MiB atomic disk LRU keyed by host,
thread revision, native method, direction and cursor. The native-v4 cache
stores original fetch times and rejects a cache replacement from a read started
before the retained entry. Coalesced callers retain their underlying operation's
start time. The order stamp stays with bounded memory/disk-index entries for this
process; it is not persisted across launches. Materialized tails use the earliest
read start in the snapshot and the same atomic publication fence. A separate
materialized tail window survives
paging away and opens a conversation from disk before the gateway answers. `ConversationCheckpointStore` owns
versioned transactional SQLite checkpoints under the host's `conversations-v1`
directory. The 64 MiB history target evicts only rebuildable records; local
records, attachments and protected recovery bytes have a separate 512 MiB
admission cap per host. Cold indexing decodes stored content off the
main actor to establish protection. Unreadable sources stay protected and move
to recovery before replacement. A session
coalesces notification-driven changes into one save per second, or per five
seconds while a turn is active. Sends, acknowledgements and turn completion
save at once; backgrounding and eviction flush. The retired
timeline cache is read once for migration and retained for rollback, never
written. Invalidation generations reject late writes from retired owners.

`HistoryReadScheduler` joins identical reads, prioritizes foreground work,
and permits two concurrent reads per host, at most one speculative. Pages
within one cursor chain remain sequential. Codex and Claude list reads overlap and report failures separately,
retaining cached sessions when a provider is unavailable. Warming covers at
most two candidates and is disabled on expensive/constrained paths, in Low
Power Mode, and during voice/foreground history work.

Conversation-list discovery keeps one continuation per provider. Recent reads
stop after twenty pages per provider with explicit incomplete coverage. Older
and search actions alternate providers and read one page of 200 rows at a time;
the browsed page outranks every unprotected, unpinned row, so its roots are
admitted before the cursor advances. Recent coverage leaves an unconsumed
provider at not-loaded if admission dropped eligible rows.

Search scans metadata pages using the same title, path and execution-target
label matcher as visible rows; native Codex's case-sensitive search does not
narrow that coverage. Search has its own continuation, and query changes cancel
or fence old results. Incremental refresh preserves in-progress browsing and its
admission priority; an explicit manual refresh (pull-to-refresh or Refresh) resets it. An
exhausted provider reopens when fresh partial coverage proves there is more,
and an exhausted query can restart after its admitted page is evicted. A visible nonempty query starts one discovery pass after
500 ms; further history remains an explicit action: the footer's one
Load Older Chats (Search More History while filtering) loads the next page on
every target that has one. List reads never resume
threads or fetch transcripts. Retained exact ancestry is inherited before
classification, and only unresolved retained headers rotate through retries.
Selection and screen membership update protected headers synchronously. Exact
missing-header recovery declines results superseded by another header admission
or mutation. Target retirement synchronously fences list/header/project reads
before asynchronous socket teardown, including drawer-owned tasks; the marks
writer has a separate owner.

ConversationList lives in Core/Conversations/History and is compiled from the
same source by both apps and Core tests. Each configured execution target owns
one exact-host ConversationHeaderStore, with one cached and one persisted
snapshot rather than a global host-key map. Target retirement closes store write
admission before its replacement can load the same file. Store construction does
no filesystem I/O; the actor creates its directory on save. Project resolution
reads only the current admitted window. A result generation advances on
directory-admission changes and on each new resolution, fencing late project
replies after readmission or a newer read. Removing a header passes through
that same admission owner. Superseded identities remain
unloaded until an ordinary resolution reads them again.

ConversationList captures each immutable header-save snapshot and its monotonic
revision before suspension. ConversationHeaderStore accepts newer revisions,
allows an identical retry, and rejects older or conflicting same-revision saves.
The loaded revision seeds the next caller sequence. Schema-3 files without that
additive key start at revision zero. Unchanged-header saves still skip disk I/O;
the in-memory accepted revision advances even when the file revision does not.

Reconnect/foreground reads check the header and re-read the tail, bypassing the
page cache when a stream gap dirtied the thread. A history read merges only
into the conversation session it read from, so a read that outlives an
invalidation cannot repopulate the replacement. JSON decoding, hashing, rendering and checkpoint encoding
run outside the state and UI actors. Activity comes from runtime observations,
never persisted history. The app applies each pushed
`daemon/activeTurns/changed` snapshot and reads the inventory once after every
connection (after replay), on foreground, when the drawer opens and after a
stream gap. One read runs at a time; a request made during it runs one more read
afterwards, so every request is answered by a read that started after it. It
keeps the highest
revision it has applied and drops older snapshots, so a slow read cannot undo
a newer push. A turn clears only after it has stayed missing across
observations at least one second apart; the first missing observation schedules
one confirming read. A read's observation time is when it was sent, so a read
already in flight cannot confirm early. A failed read keeps the last applied
snapshot and retries with backoff (2 s, doubling to 30 s). One scheduled read
exists at a time, and an earlier one replaces a later one. A background
disconnect cancels both reads, and no read starts while the app is backgrounded
unless Voice Mode keeps the socket. Losing the connection makes activity
unknown until the next read. Completed turns the app has already applied are
treated as absent from every snapshot. When the set of active
threads changes, only newly added threads get a question read; the rest follow
`conversation/questions/changed`. Required notifications
remain enabled.

Forking a bubble uses its canonical turn identity and never reads the full
thread or falls back to a different fork boundary. Browsing does not resume a
thread. Both providers page history with the same app-server v2
`thread/turns/list` and `thread/items/list`; the gateway answers them for
Claude threads with Codex's wire shape, cursor semantics and error codes. Token
usage arrives only as `thread/tokenUsage/updated`: Codex's app-server replays
it to the connection that sent `thread/resume`, right after the response, when
the resume includes turns or the thread has paginated history; the gateway
sends the same replay after every Claude `thread/resume`. There is no separate
history or usage read. The conversation checkpoint remembers the last usage with
its turn id and shows it on open only after a fresh gateway tail read shows that
turn as the thread's newest and no longer running. A tail served even partly
from the page cache, or the stored tail window, does not count, and replaces any
earlier verification when it applies. Any newer turn, including one from another
device, a running turn, or a window not yet verified by the gateway leaves usage
unknown until a resume or a turn reports it.

### Device tools

Both providers use the same registry. Codex declarations are persisted at
`thread/start`; older threads need a new conversation for `take_photo`. Claude
uses the runtime's MCP token and current active turn. Codex copies of a tool call
join one `(threadId, callId)` execution, with 60-second completed tombstones.

`DeviceTools` records the authenticated installation behind the latest
admitted `turn/start`, `turn/steer`, `claude/message`, queue add, or voice input
from the call owner. Internal delivery keeps it; operator input and an
explicitly empty `device/tools/declare` clear it. Every app connection declares after initialize:
the iPhone names supported tools and the Mac sends an empty list. Drivers are
bounded and disappear on gateway restart. An unknown driver differs from an
explicitly cleared driver; refused inputs leave the previous driver intact.

The gateway sends `device/tool/invoke` to the newest live connection that
supports that tool/version. The same connection answers `device/tool/result`.
Operations are bounded to one per installation and eight per gateway, with a
60-second deadline. Turn completion cancels pending work and sends
`device/tool/cancel`. A disconnect or deadline after invoke leaves capture
unknown. Late and foreign-connection results return `accepted:false`. Matched
invalid results fail the operation immediately. Accepted results remain
authoritative when the deadline, disconnect or turn end arrives afterwards.

Successful device content contains exactly one JPEG per capture, back then
front for both, and no text. Upload failures use `detail`; the gateway adds
camera, lens, dimensions and save information to the model result.
The model receives inline JPEGs; journals keep only image counts and encoded
byte sizes. A successful result can name uploaded originals. `UploadStore`
verifies the completed canonical path, size and SHA-256 and moves each original
without replacement to `~/Pictures/RemoteCoder/YYYY-MM-DD/HHMMSS-camera-lens.jpg`
using host local time and numeric collision suffixes. A failed save still returns
the image and its save failure. Only an accepted operation can name originals.

App-facing tool-call items replace inline MCP image `data`, tool-surface
screenshot `url`, and dynamic-tool `inputImage.imageUrl` with `""` plus a sibling
`rcImageOmitted: {mimeType, omittedBytes}`, where `omittedBytes` counts UTF-8 bytes
of the replaced encoded string; nested MCP JSON-text results follow the same
contract. An `imageView` item's `imageUrl` follows the same contract, and a
Codex `imageView`'s `savedPath`, the runtime's immutable snapshot of the image
the model received, is listed under `rcMedia` without a copy.
Compaction precedes page-size checks and replay storage; internal consumers
retain original items, and user attachments and non-data URLs stay unchanged.

### Tool media

The same compaction keeps what it removes from MCP image content,
dynamic-tool `inputImage` data URLs and an `imageView`'s `imageUrl` (the image
the model received, which the app shows instead of the file at the item's
path): `ToolMediaStore`
(`host-daemon-rs/src/storage/tool_media.rs`) writes each PNG, JPEG, GIF, WebP or
PDF of at most 32 MiB once as a read-only `~/.remote-coder/tool-media/<sha256>.<ext>`,
and the item gains `rcMedia: [{path, mimeType}]`. The Claude translator emits a
tool result's base64 images in those same item shapes, and a PDF `Read` as
`rcMedia` naming the original file. One frame is one admission, run on the
blocking pool under the store's single permit before the frame is forwarded:
existing copies only refresh their modification time, and new ones run retention once, evicting
the oldest copies outside the frame beyond 512 MiB or 4,096 files. Copies are
rebuildable, so a later read of the same history writes an evicted copy again.
A failed admission is logged and leaves the item's paths, which the app then
reports as missing files. A gateway without a state directory (tests) strips
media without keeping it.

Both WebSocket legs explicitly permit 32 MiB frames and assembled messages.
A decoded native page over 24 MiB returns request-local RPC error `-32003`,
leaving the socket usable; the phone reduces the count down to one item.
Native history responses reach the page decoder as wire bytes;
JSON parsing runs off the connection actor. Pending gateway history correlations
expire after two minutes if no response arrives. An upstream frame/message over 32 MiB produces `daemon/transportError`
(`messageTooLarge`, actual/limit bytes, nonretryable) before close 1009, bounded
by a two-second flush deadline. Unchanged oversized reads do not automatically
refetch on reconciliation; explicit user reads can retry. A single item larger
than the transport ceiling remains an explicit limitation.

Claude history is projected by `host-daemon-rs/src/providers/claude/history.rs`, shared
by list, read, and resume. Its activity date is the newest timestamped main
conversation message or tool result. Metadata writes, injected context, and
subagent records do not advance it. The gateway scans every candidate before
sorting and limiting results, with stable session-id ordering for tied dates.
Filesystem identity, size, modification time, and change time only invalidate
the in-memory header cache. Changed files are reread because Claude can rewrite
and truncate transcripts; incomplete trailing records wait for the next read.
Filesystem work runs on blocking workers outside the header-owner mutex.
Concurrent full scans coalesce into one worker with at most 64 waiting readers.
Single-header reads snapshot one cached entry, read independently, then merge
under an identity fence. A completed full scan merges under a generation fence
and preserves headers changed by concurrent reads. The changed-path set is
bounded by the header cache's 4,096-entry limit; overflow discards that scan's
cache changes while retaining its response. Four pagination workers have a
separate permit budget, retained by each blocking closure after caller
cancellation, so repeated cancelled searches cannot retain unbounded snapshots.

Warm Claude settings reads clone the runtime owner's latest snapshot under its
short state lock. They never wait for lifecycle mutations or send a control
request. Missing readback keeps model and effort unknown while the header and
current turn status remain readable.

For Claude, `host-daemon-rs/src/providers/claude/conversation_index.rs` durably records first positions,
actual gateway turn IDs and client IDs before advertising them. Provider text
and tool results remain in the CLI session file; only synthetic reasoning/plan
items carry presentation content in the index. Replayed user UUIDs and provider
message/block IDs join live output with file history. The projection
(`src/providers/claude/projection.rs`) regroups steering under the actual turn, attaches late
tool results by tool ID and orders indexed items by their first position. It
keeps byte spans rather than content and reads only a page's records, and one
32 MiB LRU keyed by session file revision, index revision and active turn keeps
paging from re-parsing the session.
Index appends are serialized per thread and synced before acknowledgement;
partial trailing writes are ignored by readers and repaired before append.
Legacy sessions without these observations retain their provider-file order.

Live notifications are authoritative while a turn runs. The gateway's
`daemon/activeTurns` reconciles local work with the app-server's exact active
inventory and returns `activeTurns` plus `coverage {codex, claude}`, under the notification
history's `epoch` and a `revision` that increases by one with every change; the gateway
seeds it from wall-clock milliseconds at its first publish, and a client compares
revisions only within one epoch. A gateway-owned turn carries `startedAtSequence`, and a Claude
replay for it starts there. The list is authoritative only for a provider whose
coverage is true. Agent grouping has separate `agentOwnersCoverage`:
`unavailable` merges positive incoming links over `TurnRegistry`'s last known
grouping, while `complete` replaces it, including an empty map. Relationships
alone never prove activity: `ConversationActivity` derives parent work from
current child execution coverage, retains unknown child activity as unknown,
and excludes idle children from parent activity while keeping their grouping.
Older gateways omit this field and retain
their complete-snapshot semantics. The app agent lists refresh when the
snapshot's children of a conversation change. The
gateway pushes each change as `daemon/activeTurns/changed` with the same
payload. Each read assembles current gateway and app-server state under short
critical sections, so a read after Stop sees the committed turn state. The
publisher refreshes external activity, ancestry and durable recovery coverage
in a separate owned task; no discovery or filesystem I/O holds the publication
lock. Discovery has a five-second bound, ownership two seconds and recovery
coverage one second. Ownership timeouts keep the previous observation without
refreshing its timestamp. A completed partial observation refreshes its positive
owner links even when other threads remain unresolved. `agentOwnersCoverage` is `complete` only while the latest
ownership observation succeeded, remains fresh and covers current active/working
threads; initial, failed, timed-out
and expired coverage is `unavailable`. An absent map entry proves roothood only
with complete coverage. Unverified or 30-second-old optional coverage is unknown.
The authenticated health summary exposes the corresponding `activeTurnCount` and
`activeTurnInventoryAvailable`; a zero count proves idleness only when that
availability flag is true.

Queued messages are Codex-only and natively owned. Codex's durable per-thread
queue (`thread/queue/*`) is the only queue and scheduler: it starts the oldest
message as its own turn when the running one completes or fails, and pauses
after an interrupt until `thread/queue/start`. The gateway governs the add, start
and delete mutations like other new work, refuses every queue method on a
`claude_` thread, and keeps a bounded durable lease of the messages it queued so
a successor turn is attributed by its `clientUserMessageId`, never by position,
and is reported through the same journal, APNs and Live Activity path while the
app is away. `thread/queue/changed` is stored like other thread notifications;
clients read `thread/queue/list` after it, on reconnect and after relaunch.
`host-daemon-rs/AGENTS.md` (*Gateway RPCs*) owns the contract.

Conversation agent inspection preserves collected native headers when optional
execution enrichment or external discovery is incomplete. The Agents owner
shares immutable launcher selections by exact host-default provider homes. Bounded
inventory tasks outlive waiting callers; inventory, alert classification and
mutations use independent host-shared budgets. Invalidation fences old work.
[`docs/conversation-agents.md`](conversation-agents.md) owns deadlines, limits,
cache policy and coverage semantics.

`daemon/activeTurns` also returns `externalActivity`, a separate inventory for sessions
outside the gateway, from the publisher's latest background refresh. Gateway
turn events still publish while that refresh is blocked. Claude ownership comes from `claude agents
--json`; transcript turn boundaries supplement missing or stale native status.
Standalone Codex ownership comes from writable rollout descriptors held by a
Codex process other than the managed app-server, paired with that process's
start time. An unfinished turn predating its owner cannot count as working.
Completed records, interrupt markers, and absent live owners clear activity;
file modification times and process existence alone never prove work.

External activity reduces bounded complete-record tails to the latest turn
boundary, caches unchanged file revisions, and reports unknown on incomplete
reads or missing boundaries. A long Codex turn can move its start outside the
8 MiB tail; it stays unknown until a boundary is visible again.
There is no inactivity timeout for a live owner. Provider coverage failures
preserve unknown state, while an available empty inventory clears it. This
observer never creates turn ids or participates in steering, notifications,
Live Activities, recovery, or restart decisions. Its one authority is
ownership: an entry whose `owner` is `client` names another process holding
the session, and the gateway refuses to resume that session until
`conversation/takeOver` has stopped it (`host-daemon-rs/AGENTS.md`).

Activity arrives over the model's gateway connection, so a hidden model learns
about it only while it stays connected: with a running turn, a voice call or an
open drawer. The history drawer shows a readable Working/Needs input/Checking
status badge. In the composer, managed work uses a spinner in the existing
44-point send control (static dots with Reduce Motion), so starting work does
not add a row or change the composer's height. Typing restores the send arrow
and labels the action as steering; detailed activity stays in the timeline.
On a running Codex turn, long-pressing that arrow offers Steer or Queue. Queue
adds the message to Codex's server-owned thread queue, which starts it as its
own turn after the running one completes or fails and pauses after an
interrupt; the app only mirrors that queue's membership for its own messages.
A known running turn adds a Stop control left of the voice, mic and send
controls, which never move; it sends `turn/interrupt` for that exact thread
and turn and waits for the turn's own completion rather than clearing it
locally. The gateway's Stop also ends the turn's running subagents or its
pending resume, and a Stop that cannot take effect everywhere fails visibly on
that conversation.
The composer retains the status badge and explanation when sending is blocked.
A session held open by another client, idle or working, replaces the text field
and its controls with one lock panel (`ComposerTakeOverPanel`): a dark
pane, like the recording bar, holding three accent dots that wave while the
other client works and breathe while it only holds the session, a few words
naming that state, and an accent lock where send sits.
Tapping anywhere on it confirms, then takes the session over; the lock opens
while the other process stops, and the field returns focused. Existing sessions with ownerless external work or unknown
provider coverage block fresh text, queued turns, and Voice Mode until their
status is available and idle. Exact managed turns still permit steering.
Native inventory reads run outside the client's serial request pump, so a slow
probe does not delay steering or interruption.

The iOS app persists bounded headers, transcripts, timelines, model metadata,
and voice-only history for fast reopening. Those caches improve presentation;
they never replace provider-owned history.
Quiet automatic history refreshes retain unchanged header arrays and do not
publish loading transitions. The header store compares against its last
persisted headers before encoding; refresh timestamps stay in memory until a
header write also persists them, so a relaunch can trigger an extra refresh.
The header window holds at most 1,024 root conversations. Delegated agent
threads never appear in the drawer, so the window admits one only while it is
protected: visible, live or asking a question. Launch restores the saved window
as saved, before protection is known, so an open child still reopens offline. Their spawn prompts once filled
the window and evicted older pins on every refresh. Previews keep at most 512
characters (`ConversationHeader.previewCharacterLimit`), which bounds every row
without a separate byte budget; search matches that prefix. Protected threads
have priority, followed by pins, the browsed page and recent rows, so neither a
refresh nor older discovery can evict a pin. The current page's priority
survives background pin recovery until a later discovery admits a new page.
`ConversationList` applies the policy; the store applies the same count bound
when it loads a file and during migration, which adopts only root conversations.
A discarded-coverage marker survives relaunch and clears only after a
successful complete recent read that fits.
Missing pins retain their known name and exact-address open action; the footer
mounts at most sixteen unloaded pin controls per target and states any remaining
count. Recovery reads at most thirty-two protected addresses per pass. Failed
reads or admissions back off from thirty seconds to ten minutes, bounded to
1,024 entries; an explicit manual refresh clears the delay.
On the Mac, an occluded window's drawer counts as closed in its
`TargetPresentation`, so optional history refresh pauses and the window's
return restarts the refresh loop; sockets, activity and attention remain live.
Hidden drawers retain their last projection without observing live sidebar inputs.
History refreshes replace fetched headers even when the server corrects an
activity date backward. Local changes made during a refresh take precedence
over that in-flight response. Newly recorded local chats carry a persisted
pending-history marker. It protects them from missing history pages for five
minutes or until a page returns them; local retries renew that grace while
confirmed chats remain unmarked. Expired markers receive no extra protection,
and explicit removal, or Codex hiding the thread elsewhere (`thread/archived`),
removes the row.
A cached row absent from an authoritative recent page cannot retain a date that
would place it inside that page; older cached
pages and ties at that provider's page boundary survive that absence. An exhausted
provider can prune missing ordinary roots; child-only partial coverage cannot.
Pins, protected addresses and newer local mutations remain retained. Codex pages explicitly
sort by updated activity. The disk cache is versioned and rebuilt when its
projection semantics change; old file-based Claude dates cannot survive there.
An explicitly disabled Claude provider lists no sessions. A failed history
read remains an error, preserving the last snapshot without reporting a
successful refresh of an empty provider.

## Lifecycle and recovery

`GatewayClient` owns one generation-fenced WebSocket liveness loop. It probes
immediately after initialization and foreground activation. The timing owner
admits at most one pending probe and no more than one probe every two seconds.
Network-path updates request that same probe: pending or recent probes coalesce
without replacing their identity, dispatch time, deadline or RTT estimate.
Repeated active-scene callbacks are idempotent; backgrounding suspends probes.

A default-route update never closes a socket. `GatewayRoutes` uses available
Wi-Fi/Ethernet interfaces as hints for trying LAN candidates, independent of
which interface carries the default route. The same path identity preserves
verified LAN state and failure backoff. A new identity clears both so LAN can be
retried immediately; availability alone does not identify a path. Losing the
local-interface hint removes future LAN candidates, but the current
socket remains authoritative for its own liveness. A LAN subnet can stay usable
while the default Internet route switches to cellular. The WebSocket integration does not report
an interface-specific path, so receive/pong errors own immediate teardown for
both LAN and configured sockets; otherwise the bounded liveness
probe decides. The connection pump owns reconnect and replay.

The normal receive grace is `min(15 s, max(8 s, 4 × smoothed RTT))`, with the first
eligible successful pong seeding RTT and later samples contributing one eighth.
Grace starts at the later of ping dispatch and completed receive progress, and
an absolute deadline at the last receive plus seventeen seconds prevents
cadence rounding from extending the cap. The eight-second floor covers the
measured 256 KiB frame at 393,216 bit/s (5.46 s serialization) plus the tested
0.6–2.5 s cellular RTT range. The RTT multiplier tolerates bursts. The bound
assumes scheduler availability, including the one-second wake loop.

RTT uses the send-call timestamp and the pong timestamp captured in the socket
callback before its actor hop. The actor checks scheduling continuity before
accepting a sample, so both pong-before-wake and wake-before-pong orderings
exclude a suspended probe. A scheduling gap over three seconds grants fresh
normal receive grace without replacing a pending probe. Background/foreground
transitions fence old callbacks and start a fresh estimate. Path updates do not
reset the estimate or grant receive grace.

Before a text message above 16 KiB, the same ordered gateway writer sends
`connection/largeFrame {bytes}`. That announcement replaces the normal grace
with an absolute deadline of `bytes / 8,000 + 4` seconds. Only the next completed
application message clears it; pongs, path hints, foregrounding and delayed
scheduler wakes neither shorten nor extend it. Probes still coalesce and RTT
samples still exclude suspension. A stalled announced frame expires even when
pongs keep arriving. The seventeen-second silent-link bound applies outside
announced transfers; the existing 32 MiB message budget bounds announced grace
at 4,198.304 seconds. Gateway write and request budgets remain independent.
Older apps ignore this notification through `ServerNotification.unknown` and
`GatewayNotificationRouting`, including shipped tags 3.33.0 and 3.35.0.

Progress means a completed `URLSessionWebSocketTask.receive()` message or a
successful pong callback outside an announced transfer. Partial-frame bytes
are opaque: the measured `countOfBytesReceived` remained zero while bytes
flowed through a capped local proxy. An unannounced unfragmented message that
blocks both callbacks longer than the adaptive grace can still reconnect.
The announced-frame allowance assumes at least 8,000 payload bytes/s; it does
not promise uninterrupted arbitrary 32 MiB transfers or extend the gateway's
sixty-second write deadline. These policies never restart a gateway or agent.

Planned runtime or gateway replacement is one Rust-owned recovery transaction:

1. fence new ingress;
2. inventory and persist exact active root/child turns;
3. suspend leaves before parents;
4. stop the verified daemon owner;
5. start the matched replacement under a generation-bound grant;
6. recover the original thread and turn ids;
7. reopen ingress only after recovery and health gates pass.

The transaction persists queued steering and inter-agent mail, retains rollback
state until gateway and Desktop checks commit, and records terminal recovery
status in `~/.remote-coder/codex-restart-recovery.json`. Shell and launchd code
submit the transaction; they do not reconstruct thread state themselves.

Retiring legacy Codex profiles uses this same transaction to capture each exact
active task tree, suspend leaves before parents and stop the verified source
daemon through official commands. Adoption transfers captured work into the
durable default recovery journal before registry removal commits. A tracked
default restart provides the generation-bound startup grant when transferred
work needs one; adoption never independently restarts the default runtime.
Installer snapshots protect destinations until that commit. Once committed,
adoption is forward-only: rollback restores the previous binary while keeping
adopted native and gateway state and the default recovery journal. Old app
windows addressed to an enrollment may fail against the previous binary.

Every gateway SIGTERM interrupts instead of draining. When no prepared handoff
exists and Codex work may be active, the gateway runs the same stopped
transaction in-process. The host gateway persists its active Claude runtimes
before terminating their process groups without a CLI interrupt, so background agents stay resumable. The replacement
resumes each one with `--resume` in the host-default Claude profile with its
recorded cwd, model and effort, using an idempotent plain-text notice.
`host-daemon-rs/AGENTS.md`, *Install, restart and recovery*, owns the details.

## Voice paths

RemoteCoder Voice Mode sends authenticated signaling/control metadata through
the gateway while WebRTC audio flows directly between the phone and OpenAI's
realtime service. A Codex voice call lets app-server own handoffs. A Claude
voice call uses an ephemeral host-default Codex realtime shadow thread for speech and binds
delegations to the warm Claude runtime; the gateway translates progress and
completion back to the realtime model.

The stable voice-session id identifies the logical call across media reconnects.
A legacy transport-loss notification can reconstruct bounded context on a new
media transport without creating another agent conversation. An explicit provider
closure is terminal: its reason is preserved, and the gateway fences automatic
reclaim even for older clients. A new explicit user start remains distinct.
Provider errors marked nonterminal remain diagnostic and do not retry speech.
Replacement waits for the predecessor's actual closure receipt, because the stop
RPC only admits its operation and a Codex conversation can reuse the same thread.

The iOS call lifecycle has explicit call and connection identities. Hang-up
enters `stopping` until cleanup completes; transcript tails remain recordable
but cannot reactivate the call. Replacement calls wait for that cleanup, and
callbacks from replaced connections are ignored. Startup belongs to the call
rather than the voice screen's SwiftUI task.

Each call owns its agent thread and working directory. Reconnect resumes that
thread without overriding execution settings and rebuilds bounded history
without reading the selected chat's identity. Composer and voice-header pickers
share one serialized conversation-settings path; acknowledged changes are merged
after asynchronous call preparation so a reconnect cannot restore stale values.
The voice-start response supplies the gateway's current model and effort.
The composer and voice header use `ConversationSettingsControls`: a native
Model menu, a Reasoning gauge button, and an icon-only Fast toggle. One solid
bolt is muted when off and uses the theme accent when on, sized alongside
the gauge in matching touch targets. Its on/off haptics use the shared rigid/soft
recipes and the native press treatment; state changes never swap or bounce the
glyph. Settings synchronize silently in the background, so ordinary updates
do not insert an indicator or change the composer height. The
gauge's needle and arc show the selected effort within that model's supported
range; Automatic shows A. After a user commits, the picker collapses before the
gauge sweeps to the new value with three light selection ticks. One view-owned
task cancels the delayed feedback on another interaction, model/selection
replacement, backgrounding or disappearance; restored settings do not tick.
Reduced motion applies the new value directly with one confirmation tick.
Its accessibility value retains the effort name. Unsupported
models disable the bolt and expose “Fast unavailable” to accessibility. The settings stay visible and reflow at narrow
widths and accessibility text sizes; Voice Mode stays bound to its call's thread
and provider, not the currently selected chat.

Settings → Chat → Codex models and Claude Code models store model visibility
separately for each provider through `ModelPickerPreferences` and `ModelVisibility`.
Existing Codex overrides keep their storage key and format. Claude families are
shown by default and visibility is saved by alias (`fable`, `opus`, `sonnet`, `haiku`).
The composer, voice picker, new-chat defaults and suggested shortcut models all
use the visible subset. Existing conversations and explicitly configured shortcuts
still resolve hidden models. New Claude chats use their preferred visible family,
then the first visible family; hiding all families leaves no default model.

Settings → Chat → Reasoning levels stores visible efforts separately for Codex
and Claude Code. `ModelPickerPreferences` owns it and `ReasoningEffortVisibility` intersects that preference with
the model's capabilities; Max and Ultra are hidden by default. The slider stops,
gauge range, new-chat default picker and Voice Mode shortcut options all use
that same intersection. A hidden selection moves to the nearest visible level
(lower on a tie), clamping both ends. Automatic stays available, and is the
only choice when every explicit level is hidden. Visibility changes update
loaded conversations through the existing settings queue; reopened conversations
are reconciled after their current settings read. This changes subsequent
settings/turns, without interrupting an already-running turn.

Reasoning opens one screen-level floating picker, never a native reasoning menu
or a slider inside the composer. `reasoningPickerOverlay()` belongs to the chat
and voice screen roots, above their safe-area insets. The neutral material track
expands and fades from the held touch position (the control center for a tap),
with a broad feathered backdrop fading independently. The transition applies
before screen positioning so its anchor belongs to the track's local bounds.
The backdrop extends beyond the composer without changing layout or keyboard
focus. Reduced motion uses opacity only; reduced transparency uses an opaque
backing. The model name and larger effort label remain above the track.

A tap leaves the picker open for a second-touch adjustment; holding permits
press-slide-release in one touch. Both paths preview Automatic plus the model's
supported efforts and commit once on release. A hold without movement leaves
the setting unchanged. Dragging vertically away cancels; a tap outside, Close,
or accessibility Escape dismisses a tap-opened picker. While held, the overlay
never takes the originating touch. A UIKit button owns primary activation and
one `UILongPressGestureRecognizer` owns the continuous hold. Its normal
`cancelsTouchesInView` behavior cancels button tracking only after recognition;
a short touch remains a button action. Do not attach a high-priority SwiftUI
hold sequence to the trigger: the physical-tap regression reproduced lost
button actions on iOS 27. UIKit forwards move/end/cancel directly, without a
second drag recognizer or a GestureState-reset race. Composer
focus taps use a transparent overlay above the glass with the current bounds of
buttons and the text field subtracted from its hit-testing shape. Layout anchors
keep those exclusions aligned through keyboard, attachment, and text-size changes.
Empty padding and gaps focus the input; control touches never enter that gesture
or summon the keyboard underneath a newly opened picker. The opened
picker uses a native Slider accessibility representation.
Conversation/model/remote-setting changes, viewport changes,
and leaving the foreground discard the transient session. No intermediate
preview reaches the settings binding or the gateway.
`just ios-ui-test RemoteCoderUITests/ReasoningPickerUITests` covers physical tap,
second-touch selection, close/outside dismissal, reopening, hold/release,
vertical cancellation, and keyboard preservation in the actual app.
Applying and failed settings are scoped to the conversation they
belong to, including when another chat or voice call is visible. Both pickers
restore the same remembered reasoning choice when changing models.

Manual picker operations are the only writers of new-chat preferences, shared
by Codex and Claude and by the composer and voice header. Settings offers
independent model and reasoning policies: last manually selected (the default)
or a fixed choice. Fixed policies retain later manual choices for switching back
to last-selected mode. New chats and App Default shortcuts resolve these same
policies; a hidden or unsupported default effort clamps to the visible range
without overwriting the preference. Likewise, a preferred Codex model that is
hidden in Settings or absent from the host's `model/list` resolves to the app's
initial model (`NewChatDefaults.initialCodexModelID`) when visible, then the
host's `isDefault` model, then the first visible one. Applying that resolved
default does not record it, so the stored preference stays unchanged. Fast mode retains the last manual Fast choice independently of model support.
Only supported models enable the tier; moving through Claude or another unsupported
model does not erase the choice. Opening a conversation or applying a shortcut's explicit configuration
never changes these preferences.

New Chat actions use the configured provider on the physical host default,
including after viewing a conversation from the other provider. They keep the
current folder when the destination is on the same host. Changing folders in
the workspace also starts a chat using that default; it never substitutes the
previous conversation's provider default.

The Codex catalog starts unknown while its cache is unread. The target owns
asynchronous restoration; a storage actor loads, decodes, prepares and persists
the list, and the main actor applies the result. An explicit provider choice
survives that wait. Cold Voice Mode preparation awaits the cache before model
validation, and retirement cancels and joins cache and refresh tasks.

Moving a new draft transfers its model identity and user choices. The destination
resolves that identity through its own host catalog; an unread list or
unoffered model clears the selection and blocks sending. The screen retains the
requested identity and lookup failure, explains discovery and unoffered-model
failures separately, and retries that model when discovery refreshes. Discovery capabilities,
including automatic Daybreak Blue, always come from that destination. A successful
refresh that removes an active conversation's model keeps its identity and current
reasoning choice through the unlisted representation, dropping advertised Blue.
Later discovery restores the listed capabilities.

Conversation restoration does not invoke picker actions or write temporary
provider defaults. It reads cached settings and metadata-only `thread/read`,
preferring the server's configured model and effort. Missing effort readback
retains a known saved or observed choice for the same model. The selection revision
and conversation load identity prevent a late read from replacing a newer edit.
Settings unavailable from both sources block dispatch with a retry action.
Live `thread/settings/updated` events update only their owning conversation;
their payload supplies model, effort and tier without rereading the metadata
document. Runtime settings are persisted as observed values separately from
acknowledged versioned metadata. Restoration uses those values without a remote
read; absent tier readback stays unknown. Reads started before an observation
cannot clear it. A later read reconciles it when the settings agree or its
acknowledged revision proves a newer preference than the observation's captured
baseline. Runtime tier readback never replaces the acknowledged Fast preference.
Observations carry local receipt time and no invented runtime server revision,
mutation identity or selection source. Historical replay never reinstates old settings. A pending explicit edit wins
over notifications until its latest response arrives. Per-session metadata
stores the requested Fast preference and whether it records an explicit selection
or an observed runtime setting. Loaded Codex thread reads expose the current tier
in `thread.extra.serviceTier`; this live snapshot takes precedence over metadata.
Both `fast` and `priority` mean Fast. Cached and unloaded threads have unknown
readback, shown by a question mark on the Fast control, and preserve the remote tier
on sends, reasoning changes and forks. Native cold resume restores the latest
thread-owned settings snapshot; native forks inherit the source's live or persisted
tier. An owned snapshot with no tier means standard routing, while a history with
no owned snapshot retains configured behavior. A drawer fork never borrows the
visible conversation's tier. A Claude fork's selection is the source's session
metadata, which the gateway copies to the fork and the app syncs before opening
it. A normal resume supplies live readback without making history browsing
resume a thread. Dispatch captures the selection revision
with its settings before suspension; readback cannot replace a newer or pending edit.
Voice startup, refresh and incoming calls apply readback under their conversation,
host and call ownership checks. Unrepresentable tiers such as `flex` remain
unknown to the Fast control and are omitted on unrelated edits; observed state
does not overwrite the remembered user preference. `conversation/settings/update` omits an
unknown tier, sends `fast` for On, and sends explicit null for Off. The gateway
preserves that omission/null distinction for both future and active settings. A newer explicit selection for an unloaded Claude thread
survives until its next turn, while legacy metadata cannot override a known
server model. Metadata synchronization merges against the current local state
after remote reads, and malformed remote data remains an error.

Claude `thread/read` and `thread/resume` expose that conversation's warm-runtime
settings when present. Otherwise they report the latest real assistant record's
model and effort, excluding sidechains and synthetic model records; unavailable
values remain null. The host's default model is only a new-thread fallback.
Reads use the latest settings snapshot without waiting for lifecycle exchanges.
Resume is a command: when a failed settings apply left readback unknown, it
recovers settings through the runtime's serialized `get_settings` before replying.

The voice screen separates the ongoing call from its transcript. Chat minimizes
the screen while the call continues; Transcript opens a sheet with the call's
available transcript and live speech. A compact status replaces the decorative
orb and reports microphone mute explicitly. Mute and End call continue through
LiveCommunicationKit actions; Speaker is a speakerphone toggle whose selected
state follows the actual audio route. Audio controls enable once connected, while
End call remains available during connection and reconnection. Failures expose
Try Again and speaker-route failures are shown in an alert.

`conversation/settings/update` changes execution settings independently of
media. Codex applies active settings through exact `turn/settings/update` and
future defaults through `thread/settings/update`; this requires the shared
`features.step_model_switching` setting. Claude updates its existing process
through runtime controls, checks readback, and reports `nextTurn` while a CLI
query still owns the old selection. The UI displays that pending boundary.
Neither provider can change a request that has already been sent to its model.
Fresh Codex threads already exist in memory before their first user message
materializes a rollout. Settings changes read live thread metadata, resume only
unloaded threads, and request turn history only for active threads.
An observed active-turn identity avoids history even before its first message
is persisted. If a hot update fails after future defaults were accepted, the
RPC acknowledges `nextTurn` with a warning so the app retains the new settings.

A Voice Mode call the user starts greets them once. When its first WebRTC
connection and the system audio session are both up, the app sends
`voice/session/connected`, and the gateway asks the realtime model through
`appendSpeech` for a short greeting. The
`VoiceSession` records it, so a repeated report or a media reconnect within
the call never greets again. Agent calls greet through `calls/connected`
instead. A failed greeting request is logged and never fails the call.

The same call replaces Codex's default realtime prompt with
`host-daemon-rs/prompts/voice-mode.md`, which follows OpenAI's GPT-Live
template: a brief, direct speaking style and a delegation policy. GPT Live
cannot call tools and often fails to delegate a goodbye, so the voice model ends
the call in words instead: it answers a goodbye or hang-up request with a short
reply whose last sentence is "Bye!". The gateway's `FarewellWatch`
(`host-daemon-rs/src/voice/farewell.rs`) arms when the voice's own transcript
ends that way in reply to the user, and ends the call like `end_voice_call` once
the voice has been quiet for 1.5 s (at most 10 s); any user speech cancels it. The
agent's `end_voice_call` remains for a hang-up it receives.

Joining Claude voice observes existing work through `appendSpeech`; only spoken
requests create handoffs. Handoffs bind to the provider's echo of the exact input
UUID, even if a previous turn finishes before that input is consumed. Synthetic
runtime context and CLI model-change echoes never become visible user input or
phantom active turns. Text and voice share the same progress instructions and
agent process; leaving voice stops the output route without interrupting work.
The shared conversation projection displays a native voice delegation's input
without its wire envelope. A transcript-tail flush becomes a “Voice conversation
ended” activity with transcript details. The original provider item remains in
the canonical checkpoint; malformed envelopes and local authored text stay intact.
Claude handoffs use escaped fields and pass native tail flushes through once
as querying synthetic CLI context. Live and replay omit that internal user
record, while the provider file and voice history retain the transcript.
Authored or ambiguous nested XML keeps its original text and client identity.

The Voice Mode shortcut configures the agent model, reasoning effort, and fast
mode using the app's model catalog and capabilities. Unconfigured values use
new-chat defaults; shortcut overrides never rewrite those defaults. Both active
launcher intents run in the main app with iOS 27 execution-target declarations.
Their request and configuration are stored together in one expiring record;
an enqueue notification delivers requests immediately when the app is active.

## Speech relay

Composer dictation (realtime and batch) and Speak replies use SpeechKit's own
provider protocols, but every request goes to the chat model's gateway rather
than to the provider. `GatewaySpeechAccess` binds a chat model to its host and
hands SpeechKit `SpeechProviderAccess.relay` at `<gateway>/speech/<provider>`
with that host's bearer. Each access asks the host's `GatewayRoutes` for its
preferred route and rewrites the origin to it; off the configured route it also
hands SpeechKit a `SpeechRelayTransport`, cached per route, that applies the
route's session configuration (the relay's proxy, LAN's no-cellular rule) and
checks the gateway's LAN pin. SpeechKit keeps the upstream path and query and
swaps only the origin, so the gateway sees exactly the provider request minus
the credential. Realtime Voice Mode is separate: its audio
flows over WebRTC through app-server and never touches this relay.

The gateway handler (`host-daemon-rs/src/voice/speech/relay.rs`) admits a request in a
fixed order: bearer authentication, provider, installation policy, operation
allowlist, drain state, capacity, then the provider credential. Each step has one
typed rejection, and every rejection the relay generates carries a
provider-independent marker. An HTTP rejection has an
`X-Speech-Relay-Rejection: <kind>` header, plus a
`{"remoteCoderSpeechError":{"kind","message"}}` body for people reading it. A
WebSocket request is admitted and its upstream connected before the client
upgrade, so admission and connect failures are marked HTTP responses too; only
revocation, drain and upstream failure close an upgraded socket, with code
`4000 + status` and reason `speech-relay-rejection:<kind>`. Provider HTTP
responses, including provider errors, and provider close frames pass through
verbatim, so SpeechKit's existing provider error handling still applies. The
response-header allowlist never forwards a provider header named like the marker.
A stop after an HTTP response has started streaming (revocation or drain
mid-body) cannot add a header; the client sees a truncated body.

| Kind | Status | Close after upgrade |
|---|---|---|
| `unauthorized` | 401 | 4401 on revocation |
| `authenticationUnavailable` | 503 | 4503 when the lease recheck cannot read credentials |
| `notPermitted` | 403 | — |
| `operationNotAllowed` | 404 | — |
| `capacity` | 429 | — |
| `draining` | 503 | 4503 |
| `credentialsUnavailable` | 500 | — |
| `requestTooLarge` | 413, HTTP only | — |
| `upstreamUnreachable` | 502 | — |
| `upstreamRejected` | 502, WebSocket connect only | — |
| `upstreamFailed` | 502 | 4502 |

Forwarding is allowlisted in both directions: a fixed set of request and response
headers, no redirects, and the client's `Authorization` plus any `key` or
`access_token` query pair dropped before the host's llm-router key is injected as a
sensitive header. Paths are matched on raw segments, so encoded separators and
dot segments never reach a provider. Responses stream as they arrive, which keeps
Gemini TTS's early playback. An installation grant is rechecked every five seconds
for the life of a relay; revocation closes it as `unauthorized`. Shutdown cancels
every relay as `draining` and waits at most three seconds, alongside the gateway
drain. Each relay writes one `speech` journal line (see
`docs/host-observability.md`).

Liveness bounds (pings, the body-idle timeout, limits) and the router vendor
mapping are in `host-daemon-rs/AGENTS.md`, *Speech relay*, and
`host-daemon-rs/README.md`, *Speech providers*.

SpeechKit maps the marker, in relay mode only and for every provider, to
`SpeechKitError.relayRejected(kind:)`. A realtime dictation reports it wrapped
in `RealtimeDictationError.connectionFailed` or `.streamFailed`.
`GatewaySpeechAccess.explain` names the host, provider and cause for that error,
bare or wrapped, and passes every other failure through.
A gateway without the relay answers an unmarked 404, which surfaces as SpeechKit's
ordinary HTTP or handshake error. Because the app has no keys, it cannot tell in
advance which providers a gateway has configured; the first use reports it.

## Sources of truth

- [Glossary](glossary.md) — vocabulary, each term's owning type and contract doc.
- [`host-daemon-rs/AGENTS.md`](../host-daemon-rs/AGENTS.md) — gateway topology,
  runtime package, restart and recovery, Claude provider, agent tools and voice
  gateway contracts; [`host-daemon-rs/README.md`](../host-daemon-rs/README.md)
  covers configuration, installation and local operation.
- [`RemoteCoder/AGENTS.md`](../RemoteCoder/AGENTS.md) and
  [`Core/AGENTS.md`](../Core/AGENTS.md) — iOS app and Core package rules.
- [`dev-tools/AGENTS.md`](../dev-tools/AGENTS.md) — RPC/debug CLI and live probe
  contract.
- [host-observability.md](host-observability.md) — logs and retrospective
  incident workflow.
- [conversation-agents.md](conversation-agents.md),
  [automations.md](automations.md),
  [provider-accounts.md](provider-accounts.md),
  [owned-operations.md](owned-operations.md) and
  [repository-model.md](repository-model.md) — the focused contracts they name.
- Codex protocol drift — compare exact fork revisions with
  `git -C <codex-source-checkout> diff <old> <new> -- codex-rs/app-server-protocol/`;
  generate a candidate schema with `CODEX_BIN=<candidate>/bin/codex just codex-schema`
  into ignored `build/codex-schema/<version>/`.
- [codex/compatibility.json](codex/compatibility.json) — exact approved release
  source/version/hash identity; private acceptance receipts remain outside Git.
- [private upgrade operations](https://github.com/emileberhard/RemoteCoder-deploy/blob/main/AGENTS.md)
  — executable matched-build and two-host deployment workflow.
- Dated plans, performance passes and validation records are history under
  the private operator archive; current code and these contracts win.

### Observing conversations opened in another client

Each target model owns a `ConversationObservationCoordinator` for its selected,
foreground Codex conversation. It subscribes to an already loaded runtime through
`thread/subscribe`; an unloaded conversation stays a stored-history view until a
runtime-start notification permits retry. Selection, backgrounding, disconnect,
and retirement cancel the capture and release its connection-scoped handle.
Execution subscriptions remain independent, and browsing never resumes a thread.

The gateway's real connection carries an ordered receipt identity and sequence.
The session buffers notifications while obtaining the acknowledgement and bounded
checkpoint pages, merges canonical item IDs, then replays only notifications newer
than that acknowledgement on the same connection. Persisted completed versions
win over partial text prefixes. Publication also checks the selected session and
viewport revision, so a slow capture cannot replace a newer selection or page.
Late successful subscribe responses retain owned cleanup with bounded retries.

The checkpoint's `liveItems` includes available ephemeral items and unfinished
text and establishes append authority for those exact items. Incomplete persisted
history rows preserve an already owned live prefix but do not establish one.
`historyUnavailable` exposes bounded ephemeral eviction through the existing
limited-history presentation. Legacy rollouts project incrementally without
rewriting their source or loading the entire transcript. Passive observation never
acquires approval or dynamic-tool request ownership.

## Ownership and persistence contracts

The current host lifecycle, draft admission, metadata transaction, request task ownership, per-conversation Claude coordination, credential migration and build/deployment contracts are maintained in [Operation ownership](owned-operations.md). The owning implementation and regression tests accompany that document.

`UndecodableStoreRecovery` owns set-aside for marks and realtime voice history.
It preserves the original bytes in numbered sibling files, retains the three
newest copies per store, and logs each oldest-copy eviction. Existing
`*.undecodable.json` copies count as the oldest. Preservation and retention
failures propagate to the store and are logged; they never report successful
recovery. Unexpected directories or symbolic links at archive paths are left
untouched.
Eviction starts only after the current source has been preserved, including
when a previous cleanup failure left more than three copies.

### Automatic conversation titles and done suggestions

The gateway owns one turn-review runtime in `gateway/conversation_review.rs`:
trigger, host slot, dialogue snapshot, Jev client and trace.
Plain title and done consumers select their questions independently. A completed
user turn with a readable goal may need a title; any completed turn, including
an agent-initiated turn, may be probably done. Pins, purposes and delegated
agents are excluded; threads must be idle and non-ephemeral. No applicable
question means no request.

The chronological dialogue reduces tools to short labels, preserves its bookends
and marks omitted middle context. One Jev request carries whichever questions
apply and retains the context-limit retry. Titles use the conversation's model
and warm prompt cache through the existing side-question path. Native snapshot
checks of that thread discard stale title results; activity elsewhere on the
account does not. Done verdicts do not reread
history or acquire conversation admission; newer activity makes the stored
suggestion expire. Each consumer handles malformed answers and apply failures
independently, with separate outcomes in the trace.

At done probability >= 0.90, the gateway writes `doneThrough` before title
writing; otherwise it clears it. Writes happen only on change and publish the
ordinary marks delta. Codex uses native turn `completedAt`; Claude uses the
transcript header's `lastTurnCompletedAt`, fenced to the judged turn. These are
the drawer's completion sources. Explicit Unsettle clears the suggestion and a
transaction rejects a positive verdict when `active(through)` covers the judged
completion. Read marks and unrelated account activity do not discard it. Jev never
settles, reads or pins a conversation. The README owns model policy; the
calibration records stay in the private operator archive.

The same runtime gives a new conversation an early title. Fifteen seconds after
its first `turn/started`, `conversation_review/early_title.rs` asks the writer
for a title mid-turn without a judge; a Claude side question answers while the
turn runs. The drawer row's context menu offers Regenerate Name, which calls
`conversation/title/regenerate` for an unpinned row. All three paths commit
through `Gateway::commit_title` and the per-thread rename owner, so a manual
rename wins and every write is traced.

### Conversation drawer order

The drawer has two views, chosen in its View Options popover and kept in
`ConversationDrawerPreferences` with the Unread Only filter and the folded
sections:

- **Priority** (the default): pinned rows under a Pinned header, by pinned name,
  then, under a Chats header, every other unsettled row ranked by
  `ConversationDrawerRank`, then the Settled shelf.
  The Chats header appears only below pinned or automation rows. Its tiers are, in
  order: needs you (an unseen question or a waiting turn), running, unread, then
  recent. Within a tier the newest activity comes first. Badges explain a
  row's position, so there are no further headers.
- **Projects**: pinned rows as above, then one section per project holding its
  unsettled rows, ordered by its newest row, each row ranked as in Priority,
  then the Settled shelf. A project with no unsettled rows has no section. A
  project is resolved on its
  host by `conversation/projects/resolve`: the normalized Git remote when the
  working directory has one, so the same repository on two Macs is one section
  labelled with each row's host; otherwise the repository root; otherwise the
  directory itself, which only matches on its own host. Sections fold, and a
  folded section shows whether it has unread rows and its most urgent activity
  (needs input, then working, then checking status), plus its row count on
  iOS. On iOS an unfolded
  section shows five rows and a "Show N more" item that lasts until the drawer
  closes; the Mac shows every row.

The Pinned section folds in both views, like a project section, and pinning a
chat unfolds it. Searching ignores every fold and offers no disclosure.

Activity is `latestActivityAt`: the later of the provider's `recencyAt` (the
creation time when absent) and the last finished turn. Tool calls, streamed
text, settings and renames do not change it. Interrupted and failed terminal
turns count as finished turns.

A done suggestion holds only while `latestActivityAt <= doneThrough`, with no
purpose or pin. New activity invalidates it without a marks write. Current
non-live Chats rows show a green outline settle checkmark labelled "Probably
done"; live rows and Settled-shelf rows do not. The suggestion is only that
badge: it never changes a row's rank, because a wrong suggestion that moved a
row down lost it among the others. The badge updates immediately.

Ranks are captured when the drawer opens and held until the next opening, so a
completing turn or a changing badge never moves a row under the finger. A
settlement mark change from any device or agent re-ranks its row at once. Pins
change order through snapshot assignment. New rows keep their first admitted
rank. Order
changes wait until scrolling and swipe actions are idle; content changes apply
immediately. The iOS drawer uses opaque content surfaces, with rising rows above
their neighbours during a smooth reorder. Reduce Motion disables that motion.
The Mac source list applies updates without animation. On macOS 27, removing a
row while its project section moves offscreen can leave an orphaned native table
row over the section that replaces it. The list clears the inherited animation
transaction; its bottom status bar keeps its own animation.
Date labels are projected once per snapshot using a day-keyed cache bounded to
2,048 entries.
Unread Only keeps rows unread at opening or since, plus the selected row, so a row read in the meantime does not vanish. A row captured as settled that turns unread shows in Chats at its captured rank; other settled rows stay hidden. The Mac sidebar is open whenever it is
visible and recaptures each time its window becomes key or returns from
occlusion. Searching (the Mac's
filter field) matches every whitespace-separated term against the title, folder
and, while shown, the host name, without reordering, and ignores folding and row
limits.

Rows whose purpose is `probe` are hidden unless live or selected. Unpinned
`automation` rows appear in their own collapsible Automations section after
Pinned and before Chats/projects, with an automation symbol that remains when
pinned. Pinned membership takes precedence and each row appears once.
Automation membership takes precedence over settlement; the stored settlement
and its actions remain intact. Search reveals matches through a folded section.
The Automations fold is a device preference and starts expanded; expanded, it
shows its first five rows plus the selected row until "Show N more" reveals the
rest for that drawer opening. Collapse and
Expand All include every collapsible section. Any purpose (`probe` or
`automation`) means a finished turn never counts as unread; within its section,
a row rises through the needs-you and running tiers, or when marked unread.
Purpose belongs to the marks document: service-created threads are marked,
while an exact existing target retains its purpose unless deliberately adopted
as a dedicated automation conversation.

Settling means "done for now". A settled row leaves Chats or its project for the
**Settled** shelf at the bottom of both views. It stays readable, searchable and
resumable. `ConversationMarks.isSettled` derives it with `now` = the layout's
capture time. A row is settled when it is not live (it needs you or runs a
turn), not pinned, not unread, and its settlement says so:

- `settled(through)`: settled while the row has a purpose or
  `latestActivityAt <= through`.
- `active(through)`: not settled while `latestActivityAt <= through`.
- Otherwise, and without a settlement: settled once `latestActivityAt` is at
  least three days (`ConversationSettlement.automaticAfter`) before `now`.

A new prompt or a finished turn from any origin moves `latestActivityAt` past
`through` and makes the row unread, so it un-settles a manual or automatic
settle without a write. A Claude wake's synthetic input is not a prompt: until
its turn finishes, only its request time can make the row need you.
Purpose rows keep a manual settle across their runs and rise only while live.

A row needs you while it has an unseen question or a waiting turn that no
settlement covers (`ConversationMarks.coversRequest`). A request's time is the
newest unseen question's ask time or, for a waiting external session, the
gateway's `waitingSince`, whichever is later. Settlement covers a request made
at or before `settled(through)`, or at least three days before `now` unless an
`active(through)` still holds the row. A covered request leaves the row to
ordinary settlement, so a parked Claude Code background job that `claude agents`
still lists as blocked months later moves to the shelf instead of staying on
top, while a question asked today in an old conversation still needs you. A
request without a time (a waiting session without `waitingSince`) needs you
until a manual `settled(through)` covers it while `latestActivityAt <= through`.
The needs-you tier, section and Quick Entry
markers, the Mac menu bar item and the Dock badge all follow this rule through
`ConversationDrawerRank`; the row itself still shows its question badge and
activity symbol. The Mac's `AttentionCenter` rechecks when the earliest
uncovered request becomes three days old and when the system clock changes.
Pins are the durable way to keep a quiet conversation in front. Nothing is
settled, and Settle is not offered, for a target whose acknowledged marks
document has `schemaVersion` below 2 or is unknown: an older gateway rejects a
batch with an unknown op, which would block every later mark change.

The shelf is folded by default; its fold is kept in
`ConversationDrawerPreferences` like the Pinned fold. Rows are ordered newest
first. Unfolded, it shows 10 rows and "Show N more", which reveals 25 more per
tap until the drawer closes (`ChatWindowModel.settledRowLimit`). The selected
row stays visible while the shelf is folded or beyond the limit. Search covers
settled rows and ignores the fold and the limit.

Settlement is captured with each rank, so activity-driven changes and the
three-day automatic settle wait for the next capture. Each rank also records
the row's settlement mark (`ConversationDrawerRank.SettlementMark`: unavailable,
automatic or the explicit `settled(through)`/`active(through)`) and this app's
`ConversationList.settlementEdits` count for the row. When either changes, the
projection replaces the row's captured rank and the row moves as soon as the
change arrives, once scrolling and swipes are idle, through snapshot assignment,
like a pin. On an explicitly settled row the mark also notes whether a pin
overrides it, so a settle anywhere that only clears the pin still moves the
row. Read state is not part of the mark: reading a row or marking it unread
keeps its captured rank, so a settle elsewhere that only clears a manual Mark as
Unread waits for the next capture. The mark changes with a
`conversation/marks/changed` delta from another device or agent and with the
marks read after reconnecting; a settle, unsettle or undo here also bumps the
count, which re-ranks the row even when the mark keeps its value. A drawer captured before its
gateway's marks were known re-ranks every row of that gateway once they
arrive.

Settle is unavailable for running rows. A waiting row or one with an unseen
question can be settled. Settling records `through` as the later of
`latestActivityAt` and the row's newest request time and marks the row read, so
the requests it showed stop needing you and a newer one needs you again
(`docs/async-questions.md`, *Attention*). The row menu offers Settle, or Unsettle on
a settled row. On iOS the trailing swipe settles or unsettles, and the
selection bar offers Settle N, or Unsettle N when every selected row is
settled. On the Mac, ⌫ does the same for the selection, the batch menu has
Settle N Chats and Unsettle N Chats, and a checkmark on a hovered row settles
it. Settle Conversation (⇧⌘S in the Mac's Conversation menu, and in the ⌘K
palette on both platforms) settles or unsettles the open conversation and
keeps it on screen. It uses the captured settlement only while the drawer or
sidebar is visible and live settlement otherwise, and it never settles a
delegated agent conversation. Settling records
`settle(through: latestActivityAt)`, which also marks the row read and unpins
it. A settle from the drawer or sidebar then shows a 5 s notice with Undo, which
records `unsettle(through)` and restores the prior pin and unread state
(`ConversationMarks.settling`). Settle Conversation offers no Undo: running it
again unsettles.

The app has no Archive. Codex's native `thread/archived` notification means
Codex hid the thread elsewhere, so the app drops its header like a deletion;
`thread/unarchived` refreshes the list.

A turn is unread when it finished after the conversation's last seen completion
and after the host's read baseline. A conversation's finished turn is seen when
the presented transcript itself carries that completion while it is on screen:
its host is visible, the app is active and the history panel does not cover the
transcript. The iPhone's overlay drawer must be closed; the Mac's sidebar can
stay open beside the transcript. The mark is the
transcript's own completion timestamp, never the drawer row's, so a stale or
not-yet-loaded transcript cannot mark a newer turn seen. Transcripts take it
from live `turn/completed`; Codex transcripts also from the native turns they
read, since `thread/read` and subscription headers carry no completion time, and
Claude transcripts from their headers. Claude's live value is the gateway's
receipt time, taken after the transcript's terminal record, so it can mark that
turn seen but, for the reason below, never becomes the row's timestamp. The
transcript checkpoint persists this value, so an offline reopen can still mark
the turn seen. Rows also offer Mark as Read and Mark as Unread, a selection mode
marks or settles many at once, and Mark All as Read moves the read baseline
to the time it was chosen, even when the change reaches the gateway later.

Pins, read state, purposes, settlement and done suggestions are conversation marks, owned by
each gateway in `conversation-marks.v3.json` beside its turn state and shared by
every device. `conversation/marks/read` returns the whole document;
`conversation/marks/update` applies up to 500 changes and returns a revisioned
delta, which the gateway also broadcasts as `conversation/marks/changed`. Both
carry `schemaVersion`; a missing value means 1. The
document's read baseline is set when it is first created, so existing history
starts read. Schema 3 imports v2 on first load, or v1 through the
settlement conversion when v2 is absent, leaving both older files untouched for
rollback. `doneThrough` is gateway-written and is not an update operation.
Each host's `ConversationList` keeps a
`ConversationMarksReplica` in `conversation-marks.v2.json` in its storage
directory: the last acknowledged document plus unsent changes (at most 2,000),
applied optimistically and sent in order once the host is reachable. Each
connection reads the whole document and sends pending changes. While a read
failed or changes stay unsent, the marks worker retries on its own (2 s
doubling to 30 s, at most eight attempts until the next connection's sync).
`quiesce()` cancels a scheduled retry. `suspendMarksSync()`, called when the
scene disconnects for the background, also stops the worker before its next
RPC, so no marks request reopens a socket the lifecycle closed; changes made
meanwhile stay pending until the next connection's sync resumes the worker. Until the
first successful read the read state is unknown and no row is unread. A file
that cannot be read leaves the replica unloaded until the next launch; one that
reads but does not decode is kept beside it through `UndecodableStoreRecovery`.
Without the versioned marks file, the first load
imports the `conversation-marks.json` written by builds before settlement and
never changes it, so a downgraded build still decodes its own pending changes.
Pins from the earlier per-host defaults key are replayed as pin changes on first
load and cleared once acknowledged. Startup reads prepend stored pending changes
to commands admitted during the read, preserving their order. Local saves wait
for that read and coalesce through one latest-state writer; `flushMarks() -> Bool`
retries a dirty revision and reports storage failure. One remote worker owns marks
reads and updates. `quiesce()` closes command admission, `drain()` joins admitted
acknowledgements, and `resume()` reopens admission after the drain.

`updatedAt` remains the provider's content-activity value for list discovery,
cache invalidation and page retention. `lastTurnCompletedAt` is separate optional
header metadata, persisted with the host's cached history. Codex completion dates
come from descending native `thread/turns/list` summaries through the existing
bounded history scheduler; no item hydration or thread resume is needed.
Completion reads bypass stale pages because `updatedAt` has only second precision.
Claude supplies the field in list/read/resume headers from root transcript terminal
stop reasons, interruption markers, or legacy turn-duration records. Child output,
metadata and file modification times are not completion evidence. Live
Codex `turn/completed` timestamps update the same cached value immediately;
Claude uses its transcript timestamp on the next header refresh so a gateway
receipt timestamp cannot disagree with the persisted provider event. History reads
recover completions missed while the app was disconnected. Failed completion reads keep a
known cached date and report incomplete coverage instead of substituting activity
or the current time.
