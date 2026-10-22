# Synced browser preferences

`Workspace` owns one durable `SyncedPreferences` replica of the ten settings the browser consumes, exchanged through the unchanged gateway `preferences/read`, `preferences/update` and `preferences/changed` contract. One host-default execution context exchanges per physical host; enrollments share that replica. Gateways preserve the other native keys without browser replication. Native owners remain authoritative: `RemoteCoder/AGENTS.md` (Synced preferences), `host-daemon-rs/AGENTS.md` (User preferences), `ChatWorkspaceModel.syncedPreferenceKeys`, `ModelPickerPreferences`, `ModelVisibility`, `ReasoningEffortVisibility` and `NewChatDefaults`.

The existing gateway contract supplies conflict ordering, persistence and broadcasts, so the browser adds only a local replica and workspace exchanges. A web-only settings document would split ownership. Add a native key to the typed registry only when a browser feature consumes it; pins, host IDs and credentials must not be inferred into that registry.

## Replication

Each key retains `{value, updatedAt, device}`; the greatest `(updatedAt, device)` wins. Versions are integer milliseconds in `1...2^53-1`, with a per-key monotonic floor when the local clock is behind. Null is a retained reset tombstone. Each live browser workspace has its own UUID to distinguish concurrent tabs. The bounded replica survives reload in `remotecoder.web.preferences.v1`; storage events merge other tabs. The old browser theme is adopted at version zero and never overwrites a synced choice.

Every physical host exchanges on refresh/reconnect, browser focus/activation, and replica changes from local controls or another host. There is one coalesced exchange per host, with coordination held privately by the workspace. History, model discovery and conversation recovery proceed independently; fresh-chat default seeding waits for the first successful replica read, then uses the local replica during subsequent exchanges. Outbound catch-up writes do not delay seeding. Failed reads remain failed in `HostState.preferences`; reconnect or `workspace.syncPreferences()` retries. Retired contexts and disposed workspaces reject late results. Fixture gateways use independent in-memory replicas that retain all opaque native keys, including unknown values and reset tombstones. No polling timer or bridge-owned preference database is introduced.

Unknown keys remain with their owning client. Values native defaults cannot represent are ignored without republishing older data over them. Unknown enum values remain in the replica while typed getters return null and derived owners use their native default. Computed defaults never write back. A corrupt browser cache is reported and reconstructed from the next successful host read or explicit local choice; storage write failures prevent claiming a durable local choice.

## UI contract

- `workspace.preference(key)` returns a typed native value or null for an absent/reset/unrecognized value. `setPreference(key, value)` records an explicit choice; null resets it. Workspace publications notify existing `useSyncExternalStore` consumers on incoming changes.
- `workspace.selectedThemeID` applies the native `caribbeanSunset` default in memory. Theme selections call `setPreference("appearance.selectedThemeID", id)`. `HostState.preferences` exposes failed exchanges for the Settings error surface; exchange bookkeeping and default resolution are private.
- `workspace.choices()` supplies the picker. Codex retains upstream-hidden models in its catalog but shows them only when explicitly enabled. Claude uses generated native family IDs. A conversation's current model stays selectable when hidden, including unlisted Codex models and numbered Claude IDs. Reasoning levels follow native visibility; unlisted models retain their reported effort.
- Render `workspace.modelVisibilityChoices()` for settings: all discovered models plus `visible`, `hiddenUpstream`, capabilities and supported efforts. Call `setModelVisible(provider, id, visible)`; it canonicalizes Claude IDs and removes overrides when the choice matches the upstream default.
- Fresh-chat model/effort/Fast defaults seed after catalog discovery and the first successful replica read. Incoming defaults affect the next fresh chat, preserving open drafts. `chooseModel(choice)`, `chooseReasoning(effort)` and `chooseFastMode(enabled)` each record only their own native key when the action starts. Capability clamping stays local; a delayed acknowledgement cannot restamp the intent over a newer preference. Open-conversation selections apply locally at action start; each conversation sends one settings update at a time and retains only its latest waiting selection. A rejected superseded request leaves the newer choice intact; a rejected latest request restores the last confirmed settings without changing typed input. A provider with no shown models stays unavailable. Missing model settings are seeded even if typing or attaching created the draft first; content, directory and explicit selections survive.

## Native keys

| Key | Native meaning |
| --- | --- |
| `codex.modelVisibility`, `claude.modelVisibility` | Newline-separated `+id`/`-id` overrides; empty uses upstream defaults. Claude uses family IDs. |
| `reasoning.visibleLevels.codex`, `reasoning.visibleLevels.claude` | Comma-separated levels; default `low,medium,high,xhigh`. Empty hides all explicit levels; automatic remains available. |
| `codex.newChatModel` | Fixed model ID, or `last-selected`/absence to use `codex.defaultModelID`. |
| `codex.defaultModelID` | Last explicitly selected model across both providers; its ID determines the provider. |
| `codex.newChatReasoning` | Fixed `automatic` or `effort-<level>`, or `last-selected`. Legacy bare levels remain readable. |
| `codex.defaultReasoningSelection` | Last explicit reasoning; absent/unrecognized means high. Clamp to nearest supported visible level, lower on a tie, or automatic if none. |
| `codex.fastModeEnabled` | Last Fast choice, default false; applied only to models supporting Fast. |
| `appearance.selectedThemeID` | Native theme ID; absent/unrecognized uses Caribbean Sunset in memory. |

Pinned conversations are **not synced preferences** in native apps. Their per-host pin-name stores, drawer folds/filter, working directories, host/installation identities, notifications and haptics stay device-local. No Pinned replica is invented here. Drawer mode, account nicknames, transcription, automatic speech and realtime voice stay with native clients until a browser feature consumes them.

The initial Codex model comes from `NewChatDefaults.initialCodexModelID` through the existing native model generator (`bun scripts/generate-native-models.ts`), alongside the Claude catalog. Its generated `src/protocol/native-model-defaults.json` is consumed by the workspace and verified against the owning Swift source; do not add another fallback model constant.
