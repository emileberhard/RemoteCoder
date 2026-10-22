# Automation management

RemoteCoder can manage an operator's existing automation service through the
authenticated gateway. The service continues scheduling and observing runs
independently of the app. Its private SQLite database owns live definitions,
immutable definition history, source checkpoints, and run receipts.

## Ownership

`host/info` reports physical `hostname` and `automationsAuthority`. Clients use
that capability to select the authority independently of conversation selection;
a missing capability or unavailable host never authorizes a guessed substitute.
The private host-profile document configures the gateway's authority; public
defaults configure none. The automation service itself is an optional operator
integration, outside the basic chat path.

The Python service in the configs repository validates definitions, admits
events/timers, records versions, and reconciles execution. For definition management,
the Rust gateway is a bounded transport adapter to its private Unix-socket `POST /rpc` API. Agent and
command execution retain their existing gateway-owned paths. The app uses the
configured authority's physical-host services independently of the selected conversation target.

No provider session or account selection owns the definition inventory. An
automation's saved execution configuration determines which exact gateway
host is used for its runs. An unavailable authority remains unavailable;
neither another host nor an empty local list replaces that authority.

## Definition history

Each meaningful save appends a complete normalized definition snapshot and
updates the current projection in one SQLite transaction. Prompt text, enabled
state, trigger configuration, execution settings, and removal belong to the
snapshot. Scheduling/checkpoint movement does not create a version.

Creation, editing, pause/resume, removal, and restoration use the same service
mutation boundary. Removal appends a tombstone and preserves history. Restoration
validates an earlier snapshot and saves it as a new revision, with its source
revision recorded. The restore preview defaults to paused.

The current numeric revision guards edits. A stale base produces a conflict with
the current revision; the editor retains its draft for explicit reconciliation.
Stable request IDs make an acknowledgement-lost retry return the committed
result rather than create another revision. Reusing an ID with different input
is rejected.

Older live heads become honest migration baselines at their existing revision
numbers. The service does not invent the missing changes before those baselines.
Legacy run snapshots and the configs Git history remain prior evidence.

## Gateway contract

The host-owned methods are `automations/status`, `automations/list`,
`automations/show`, `automations/set`, `automations/remove`,
`automations/history`, `automations/restore`, and `automations/run`.

Public top-level parameters use the gateway's camelCase spelling, including
`requestId`, `expectedRevision`, `targetRevision`, and `replaceDefinition`. The adapter maps those to
the service's snake_case request keys. Definition/event JSON keeps its service
shape so fields are preserved rather than translated by a second domain model.
The result preserves the service envelope: `{ok, data, health}` or
`{ok: false, error, health}`. Read revision metadata through history and retrieve
one complete snapshot through show with `targetRevision`.

Definition writes require stable request IDs and expected revisions. Run controls
retain their explicit exact-run forms. Dispatch classification distinguishes
reads, definition changes, new execution admissions, and controls for existing
work. Definition management does not borrow the selected chat host's admission
policy; execution remains subject to the service's saved target and established
execution boundary.

The app sends complete edited bodies with `replaceDefinition: true` for saves
and restores. Omitted optional fields then use model defaults rather than
reappearing from the previous definition. CLI partial patches retain their
existing merge behavior.

The adapter is available on the configured authority and uses the private control socket, with
the service state-directory override where configured. It does not launch a
service, manipulate files through a shell, read SQLite directly, or open a new
network listener. It bounds requests, responses, and elapsed operation time.
Authenticated gateway attribution is supplied in a service-owned header; no
human author is guessed.

Transport errors distinguish an unavailable connection from an unknown mutation
acknowledgement. The latter carries the original request ID. The app retains the
original input for retry/reconciliation instead of generating a new submission.
Structured service validation/conflict errors and health stay visible.

## App behavior

Automation-purpose conversations appear in a collapsible Automations section
in the native and browser drawers, after Chats/projects and before Settled.
Their rows carry an automation symbol. Explicitly pinned automations appear
once in Pinned and retain the symbol. Automation membership takes precedence
over settlement; search reveals matching rows in folded sections. The section
starts expanded and its fold is a device preference, like Pinned. The Mac Quick
Entry panel keeps unpinned automation runs out of its limited recents; explicitly
pinned automations remain eligible. Collapse and Expand All change the currently
displayed section types, including projects only while in Projects mode.

New service-created conversations receive the existing `automation` purpose
mark. An automation targeting an exact existing conversation preserves that
conversation's purpose: a scheduled follow-up alone does not make it a dedicated
automation chat. When deliberately adopting an existing conversation as a
dedicated automation assistant, set its purpose explicitly through
`conversation/marks/update` (`setPurpose`, `purpose: "automation"`). The gateway
marks document owns this classification; neither client guesses it from titles,
message content or schedules. Automation run history remains another entry
point to the exact recorded conversation.

Automations is reachable through the existing app navigation. Inventory shows
active/paused/removed state, expiry or completion, trigger, next due time where applicable, and last
result. A failed run does not mean the automation is paused. Event triggers do
not receive an invented next due time.

The editor supports the existing agent/command actions and trigger forms. Saved
fields that are unavailable or not edited remain intact. The service owns
validation, iMessage resolution, and schedule semantics; the app reuses host
directories and model catalogs rather than adding another backend.

Revision history provides complete snapshots, field/prompt comparisons, and
restore previews. Run details show their admitted definition and durable
outcome, including queued, uncertain, filtered, expired, coalesced, and cancelled
states. Opening a conversation uses its recorded host and thread identity.
Command output is paged through the existing run-detail API.

Refresh on opening, foreground, reconnect, manual refresh, and mutation. Active
run observation belongs to its visible screen and stops on background/teardown.
Retain the last successful inventory as stale on disconnect, preserve unsaved
drafts in a workspace-owned Settings store that survives chat-window closure,
and disable remote actions while offline. There is no offline mutation
queue. Decode and compare large snapshot content off the main actor.

## Scheduling and run history

New saved-definition runs retain their exact admitted revision and definition
snapshot. Later edits do not replace the admitted action configuration. Current
removal, pause, and expiry gates retain their existing dispatch behavior.
Pausing holds queued automatic runs; active execution requires explicit
cancellation. Removing cancels queued work while retaining running/uncertain
receipts.

One-time invocations have their own snapshot and revision zero, without a saved
definition history entry. Legacy receipts retain their coverage limits. Runtime
session/continuation resolution stays in execution context and receipts, separate
from the admitted snapshot.

The service retains its existing coalescing, queue/skip/steer, source checkpoints,
delivery uncertainty, and restart recovery contracts. Durable admission can be
deduplicated; this does not promise exactly-once external side effects.

## Execution recovery

The service asks the execution gateway `turn/inspect` with the exact
`{threadId, turnId}`. The authenticated connection selects the host; both providers
use their host-default profiles. This read does not admit new work or alter
provider execution.

The response preserves `threadId` and the requested `turnId`, and names the
resolved `executionTurnId`. `activity` is `running`, `recovering`, `inactive`, or
`unknown`. Independently, `outcome` is `{state: "known", status, error}` or
`{state: "unknown", reason}`. Known terminal statuses are `completed`, `failed`,
and `interrupted`. Error details are bounded, and missing historical error
details remain absent rather than being reconstructed from transcript text.

Claude reads its existing notification-fed identity records, which retain
terminal errors and explicit planned-restart continuation links. Codex reads
at most ten descending pages of fifty turn metadata entries, requiring an exact
match and recorded completion timestamp. Presentation status alone, missing
history, and exhausted lookup never establish a terminal result. Cold Claude
index reads are capped at 64 MiB; continuation traversal is capped at sixteen
turns. Inspection has a fifteen-second budget and unavailable evidence remains
unknown. Provider recovery and live activity override stale terminal records.
Codex also checks the persisted runtime restart journal before reporting
inactivity. Suspension notifications do not settle that journal's recovery task.
A stale Claude pending marker after journal recovery is unknown evidence, not
permanent recovery. An unavailable conversation index does not keep unrelated
Claude recovery pending.
An interrupted Claude identity without a recorded recovery disposition remains
unknown: legacy captures cannot prove whether an unrecorded continuation ran.

Running/recovering or unknown activity holds automation ordering. Confirmed
inactivity with unknown outcome releases ordering while retaining an uncertain
run. Steered input retains its existing delivered/uncertain semantics; a shared
turn's success does not prove that an individual event was handled. A planned
interruption stays recoverable while the gateway resumes the recorded execution.

Output is read separately through `thread/items/list` for the resolved exact
turn, in descending pages. Recovery retains at most a 256 KiB UTF-8 assistant
text tail, with at most ten pages and a fifteen-second budget. Complete, tail,
partial, and unavailable coverage remain distinct. An unavailable read does not
erase a known outcome; weaker output recovery preserves a fuller saved copy.
Receipts retain the original turn, resolved execution turn, normalized refusal
reason, and any original refused/fallback identities. Recovery does not initiate
a newly discovered refusal fallback.

Install and verify the service's fail-closed recovery before activating the
gateway release. This prevents the previous observer from settling planned
deployment interruptions as final failures. A missing capability or failed read
retains uncertainty and holds ordering during the bridge interval. Deploy and
verify the gateway capability on both hosts, then exercise live restart recovery.
The service never selects the old reconstruction path or redispatches the agent.

## Migration and operations

The configs installer requires explicit ownership cutover for legacy unmarked
state. Migration reconciles the last manifest-owned definitions once under the
source lock, preserves database-only definitions and runtime state, and commits
the authority marker with the final changes. Database-owned restarts and config
sync do not reload templates or re-enable removed/paused definitions.

Git versions service/job code and optional import templates. Applying a prompt
file/template explicitly creates a definition revision; editing the file alone
does not change the live definition after cutover. Definition restoration does
not roll back arbitrary tools, workspace files, job code, or conversation context.

Use the configs automation CLI for exports, imports, online SQLite backups, and
service operations. Snapshot exports are not complete database recovery images.
A complete export gathers bounded pages against one history generation and
rejects concurrent definition changes. Import uses exported head revisions and
skips removed definitions and service-managed sources. The cutover installer
takes a private online backup before stopping the old service. It restores the
prior job only before ownership commits; after commitment it retains the new
database-aware release and reloads normal launch arguments.
A rollback after cutover must retain the current database and use an ownership-
aware release. Recovering an older database requires reconciling actual gateway
executions rather than replaying historical receipts.

See the configs automation README/skill for the canonical installer, backup,
health, and recovery procedures. [System architecture](system-architecture.md)
owns host/session relationships, and [repository model](repository-model.md)
owns main branches and release delivery.
