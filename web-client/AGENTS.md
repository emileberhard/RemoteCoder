# RemoteCoder web client

The browser follows the native ownership vocabulary while keeping browser
transport, storage and rendering independent of Swift. `Workspace` is the
UI-facing coordinator; import types from their owners, without barrel files.

## State owners

All paths below are under `src/workspace/`.

| Module | Owns | Native counterpart |
| --- | --- | --- |
| `workspace.ts` | Selection and navigation fences, snapshots, paced publication, cross-owner flows | `ChatWorkspaceModel` plus the single browser window's selection |
| `host-services.ts` | Exact execution contexts, connection lifetime, history/catalog/account reads and feature transport | `ExecutionTargetRegistry`, `ChatTargetModel`, `HostServices`/`HostDirectories` |
| `host-versions.ts` | Independent physical-host version reads, three concurrent reads, retirement fencing | Gateway version refresh |
| `account-usage-store.ts` | One acknowledged account document for catalogs/rings, foreground refresh, Claude inventory and routing | `AccountDirectory`, `AccountUsagePresentation`, `ClaudeRouterAccounts` |
| `conversation-marks.ts`, `conversation-marks-store.ts` | Native predicates and exact-target durable marks replicas | `ConversationMarks`, `ConversationMarksReplica`/`Store` |
| `conversation-projects.ts` | Gateway-authoritative remote/repository/directory identities, bounded to loaded history | `ProjectIdentity` and project resolution |
| `conversation-activity.ts` | Managed/external activity coverage and delegated work rollup | `ConversationActivity` |
| `conversation-sidebar-model.ts` | Host metadata lifetimes, 32 question interests, held drawer ranks and projection memoization | Web coordinator for native sidebar inputs and question reads |
| `conversation-sidebar-projection.ts` | Pure rows, sections, ranking, filters, grouping and row caps | `ConversationSidebarProjection`/`Sections`/`Arrangement` |
| `conversation-drawer-preferences.ts` | Local folds/filter preferences and per-window reveals/query | `ConversationDrawerPreferences` plus window arrangement |
| `host-directories.ts`, `directory-picker-model.ts` | Physical-host favorites/home and a captured picker tree lifetime | `HostDirectories`, `DirectoryPickerViewModel`/`DirectoryTree` |
| `favorite-folder.ts`, `working-directory-path.ts` | Favorite titles/identities and home-relative paths | `FavoriteFolder`, directory path formatting |
| `context-window-usage.ts` | Last-request token usage and composer fill thresholds | `ContextWindowUsage` |
| `command-palette-search.ts`, `search-text.ts` | Folded token matching and stable ranking, shared drawer text folding | `CommandPaletteSearch` and native localized search |
| `conversation-sidebar-navigation.ts` | Visible neighbors and circular question-first attention traversal | `ConversationSidebarNavigation` |
| `conversation-header.ts` | Header decoding, native ancestry and drawer classification vocabulary | `ConversationHeader` |
| `conversation-agent-classifier.ts` | Coalesced, host-scoped ancestry reads in batches of 200; warnings preserve unresolved entries | `GatewayHistoryService.classifyAgents` |
| `conversation-sessions.ts` | Bounded session admission/eviction and serialized Claude subscription intent | Native `ConversationSessions`; unlike `RecentConversationCache`, retains owners rather than presentation copies |
| `conversation-session.ts` | One transcript, bounded rows, rendering revisions, history/observation barriers, activity, questions and queue replicas | `ConversationSession`/`ConversationState`, `HistoryWindow`, `QuestionReplica` |
| `composer-draft-store.ts` | Draft revisions, retention and browser persistence | `ComposerDraftStore` |
| `drawer-undo.ts` | Single-use action undo and its five-second deadline | `DrawerUndo`; web owns the deadline with the action |
| `turn-dispatcher.ts` | Send/preparation admission, captured dispatch, durable receipts and steer recovery | `TurnDispatcher.Submission` and session delivery state |
| `conversation-settings-selection.ts` | Model visibility/defaults and serialized picker updates/rollback | `ConversationSettingsSelection` |
| `synced-preference-exchange.ts` | Browser preference listeners and per-host exchange lifetime | `SyncedPreferenceExchange`; value merging stays in `src/preferences.ts` |
| `load-state.ts` | Unread/loading/failed/ready result vocabulary | Native explicit coverage states |

The split isolates existing invariants rather than introducing a shared mutable
workspace context or a second event pipeline. Concrete collaborators and narrow
callbacks connect the owners. A native actor/threading model is not replicated
on the browser's single event loop. Multiple browser windows or persistent
offline transcript caching would require revisiting selection and retention.

`src/protocol/agent-provider.ts` owns thread-provider classification;
`codexDesktopLink` lives beside `Address` in `protocol/boundary.ts`.

## Invariants

- Address keys preserve physical host/account identity; binding checks also
  require the exact enrollment generation. Retired connections cannot publish
  late events into replacement state.
- Only a session mutates its conversation. Replace row objects when changing
  content, delivery, Markdown or prefix authority; React may retain older rows.
- `activeTurnId` is a string for known running work, `null` for authoritative
  idle, and `undefined` for unknown. Unknown never authorizes a second turn.
- Subscribe/checkpoint receipts fence buffered events. Claude deltas require a
  contiguous live prefix; historical text alone grants no prefix authority.
  `rcClaudeLive.sequence` counts upstream events, which can emit zero or several
  notifications. Use it only against the fixed history checkpoint watermark;
  neither skipped nor repeated marker numbers prove a transport gap.
- Receipts and drafts are persisted before dispatch. Lost acknowledgments are
  uncertain and never automatically retried. A steer acknowledgment proves
  admission; only its canonical client identity confirms consumption.
- Acknowledgments clear only the captured draft revision. Existing conversation
  headers own their cwd; choosing another folder preserves the old draft.
- Marks remain unknown until an acknowledged full read. Pending changes persist
  before dispatch; acknowledgments remove only captured pending IDs. Retain
  newer per-thread revisions and the maximum read baseline. Pending marks are
  bounded at 2,000 with batches of 500; overflow rejects the new change.
  Undecodable saved marks move to one bounded quarantine slot before fresh
  reads; failed quarantine preserves the original and blocks dispatch.
- Completion, creation and recency timestamps have separate meanings. Missing
  time cannot become zero or the browser clock. Questions use canonical pending
  inventory and unseen request times; activity coverage never invents idle.
- Drawer mode syncs only `conversationDrawer.mode`; unread-only and folds stay
  local. Open drawers hold ranks until settlement marks change. Projects use
  gateway identities, group remote repositories across hosts, and show five
  rows initially. The Settled shelf starts folded, expands ten rows, then 25.
  Reveals reset on closed-to-open transitions, not focus recapture. Draft edits
  own their timestamps; unknown historical times sort after known ones.
- The UI calls `publishSeenCompletion()` only for a ready, visible and
  uncovered transcript. Per-thread Mark Read uses its last completion, while
  Mark All Read advances the wall-clock baseline. Batch settlement owns a
  single-use five-second undo that restores captured pin and unread state.
  Discard undo restores the saved draft and reopens its prior active location.
  Both return one Unix-millisecond `expiresAt`; expired undo throws.
- Directories/favorites belong to a physical host across account enrollments.
  Picker replacement cancels its reads and fences late folder selection.
  Preserve bounds: 100 favorite operations, 4,000 tree nodes, eight reads.
- Usage keeps absent windows distinct from zero remaining, deduplicates verified
  identities, and follows the exact selected context. Only native five-hour
  run-out projections produce an inner arc. Claude samples stale after 900 s.
  `HostServices` owns the account store; catalogs and rings derive from the same
  acknowledged document. Both providers expose explicit read coverage, separate
  from stale retained values. One foreground timer refreshes every 120 s; browser
  visibility owns start/stop, while uncertain preference readback survives it.
- Preferences merge newest per key. Picker updates serialize per conversation,
  and rollback uses confirmed settings without overwriting a newer selection.
- Live title notifications replace the exact host's cached and open headers;
  older reads cannot erase a title received while they waited. A prepared
  conversation gets its preview only when its first message is dispatched.
- History retains definitive agent ancestry across refreshes. The drawer uses
  `isDelegatedAgent` from `conversation-header.ts`: native subagents and known
  child relations stay with their parent; unresolved classifications remain
  visible. Classification warnings are separate from history-read failures.
  Automation-purpose threads use their own locally foldable Automations section
  before Settled, regardless of settlement state. Pinned automations appear only
  in Pinned; all automation rows show their purpose icon. Collapse/Expand All
  includes every foldable section in both drawer modes.
  Pins retain real headers within the 500-entry cap. Missing pins recover by
  exact context/thread, at most 32 reads per pass, with 30–600 s failure cooldown.
  Selected and live headers outrank pins; exact session reads enter the same
  header source used for selected row actions. One context-owned timer retries
  failed pins at the earliest cooldown and cancels on retirement or disposal.
  Overflow and unavailable headers report separate recovery coverage. History
  coverage is ready only when every requested provider list succeeds.
- Agent parent/child navigation belongs to `Workspace`. It commits after the
  child loads; failed or superseded nested opens preserve the committed route.
  Other selections clear it on commit. Check navigation fences again after
  loading, immediately before committing an open or return.
- Preserve the existing bounds: 24 contexts, six sessions, 240 rows/8 MiB per
  transcript, 500 history entries, 200 models, 32 drafts, 64 receipts and
  4 MiB/8192 buffered events. Live publication is paced at 80 ms.
- `dispose()` cancels owned listeners, timers, connections and conversation
  reads, flushes drafts and disposes rendering. Feature subscribers release
  their subscription on unmount.

Use the fake RPC/storage owners in `tests/fixtures/workspace.ts` for state tests.
Keep race and recovery assertions at `Workspace`'s public boundary; tests are
grouped by the owner whose contract they protect. Never send real prompts or
change real host preferences to verify a refactor.

Run `bun run format`, `bun run check`, `bun run typecheck`, `bun test` and
`bun run build` in this directory.

## UI

`src/ui/` mirrors the native `RemoteCoder/UI/` tree (`chat/`, `conversations/`,
`settings/`, `accounts/`, `agents/`, `automations/`, `directory-picker/`,
`design-system/`); `ui/chat-root.tsx` plays `ChatRootView` and `main.tsx` only
composes. Before adding or changing a surface, read its native view and reuse
its structure and vocabulary. Add browser-only affordances only for a browser
reason; native has no shell-command dialog, files browser or starter cards.

- Components read the workspace through `useWorkspace()`, `useSnapshot()` and
  `useRun()` from `ui/workspace-context.tsx`, the analogue of the SwiftUI
  environment. Do not pass the workspace as a prop or keep module globals.
  Two module stores predate this rule because their state must outlive the
  panel: feature-action receipts in `ui/remote-operations.tsx` and open
  automation drafts in `ui/automations/automations-panel.tsx`. Move them into
  a workspace owner rather than adding a third.
- Components own presentation state only: open dialogs, tabs and menus. Domain
  state and derived projections such as drawer sections, marks and usage come
  from the workspace owners above.
- Use the shared pieces in `ui/design-system/`: `Dialog`, `Menu`/`MenuItem`
  (popover API), `useAnchoredPopover`, `useContextMenu`/`ContextMenu` (right
  click and touch hold), `IconButton`, `HostPicker` and `ProviderMark`.
- Check layout at 1440, 402 and 360 CSS px with no horizontal overflow.
