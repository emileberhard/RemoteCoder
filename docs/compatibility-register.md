# Compatibility register

Every compatibility path that remains in the tree, with its owner, the reason
it exists, and the condition that removes it. A path that is not listed here
must not exist; a new one is added here in the commit that introduces it.

## App: state written by earlier builds

Removal package A2.5 (decision D4) deletes this whole group, and its tests, once
one launch on the phone has logged that each condition below holds.

| Path | Owner | Reason | Removal condition |
|---|---|---|---|
| Legacy `ChatMessage` image/file keys and readable attachment text on checkpoint writes | `ChatMessage` (Core `Conversations/`) | Builds before sent attachment tiles require `imageAttachments`; rollback keeps known media and reads pasted text as plain text | No supported rollback build predates sent attachment tiles; old checkpoints remain readable until migrated or retired |
| Host-scoped state migration: legacy working directory, pins and session index adopted into per-host files | `HostScopedStateMigration` (`RemoteCoder/Services/Gateway/`), `ConversationIndex.legacyEntriesSynchronously`, `ConversationHeaderStore` synchronous read | The phone still holds unscoped defaults and files from before multi-host | `gateway.hostScopedStateMigrated` is set on the phone |
| Unscoped pin key `codex.pinnedSessionNames` and the `hostID: nil` working-directory key | `ConversationPinStore.legacyStorageKey`, `HostPreferences` | Read only by the migration above | The migration is removed |
| Retired timeline cache read for local conversations | `LegacyConversationMigration`, `ConversationCheckpointStore.allowsLegacyMigration` | Old `conversations-v1` timelines keep local activity until a checkpoint exists | No v1 timeline remains on the phone; a remaining one falls back to gateway history, which is authoritative |
| Plaintext host list in defaults, removed after the protected write is read back | `HostStore.load`, `HostStore.hostsKey` | Hosts saved before the Keychain snapshot | Keychain `hosts-v2` exists on the phone |
| File-keychain `hosts-v2` item moved into the data protection keychain | `KeychainGatewayCredentials.migrateFileKeychainItem` (Core `Hosts/GatewayCredentials.swift`) | Mac builds before 3.24.1 saved hosts in the file keychain | Every Mac has launched 3.24.1 or later |
| Device snapshot without a host directory: its hosts join the synced directory with no edit time | `HostStore.load`, `HostDirectory.adopt` (Core `Hosts/`) | Devices saved hosts before iCloud host sync; adopting them unedited lets any explicit edit or deletion win | Every device has launched the host-sync build |
| Missing `transport` decodes as trusted network | `GatewayHostConfiguration.init(from:)` (Core `Hosts/GatewayHost.swift`) | Hosts saved before transports existed (LN7) | Every stored host has `transport` |
| Import of the unversioned marks replica | `ConversationMarksStore.load` and `storedFile(in:)` (Core `Conversations/Marks/ConversationMarksStore.swift`), `ClaudeHostStateMigration.migrateMarks` | Builds before settlement saved `conversation-marks.json` and cannot decode settlement changes, so the replica moved to `conversation-marks.v2.json` and the old file stays untouched for a downgrade | Every target directory on the phone and the Macs holds `conversation-marks.v2.json` and no supported build predates settlement |
| Per-device favorites adopted as pending adds to the host's favorites | `HostDirectories.loadFavorites` and `DirectoryFavoritesReplica.init(legacyPaths:)` (Core) | Builds before favorites sync kept each device's favorites under `directoryPicker.favoritePaths.<host>`; adding them on the host unions every device's list. The key stays for a downgrade | The phone, the iPad and both Mac apps have launched the favorites-sync build |
| Session metadata stored as a bare array | `ConversationMetadataStore.load`, `SessionMetadataLocalState.legacy`, `ConversationMetadataService` | Settings files written before the versioned document | No host directory on the phone holds an array file |
| Session metadata schema 2 ISO dates | `ConversationMetadataStore.load` | Schema 3 stores native Date numeric values without losing fractional seconds; schema 2 imports its existing whole-second values | Every supported device cache uses schema 3 and no supported rollback build writes schema 2 |
| Thread headers without explicit agent classification | `ConversationHeader.init(from:)` | A saved relation proves child ancestry; a missing relation proves neither root nor unresolved success | Every retained header cache stores explicit classification and no supported rollback build omits it |
| Bare `new-chat` draft key and blank unsent-draft records | `ComposerDraftPersistence.adoptLegacyNewChatDrafts` (Core `Conversations/`) | Builds before unsent drafts kept one New Chat slot per host under `new-chat` and stored it even when blank; adoption re-keys a non-blank slot to `new-chat:<draft id>` and deletes blank ones | Every draft store on the phone and the Macs has opened once on the unsent-drafts build, no supported rollback build still writes bare `new-chat`, and `ClaudeHostStateMigration` no longer imports pre-migration draft stores |
| Composer drafts holding inline images | `ComposerAttachment.Content.legacyImage` (decoded from the `image` key) and `FileAttachmentImports.resume` (Core `Files/`) | Builds before photos-as-files saved composer images inline in drafts; resume uploads their bytes as a file in place so an unsent photo is not lost | Every draft store on the phone and the Macs has opened its drafts on the photos-as-files build and no supported rollback build writes inline images |
| Live Activities without a host id are ended by any host | `ActiveTasksLiveActivityScope.isLegacy` and `mayEnd`, `ActiveTasksLiveActivityService.endLegacyActivities`, optional `hostID` in `RemoteCoderActiveTasksAttributes` | Activities requested by builds before per-host activities | No such activity is live on the phone; `hostID` then becomes required |

## App: tolerance for older gateways and payloads

| Path | Owner | Reason | Removal condition |
|---|---|---|---|
| Metadata reads returning full `entries` without a snapshot `revision` | `ConversationMetadataSnapshot`, `ConversationMetadataService` (Core `Conversations/Metadata/`) | Gateways before conditional metadata reads ignore `knownRevision` and always return the whole map; the client accepts that authoritative map and keeps its validator absent | Every configured gateway and supported rollback returns content validators; then require a revision on full reads |
| Omit `$/cancelRequest` unless the connection's `daemon/ready` advertises `capabilities.cancelRequest: true` | `GatewayClient.abandonPending` (Core `Gateway/`), `gateway/transport.rs` | Older gateways pass unknown notifications through to Codex and do not cancel gateway-owned reads | Both configured gateways and every supported rollback advertise cancellation; remove the capability gate |
| Missing `agentOwnersCoverage` means complete ownership | `CodexGatewayDaemon.ActiveTurnsResponse`, `TurnRegistry.apply` | The GUI test host can still run a gateway predating discovery coverage during catch-up | Both gateways and every supported rollback send `agentOwnersCoverage`; make the field required |
| Claude content subscriptions unavailable on an older gateway (`-32601`, or its dispatch decoder’s `-32600`) | `GatewayClient.ContentSubscriptionState.unsupported` (Core `Gateway/GatewayClient.swift`) | A new app must initialize and load history against the live 3.37.0 gateways; the older gateway keeps full content fanout. Probe once per connection and retry only on reconnect, while subscription state stays explicitly unsupported | Both configured gateways and every supported gateway rollback provide `conversation/subscriptions/set`; no supported app-to-gateway pairing can reach the older decoder |
| A completion notification without an event id renders but never enters the delivery ledger | `ForegroundNotificationPresentation.Ledger`, `TaskCompletionNotificationPayload.presentationID` | Payloads from before event ids | Both gateways run the phase 10 build and no such payload is pending |

## Gateway: tolerance for older apps

| Path | Owner | Reason | Removal condition |
|---|---|---|---|
| Metadata reads without `knownRevision` always return full `entries`, with an added `revision` | `ConversationMetadataStore::read`, `Gateway::metadata_rpc` | Older apps require a full map and ignore the extra field; only a matching opaque validator opts into explicit `unchanged` | Every supported client and rollback sends conditional validators and handles explicit unchanged snapshots; unconditional reads may remain useful for cold starts |
| `thread/start.acceptProviderFallback: true` opts into cross-harness admission; absence keeps the selected harness | Gateway new-thread admission; `GatewayClient.startThread`, web `TurnDispatcher`, shared CLI `turns.py` | Older clients cannot dispatch or persist a returned thread from another harness. Opted-in clients adopt its actual identity and settings; existing threads and Voice never opt in | Every supported client and rollback handles cross-harness admission, including actual model/effort readback; then the gateway may remove the compatibility gate and clients remove the field together. Voice remains excluded |
| `POST /uploads?name=` stores one whole body as a single attempt at a fresh resumable upload, discarded unless stored | `legacy_upload` (`http/server/files.rs`) | Apps before resumable uploads attach files this way, and the gateway deploys before the iPhone, the Mac apps and TestFlight builds update | The iPhone, the iPad and both Mac apps run a build with resumable uploads and no supported rollback build predates it |

## APNs broker rollout

| Path | Owner | Reason | Removal condition |
|---|---|---|---|
| Omit `relevance_score` unless `/healthz` confirms support | `PushBroker.supports_live_activity_relevance` | Older AgenTTY brokers reject unknown request fields | Every supported broker and rollback accepts relevance scores |

## Gateway: wire fields and handlers kept for out-of-repository consumers

The app no longer reads any of these. the private operator configuration repository (the automation service and
`codex-threads`) and esmalib still do until they are checked against the new
gateway. Removal package X10.5, after the phase 10 deploy and acceptance, on
both hosts.

| Path | Owner | Reason | Removal condition |
|---|---|---|---|
| Full Claude content fanout until a connection first sends `conversation/subscriptions/set` | `gateway/subscriptions.rs`, connection-owned `ContentSubscriptions` | Gateways deploy before apps; older TestFlight builds, `rc-gateway`, `codex-threads`, automations, agent-calls and launcher callbacks still observe Claude without a subscription set | Every shipped app and gateway client sends the set, including an explicit empty set when observing no thread |
| `latestSequence`, `oldestSequence`, `gapBefore` in `daemon/replayNotifications` results | `ReplayPage` (`notifications/history.rs`) | Consumers that predate `hasMore`, `throughSequence` and `epoch` page on them | X10.5: the live automation and `esmalib notify send` pass against the new gateway |
| `sinceUnixSeconds` request parameter | `NotificationHistory` (`notifications/history.rs`) | Previously deployed automation runtimes use it; new recovery uses `turn/inspect` | Both gateways and the automation service have accepted the new recovery path; remove in the next gateway cleanup |
| `appServerInventoryAvailable` beside `coverage` in `daemon/activeTurns` and its change notification | `ActivityContent` (`gateway/activity.rs`) | It mirrors `coverage.codex` for `codex-threads` and older clients | X10.5, after `rc_gateway.py steer` and `codex-threads` read `coverage` |
| `calls/device/register` and `calls/device/unregister` | `Gateway` calls handlers (`gateway/calls.rs`), dispatch table (`rpc/dispatch.rs`) | Builds that register a VoIP device per call store | X10.5 |
| `navigation/device/register` | `gateway/rpc_methods.rs`, `NavigationDestination` (`navigation.rs`) | Builds that register the navigation device outside the registry | X10.5 |
| `calls/host` | `gateway/calls.rs`, `rpc/dispatch.rs` | `agent-calls/agent_calls/cli.py` still resolves the call host through it | `agent-calls` stops calling it (X10.5 or earlier, whichever removes the CLI use) |
| Legacy token-file fallback while `devices.json` was never written: `apns_device_token`, `active_tasks_live_activity_token`, `apns_environment`, `apns_notification_identity.json`, `agent-calls.json` `device`, `navigation-device.json` | `devices::legacy::Sources`, `DeviceRegistry`, `Origin::Legacy` (`devices/`) | Push and call delivery before the phone's first `devices/register` | X10.5, together with the two handlers above that still write those files |

## Gateway: durable state and files from earlier builds

Each removal needs a read-only check on both hosts first; a host restored from
an old backup keeps its item until the check passes.

| Path | Owner | Reason | Removal condition |
|---|---|---|---|
| Conversation marks schema 2 import | `conversation_marks/migration.rs`, `ConversationMarksStore` | Gateway schema 3 adds `doneThrough` in `conversation-marks.v3.json`; previous gateways reject unknown fields and exact schema mismatches, so v2 and v1 files stay untouched for rollback | Every host and account marks context holds v3 and no supported rollback gateway predates done suggestions |
| Conversation marks schema 1 import, its read of `conversation-handoffs.json`, and the `pendingNativeUnarchive` drain | `conversation_marks/migration.rs`, `ConversationMarksStore::pending_native_unarchives` and `complete_native_unarchives`, `Gateway::drain_pending_native_unarchives` (`gateway/rpc_methods.rs`) | Settlement replaced Archive. Hosts hold `conversation-marks.json` with `archivedAt`, left untouched so a rollback to an older gateway reads valid marks, and purpose-free natively archived Codex threads must reappear in `thread/list` | A release after the one that introduced settlement has run on both hosts, every marks context there has `conversation-marks.v3.json`, and none still lists `pendingNativeUnarchive` |
| Restart journal `schemaVersion` 1 migration | `migrate` in `providers/claude/restart.rs` | The migration lacks deployed-build provenance, and journals written by earlier gateways may still exist | No journal on either host has `schemaVersion` 1 |
| Retired Codex and Claude enrollment IDs | Provider adoption receipts and one account redirect | Old app windows, archived automation receipts, reply routes and launcher resume paths still name retired enrollments; `/ws` accepts any generation and serves the default | No served redirect for 14 days and old app windows, receipts, callbacks and launcher paths migrated or retired; remove both `retiredClaudeAccountIds` and `retiredCodexAccountIds` with the redirect, then explicitly retire cold source homes; see [Provider accounts](provider-accounts.md#codex-enrollment-adoption) |
| Scoped pending pre-retirement mark-all reads | `ConversationMarksStore::update`, immutable `readScopes` in the Codex adoption receipt | Old app state can hold an unsent mark-all edit for the original default or a retired account, including uncached conversations; the merged global baseline cannot express that scope | Every supported device has durably converted and acknowledged all pre-retirement pending marks and no supported rollback app can create them. Keep the scope evidence after cold profiles are removed; missing old evidence must fail visibly, never infer from current history |
| Forward-only Codex adoption commit | `runtime::retire_codex_accounts`, registry pending commit and installer profile snapshot | A previous gateway must not resume adopted work from both its cold enrollment home and the default | Before the pending registry removal commits, restore snapshots. After commit, binary rollback keeps adopted native/gateway state, empty enrollment registry and default recovery journal. Old app enrollment windows may fail on that binary. Remove the adoption adapter after both hosts are committed and supported rollback versions no longer understand enrollments |
| Pid record key `linuxProcessIdentity` | `PidRecord` (`providers/codex/daemon.rs`) | The Codex daemon (upstream `app-server-daemon`) still accepts and may have written it | The pinned fork stops accepting the alias and no running daemon was started before that build |
| Codex packages under `packages/standalone` for homes that already use them | `providers/codex/package.rs` | An existing home keeps its namespace instead of moving | No enrolled home uses `packages/standalone` |
| Removal of the old `launch-chatgpt-with-shared-codex` launcher on install and uninstall | `LEGACY_DESKTOP_LAUNCHER` (`runtime/install/transaction.rs`, `runtime/install/uninstall.rs`) | Hosts installed before the current launcher name | No enrolled host has the file |
| Official ChatGPT bundled Codex at `Contents/Resources/codex` or `Contents/Resources/codex-cli/bin/codex`, requiring exactly one present path | `read_bundled_codex_version` (`runtime/desktop.rs`), `chatgpt_matches_release` (`scripts/install-shared-codex-stack.zsh`) | The source official app uses the earlier layout and must remain usable during matched-stack rollback | Both hosts and every supported official-app rollback artifact use the newer layout |
| Claude minted-session record in its own `.minted` file | `providers/claude/conversation_index.rs` | Older gateways reject unknown records in the identity index, so a rollback must still read it | Rollback to a gateway before the record is no longer supported |
| Synthetic turn id `claude-turn-<n>` for history rows without an index identity | `providers/claude/projection.rs` | Sessions recorded before the identity index | No indexed session lacks row identities, or those sessions are re-indexed |
| Transcript reader accepts `parent_tool_use_id` as well as `parentToolUseID` | `activity/external/claude.rs` | Claude CLI versions write either spelling | The supported CLI range writes one |

## Tools and other repositories

| Path | Owner | Reason | Removal condition |
|---|---|---|---|
| Legacy replay probe of `latestSequence` | `dev-tools/src/remotecoder_tools/performance.py` | Proves the gateway still serves the old cursor | X10.5 removes the fields it checks |
| esmalib and the private operator configuration repository fallbacks to the legacy token files and old replay fields | esmalib reader, `automation_service`, `codex-threads` (other repositories) | They must work against a gateway on either side of the deploy | X10.5, each in a focused commit in its own repository |
| Restoring pre-renumbering thread-history migration versions | `scripts/codex-thread-history-legacy-versions.py` | The Codex fork moved its private thread-history migrations out of upstream's version range, and the candidate rewrites that bookkeeping on first open. Runtimes built before the move (0.155.0-alpha.16, 0.158.0-alpha.2.1) cannot open a rewritten database, so a reverse deployment onto one of them needs the old bookkeeping back | Both hosts have accepted a runtime with the renumbered migrations and no retained rollback asset predates it |

| Legacy compilation eviction activation | `scripts/build_cache.py.load_policy`, configs `build/compilation-cache-policy.json` and `build/compilation-cache-eviction.json` | The legacy policy flag stays false while the new activation file enables only the corrected owner; stale worktrees must not delete outside RemoteCoder-Build | No supported release or live worktree uses the old activation flag or its broader eviction implementation |
| Legacy six-key `build/macos-cache-policy.json` reader | Pinned older `scripts/build_cache.py` in immutable release tags and live worktrees; source in the private maintainer build policy | Re-running supported releases and older worktrees must keep reading their exact policy schema. New runners use `compilation-cache-policy.json` for retention and `compilation-cache-eviction.json` for activation | No supported release tag or live worktree predating the aggregate compilation policy still loads this file |

## Planned checkpoint database rollout

This path is not active; checkpoints still use schema 1. The deferred schema-2
PR must introduce the reader before enabling its writer.

| Path | Owner | Reason | Removal condition |
|---|---|---|---|
| Planned schema-2 checkpoint reader with a schema-1 writer, followed by schema-2 writes in a later release | `CheckpointDatabase` | Rollback, preview and branch builds must read every canonical checkpoint without stranding unique local records in recovery | Enable schema-2 writes only after every supported rollback/install consumer reads schema 2; remove schema-1 migration only after all retained databases are migrated or explicitly retired and no supported writer creates schema 1 |

## Release cache

| Path | Owner | Reason | Removal condition |
|---|---|---|---|
| Mac App Store package as completion marker through 3.73.0 | `scripts/release-cache.py`, `mac_completion` | Retained direct releases predate the independent direct completion marker | Neither host retains a release reference at 3.73.0 or earlier; then use the direct marker for every retained release |
| `testflight-` symbol directory names through 3.73.0 | `scripts/release-cache.py`, `symbol_directory` | Retained pre-migration direct dSYMs use the former TestFlight label | Neither host retains a release reference at 3.73.0 or earlier; then use `direct-` for every retained symbol directory |

The gateway projects the current parent tag into the legacy thread header
`parentThreadId` for app versions that do not read `parent`. The value is the
parent's thread ID only when the parent belongs to this host; remote parents
and promoted roots project to null. The authoritative header field is
`parent: {hostId, threadId} | null`. Remove the flat projection when the minimum
supported app version reads the nested parent address.
