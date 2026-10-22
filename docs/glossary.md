# Glossary

One line per term, with the type that owns it and the document that holds its contract. When a meaning changes, rename code, docs and user-visible copy together in one change. Names here are the final names of the ownership layers; the ownership-layer rules are in [System architecture](system-architecture.md#ios-ownership-layers).

## Hosts and providers

| Term | Meaning | Owner | Contract |
|---|---|---|---|
| Host | A Mac running one gateway, configured in the app by name, address and credentials | `HostStore`, `HostServices` | [System architecture](system-architecture.md#ios-host-ownership) |
| Host directory | The hosts shared by the user's devices through iCloud Keychain, merged by host ID with deletion tombstones | `HostDirectory`, `HostStore` | [Owned operations](owned-operations.md#credentials-and-transport) |
| Synced preferences | The user's settings every device shares (model and reasoning visibility, new-chat defaults, dictation, voice, theme, account names, drawer order), replicated through every host with the newest change per setting winning | `SyncedPreferenceStore`, `SyncedPreferenceExchange`, `host-daemon-rs/src/user_preferences.rs` | [App](../RemoteCoder/AGENTS.md#workspace-and-hosts-workspace-chat) |
| Gateway | The Rust process on a host that authenticates the app and serves every JSON-RPC method | `host-daemon-rs/src/gateway` | [Gateway](../host-daemon-rs/AGENTS.md) |
| Connection query scheduler | The connection-owned FIFO, running read futures, cancellation and receipt-based deadlines; all client connections share host admission | `ConnectionQueries` (`gateway/transport/queries.rs`), `RequestBudgets` | [Owned operations](owned-operations.md#gateway-and-claude-concurrency) |
| Planned restart | A deploy, installer handoff or other intended gateway stop, announced to clients with WebSocket close code 4012 and shown as an update rather than an error | `Gateway::restart_in_progress`, `GatewayClient`, `GatewayConnectivity` | [System architecture](system-architecture.md#lifecycle-and-recovery) |
| Relay route | The Tailscale-independent fallback from the app through a VPS and a reverse SSH tunnel to a gateway's LAN listener | `GatewayRoutes`, `relay/`, `scripts/relay.py` | [Relay route](relay-route.md) |
| Execution target | A physical host, with one chat target model and native connection | `ExecutionTargetRegistry` | [System architecture](system-architecture.md#ios-host-ownership) |
| Provider | The agent backend of a conversation, Codex or Claude | `AgentProvider` | [System architecture](system-architecture.md#agent-providers) |
| Account | A provider identity owned by llm-router; the app shows its usage and resets while chats use host-default contexts | `AccountDirectory`, `ClaudeAccountDirectory`, `host-daemon-rs/src/accounts` | [Provider accounts](provider-accounts.md) |
| Shared Codex | The one managed Codex package a host shares between ChatGPT Desktop, the gateway and external Codex agents | `host-daemon-rs/src/runtime` | [Gateway](../host-daemon-rs/AGENTS.md#codex-runtime-and-desktop) |
| Managed app-server | The version-matched `codex app-server` the gateway starts and proxies | `host-daemon-rs/src/providers/codex` | [Gateway](../host-daemon-rs/AGENTS.md#codex-runtime-and-desktop) |
| Retired profile adoption | Copying legacy Codex history and state into the single host-default runtime, with exact recovery and a forward-only adoption commit | `accounts::codex_migration`, `runtime::accounts` | [Provider accounts](provider-accounts.md) |
| Desktop reconciliation | The gateway's decision to stop and reopen ChatGPT Desktop so it uses the shared Codex | `host-daemon-rs/src/runtime/desktop` | [Host observability](host-observability.md) |
| Compatibility register | The approved ChatGPT, Codex and runtime identity with acceptance evidence | `docs/codex/compatibility.json` | [Compatibility register](compatibility-register.md) |
| Automation management | Viewing and editing the primary service host's service-owned definitions, revisions, and runs across chat targets | `AutomationManagement`, `HostServices`, `host-daemon-rs/src/automations.rs` | [Automations](automations.md) |
| Definition revision | An immutable complete automation configuration snapshot; runtime movement does not create a revision | configs automation service | [Automations](automations.md#definition-history) |

## Conversations

| Term | Meaning | Owner | Contract |
|---|---|---|---|
| Conversation address | Host plus thread id; thread ids are unique only within one gateway | `ConversationAddress` | [System architecture](system-architecture.md#history-and-live-state) |
| Thread | The provider's durable conversation, identified by a thread id | `ConversationSession` | [System architecture](system-architecture.md#history-and-live-state) |
| Turn | One prompt and the agent's work until it ends, is interrupted or dies | `TurnRegistry`, `ActiveJob` | [Gateway](../host-daemon-rs/AGENTS.md) |
| Item | One element of a turn: a message, tool call, command, file change or question | `ServerNotification` | [System architecture](system-architecture.md#history-and-live-state) |
| Conversation session | The single transcript owner for one conversation | `ConversationSession` | [System architecture](system-architecture.md#history-and-live-state) |
| Native transcript container | The Mac scroll surface, cached row placement, bounded row index and scroll-command owner; conversation data remains in the session | `AppKitTranscriptContainer`, `TranscriptRowIndex` | [System architecture](system-architecture.md#history-and-live-state) |
| Logical transcript row | A loaded Mac row's current inputs, cached height/estimate and presentation state, independent of whether its graph is mounted | `TranscriptLogicalRow` | [System architecture](system-architecture.md#history-and-live-state) |
| Transcript row host | A Mac SwiftUI root and current measurement admitted around the viewport or retained by an active owner | `TranscriptRowHost` | [System architecture](system-architecture.md#history-and-live-state) |
| Tool media | An image or PDF a tool call delivered to the agent, kept as a host file and shown as a viewed-media row | `ToolMediaStore`, `ViewedMedia` | [Remote files](remote-files.md#inline-images) |
| HTML visual | A content-addressed HTML block embedded in a transcript | `PublishVisual`, `HTMLVisualReference`, `HTMLVisualInline` | [HTML visuals](html-visuals.md) |
| Verified visual document | The immutable local HTML copy bound to a physical host and digest, reusable offline | `HTMLVisualDocumentStore`, `HTMLVisualDocumentCache` | [HTML visuals](html-visuals.md#document-ownership-and-offline-reads) |
| Visual page admission | The app-wide bounded live-page and waiting-request ownership, including interaction pins | `HTMLVisualRenderer`, `HTMLVisualPageAdmission` | [HTML visuals](html-visuals.md#visibility-interaction-and-cached-geometry) |
| Visual preparation | A screen's bounded work that makes its visuals presentable before the reader reaches them: awaited for opening and revealed rows, near for rows around the viewport, speculative for nearby history | `HTMLVisualPreparation`, `HTMLVisualPreparationHost` | [HTML visuals](html-visuals.md#readiness-and-background-preparation) |
| Visual presentation cache | Persisted layout estimates and encoded snapshots with separate height, image and byte bounds | `HTMLVisualPresentationCache` | [HTML visuals](html-visuals.md#visibility-interaction-and-cached-geometry) |
| Link chip | A Markdown link drawn as a capsule with a site icon or symbol and a semibold label, still a native link | `LinkChip`, `InlineMarkdownText`, `LinkChipRenderer` | [Link chips](link-chips.md) |
| Site icon | A public host's favicon from its root page's metadata, cached in memory and on disk with bounded fetches | `SiteIconStore`, `SiteIconDisk` | [Link chips](link-chips.md#ownership-and-bounds) |
| History window | The bounded slice of a conversation's items the app keeps mounted | `HistoryWindow` | [System architecture](system-architecture.md#history-and-live-state) |
| Checkpoint | The persisted snapshot of a conversation for instant reopening | `ConversationCheckpointStore` | [Persistence and energy](persistence-energy.md) |
| Drawer | The history sidebar across all configured hosts | `ConversationIndex`, `ConversationSidebarProjection` | [System architecture](system-architecture.md#conversation-drawer-order) |
| Drawer view | Priority (ranked rows below the pinned ones) or Projects (one foldable section per project), each ending with the Settled shelf, with the Unread Only filter | `ConversationDrawerPreferences`, `ConversationDrawerArrangement` | [System architecture](system-architecture.md#conversation-drawer-order) |
| Drawer rank | A row's tier (needs you, running, unread, recent), recency and settlement, captured when the drawer opens | `ConversationDrawerRank`, `ConversationDrawerLayout` | [System architecture](system-architecture.md#conversation-drawer-order) |
| Project | The repository or directory a conversation works in, keyed by its Git remote across hosts | `ProjectIdentity`, `host-daemon-rs/src/conversation_projects.rs` | [System architecture](system-architecture.md#conversation-drawer-order) |
| Conversation marks | A gateway's pins, read state, purposes, settlements and done suggestions, shared by every device | `ConversationMarksReplica`, `host-daemon-rs/src/conversation_marks.rs` | [System architecture](system-architecture.md#conversation-drawer-order) |
| Purpose | A mark saying a conversation was started by a probe or an automation, so its completions are never unread and probes stay out of the drawer | `ConversationPurpose` | [System architecture](system-architecture.md#conversation-drawer-order) |
| Settled conversation | A conversation in the drawer's folded Settled shelf: settled by hand, or after three days without activity, until new activity, a pin or unread state brings it back. Unrelated to settled Markdown blocks or the slider-settle haptic | `ConversationMarks.isSettled`, `ConversationSidebarProjection` | [System architecture](system-architecture.md#conversation-drawer-order) |
| Early title | The title a new conversation gets 15 seconds into its first turn, written mid-turn through a side question without a judge; Regenerate Name asks for one on demand | `conversation_review/early_title.rs`, `Gateway::regenerate_title` | [System architecture](system-architecture.md#automatic-conversation-titles-and-done-suggestions) |
| Probably done | Jev's suggestion that the latest request is fulfilled, held through its judged activity timestamp; shows a green checkmark without moving or settling the row | `ConversationMarks.isProbablyDone`, `gateway/conversation_review/done.rs` | [System architecture](system-architecture.md#automatic-conversation-titles-and-done-suggestions) |
| Settlement | The mark behind it: `settled(through)` or `active(through)`, compared with the conversation's latest activity | `ConversationSettlement`, `host-daemon-rs/src/conversation_marks.rs` | [System architecture](system-architecture.md#conversation-drawer-order) |
| Chat target | The live state of one execution target: connection, activity, turns, questions and catalogs | `ChatTargetModel` | [System architecture](system-architecture.md#ios-ownership-layers) |
| Window | One scene: its selected target, drawer state and screens | `ChatWindowModel` | [System architecture](system-architecture.md#ios-ownership-layers) |
| Screen | What one window presents for one target: composer, drawer, alerts and transcript subscription | `ChatScreenModel` | [System architecture](system-architecture.md#ios-ownership-layers) |
| Quick action | An App Intent that opens a new chat, Voice Mode or the camera, delivered once through the router | `ExternalEventRouter` | [App area rules](../RemoteCoder/AGENTS.md) |
| Share inbox | Files and text the share extension hands to the app through the app group, claimed once by a New Chat in the host's home folder | `SharedItemsInbox`, `RemoteCoderShareExtension/` | [App area rules](../RemoteCoder/AGENTS.md) |
| Camera capture | Shared multi-shot camera for the composer, app and locked extension; original photos save to the camera roll, and Done attaches the selected batch unsent | `CameraCaptureSession`, `CameraCaptureView`, `CameraCaptureBatch`, `LockedCameraCaptureImports`, `RemoteCoderCaptureExtension/` | [App area rules](../RemoteCoder/AGENTS.md) |
| Question | An agent's asynchronous question with a host-owned answer state | `QuestionReplica` | [Async questions](async-questions.md) |
| Attention summary | The Mac's cross-target view of conversations that need you (an unseen question or waiting input that no settlement covers) and running ones, for the Dock and the menu bar item | `AttentionSummary`, `AttentionCenter` | [App area rules](../RemoteCoder/AGENTS.md) |
| Agents | The per-conversation view of subagents and background work | `ConversationAgentsModel` | [Conversation agents](conversation-agents.md) |
| Other client | A process outside the gateway holding a conversation's session open, such as a terminal TUI; the gateway refuses to resume that session | `host-daemon-rs/src/gateway/takeover.rs`, `ConversationActivity` | [Gateway](../host-daemon-rs/AGENTS.md#gateway-rpcs) |
| Take over | Stopping the other client so the gateway owns the session; the composer's lock panel | `ChatTargetModel`, `ComposerTakeOverPanel` | [System architecture](system-architecture.md#history-and-live-state) |

## Input and voice

| Term | Meaning | Owner | Contract |
|---|---|---|---|
| Side question | A one-off question answered from a conversation's own context and warm prompt cache without changing it, also mid-turn: Claude's `side_question` control request (or a non-persistent one-shot fork without a warm runtime), or an ephemeral Codex fork; automatic titles use it | `Gateway::side_question`, `ClaudeSupervisor::side_question`, `ClaudeSupervisor::detached_side_question` | [Gateway README](../host-daemon-rs/README.md#automatic-conversation-titles-and-done-suggestions) |
| Slash command | A composer action on the exact existing conversation; `/compact` invokes native context compaction | `ComposerSlashCommand`, `ConversationSession` | [System architecture](system-architecture.md#composer-drafts) |
| Composer draft | The unsent text and attachments of one conversation, and an unsent draft's setup | `ComposerDraft` | [System architecture](system-architecture.md#composer-drafts) |
| Unsent draft | A New Chat draft with content, keyed `new-chat:<UUID>`, listed in the drawer until sent or discarded | `ComposerDraftStore.unsentDrafts`, `UnsentDraftRow` | [System architecture](system-architecture.md#composer-drafts) |
| Composer document | The ordered text and inline paste references, with one main-actor range-edit owner and native storage while mounted | `ComposerDocument` | [System architecture](system-architecture.md#composer-drafts) |
| Dictation | Speech-to-text into the composer, with a durable receipt per recording | `DictationSession`, `DictationReceipt` | [System architecture](system-architecture.md#composer-drafts) |
| Voice Mode | The realtime spoken conversation with a thread's agent | `VoiceCallCenter`, `VoiceCall` | [System architecture](system-architecture.md#voice-paths) |
| Device tool | A registry tool executed by the installation driving the current input, starting with `take_photo` | `gateway/device_tools.rs` | [System architecture](system-architecture.md#device-tools) |
| Turn driver | The authenticated installation that submitted the thread's latest admitted text or voice input; unknown and cleared are distinct; operator and empty-declaration inputs clear it | `DeviceTools` | [Gateway](../host-daemon-rs/AGENTS.md#agent-tools-srcagentstools) |
| Device operation | One invoke and its exact-connection result, cancellation or unknown outcome | `DeviceTools` | [System architecture](system-architecture.md#device-tools) |
| GPT Live | The realtime speech model that Voice Mode and agent calls attach to a thread | `host-daemon-rs/src/voice` | [System architecture](system-architecture.md#voice-paths) |
| Speech relay | The gateway path that keeps speech-provider keys off the phone | `host-daemon-rs/src/voice` | [Gateway README](../host-daemon-rs/README.md) |
| Agent call | A call an agent starts to reach a person, attached to its originating thread | `agent-calls/` | [Agent calls](../agent-calls/README.md) |

## Navigation and platform

| Term | Meaning | Owner | Contract |
|---|---|---|---|
| Live Activity attention | One host aggregate of unread finishes (marked when they asked an unseen question) and running root count; gateway-authored initial content, updates and normal End | `ActiveTasksLiveActivityService`, `host-daemon-rs/src/gateway/live_activity.rs`, `PushService` | [Gateway](../host-daemon-rs/AGENTS.md#push-notifications) |
| Voice call Live Activity | The Lock Screen and Dynamic Island activity a Voice Mode intent start presents for its exact call, ended by that call's teardown | `VoiceCallLiveActivity`, `VoiceCall.startWithLiveActivity`, `RemoteCoderVoiceCallWidget` | [App](../RemoteCoder/AGENTS.md#app-intents-and-quick-actions-app-shared) |
| Live Navigation | Agent-driven live-location guidance on the phone | `host-daemon-rs/src/navigation.rs` | [Live navigation](live-navigation.md) |
| LPSE | The Location Push Service Extension that wakes the app for one-shot location | `RemoteCoderLocationPushService/` | [Live navigation](live-navigation.md) |
| Energy state | Normal or conserving rendering and prefetch, chosen from Low Power Mode and thermal state | `AppEnergyPolicy` | [Persistence and energy](persistence-energy.md) |
| Haptic | A named feedback event from the one catalog | `HapticService` | [Haptics](haptics.md) |
| Interface zoom | The Mac's app-wide text and control scale, 80–200 %, set from the View menu and applied as `interfaceScale` | `InterfaceZoom`, `InterfaceScale.swift` | [App area rules](../RemoteCoder/AGENTS.md) |

## Build and operations

| Term | Meaning | Owner | Contract |
|---|---|---|---|
| Build identity | Release version or Dev, full source commit and recorded modification state, shared by app and gateway displays | `BuildIdentity` | [Build stamps](../Project.swift) |
| Gateway scheduling | Best-effort macOS thread QoS, agent child preparation and Darwin-background guard | `platform/macos/scheduling.rs` | [Owned operations](owned-operations.md#gateway-scheduling) |
| Candidate | A built gateway or Codex artifact that has not yet been approved or installed | `just gateway-candidate` | [Owned operations](owned-operations.md) |
| Receipt | The recorded evidence of one build, install or probe run; it proves only what it recorded | `scripts/build_support.py` | [Owned operations](owned-operations.md) |
| Lease | Exclusive, expiring ownership of a mutable mirror, cache or device during an operation | `scripts/build_support.py` | [Owned operations](owned-operations.md) |
| Worker | A private process that carries out an owned operation on behalf of a gateway lease | `agent-calls/`, `dev-tools/` | [Owned operations](owned-operations.md) |
| Acceptance | Evidence that the exact deployed artifact behaves correctly on its real boundary, separate from build, install and launch | per feature contract | [Repository model](repository-model.md) |
