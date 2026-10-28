# Delegated jobs

The gateway owns external delegated work on its host. Its installed `agent`
subcommand implements spawn, Continue, messaging, Stop, inspection and caller
capture. Shell command shims add no execution or persistence owner. Native
provider subagents and automation scheduling retain their existing owners.

## Identities and ownership

| Concept | Owner and lifetime |
| --- | --- |
| Agent | Exact provider/home/conversation and immutable origin; outlives jobs |
| Job | One explicit invocation, including automatic recovery and Claude background results |
| Execution binding | Exact input and provider turn; recovery preserves the job and conversation |
| Completion | Immutable final envelope and independent delivery obligation |

`agents::jobs::JobOwner` coordinates the lifecycle; `JobStore` commits private
records under `agent-jobs/v1/`. The gateway adapters use the existing Codex turn
ledger and Claude supervisor. They do not introduce another daemon, observer,
scheduler, provider transcript or account owner. `wire::agent_jobs` shares types
between the client and gateway; `agents::envelope` owns message formatting.

A caller supplies the JobId before admission. The same ID and request
fingerprint return the original job; changed content conflicts. Continue creates
a new JobId in the same exact conversation. At most one unresolved runtime job
holds its current-job slot. Origin and permission scope are immutable; an
explicit recipient change affects completion routing only. Missing historical
origin or provider scope stays unknown rather than becoming a root.

## Durable lifecycle

The cluster upgrade is a one-way job-store change. After an agent gains a parent
tag or a job gains cluster state, gateways at `aa96ebb` and earlier reject the
new fields or enum variants. Recover by rolling forward to a fixed next patch;
never restore a pre-upgrade snapshot that would discard accepted jobs.

| Store | Older gateway behavior |
|---|---|
| `agent-jobs/v1/agents` | Rejects parent-tag fields and `remoteParent` origin. Never-tagged roots omit new fields and retain their old shape. |
| `agent-jobs/v1/jobs` | Rejects cluster admission, parent or attention fields, remote origin/recipient and `waitingForProvider`. Ordinary untagged jobs omit absent new fields and retain their old shape until they use a new state. |
| `agent-jobs/v1/messages` | Rejects a non-null `remoteRecipient` or remote sender/recipient. Local messages omit the absent field and retain their old shape. |
| `agent-jobs/v1/remote-intents` and `cancel-fences` | Ignores these new directories; cannot enforce their accepted work or Stop fences. |
| `identity/v1`, job-store `.epoch`, Claude receipt `.epoch` | Ignores these new files; existing receipt records keep their prior format. |
| `cluster/v1` members and credentials | Ignores this new store and cannot authenticate peer credentials. |

Ignoring a new store does not make a downgrade safe: the older gateway cannot
reconcile its accepted intents, remote deliveries or cancellation fences.

Admission, exact conversation binding and ancestry commit before useful provider
work starts. The initial input has a deterministic UUID derived from the JobId.
A job moves through admitted, bound, dispatching, running or recovering, and a
terminal outcome. Before binding, an unavailable provider is represented by
`waitingForProvider` with its provider name. The driver retries with its existing
250 ms to 60 s bounded backoff, retains the job until readiness or explicit Stop,
and never blocks another provider's admission or execution. No provider effects
have started in this state. Unknown is nonterminal. `JobSummary.active` describes an owned nonterminal runtime
lifecycle, independently of its observed state. `agent list --active` uses that
fact; imported historical uncertainty remains unknown and is excluded from the
active list. Native provider activity retains its separate inventory owner.
Connection loss, process signals,
idleness and time alone never mean completion and never free its slot.

Stop is persisted before the provider interrupt. It works after the client is
gone and is applied before restart recovery. Stale controls cannot act on a
newer job. A receipt distinguishes accepting Stop from finishing the provider
fence and cleanup. A completed turn is finalized from its exact history and
never dispatched again. A positively failed transient provider turn may schedule
up to five successor attempts in the same job and exact conversation. Each failed
binding and outcome, retry deadline and deterministic successor input identity is
durable before dispatch. Exponential delays include jitter; restart preserves the
budget and deadline. Stop during backoff prevents the successor. A successor asks
the agent to continue from history and inspect existing effects; it never replays
the original task. Unknown acceptance or outcome remains reconciliation work,
never permission to create another attempt.

Finalization atomically commits outcome, bounded result, Git snapshot and the
immutable completion envelope. Claude provider cleanup follows that commit and
has its own durable pending phase; a crash cannot erase the candidate before
saving the result or silently strand cleanup. Continue waits for provider cleanup.
Actual HEAD, branch and working-tree dirtiness are read independently of the
model's report; unreadable Git state stays unknown.

## Provider evidence

Codex dispatch uses the matched native accepted-input contract. Custody and
binding are durable before effects and acknowledgement. Same-ID retries retain
the original binding and reject changed payloads; they cannot bypass planned
suspension, Stop or the exact restart owner. The existing turn ledger retains
pending custody even before the user item appears. Canonical acceptance, turn
inspection and exact-turn items determine progress and the final answer.
Typed capacity, rate-limit, server and statusless transport errors, and HTTP
408/429/5xx failures qualify for retry. Authentication, quota, refusal, Stop and untyped errors do not.
Claude requires its failed result's authoritative `api_error_status` on a normal
or execution-error result; a known terminal reason must identify an API error. Its preceding
process must have reached the existing EOF/reap fence, and exact session history
must remain available. The matched Codex and Claude terminal protocols expose no
Retry-After header, so the job owner cannot observe provider-specific header delays.

The native queue remains the sole Codex queue. Its replay uses the same stable
input identity, so a crash between native admission and queue-row removal does
not execute a second turn. The gateway reconciles queue attribution with native
positive receipts rather than inventing a queue ID for already-dispatched work.

A Claude job can span several turns. Its initial dispatch must be consumed and
an ordinary result must establish eligibility. Every top-level result, including
a task-notification result, replaces the candidate. Non-ambient background work
and pending recovery keep it open. Quiescence closes input, drains output and
reaps the process before the final result is frozen. A saved final candidate is
finalized after a crash; otherwise exact-session recovery supplies a generic
history-aware prompt. Code does not infer semantic completion from transcript
wording. Prepared recovery input keeps its UUID and payload across retry.

## Delivery

Completion uses `<JobId>:completion`; interim uncertainty notices have separate
IDs. A retry rereads the committed bytes. Neither an interim notice nor a manual
message can occupy the completion ID. Imported delivery IDs remain reserved even
when the old sender did not retain replayable payloads.

Execution and delivery are independent. Delivery can be pending, sending,
submitted, accepted, recorded, uncertain, blocked, unreachable, failed or
explicitly dismissed. Acceptance is not model consumption. An uncertain send
is reconciled against canonical provider evidence under the same ID; elapsed
time does not authorize a new send. Accepted/recorded obligations are settled.
A blocked or unreachable parent does not discard the child's saved result.

Claude's parent receiver owns one intent/receipt ledger for both gateway and
native terminal routes. A terminal parent uses a holder started directly by its
async SessionStart hook. The holder proves its exact CLI process and inbox,
keeps the process-only token in memory and forwards prepared frames. It executes
no worker. Missing holder/socket/token becomes unreachable; it never triggers
terminal takeover. Registration after a gateway restart reestablishes that same
live route. Gateway-owned parents use their existing supervisor and Stop fence.

An older parent record can lack a route while retaining a gateway-owned turn
selection. Only that exact persisted selection plus a freshly available native
inventory proving no external client may restore its gateway route. A native
route is never converted, and restoration preserves Stop and its generation.

## Sender message receipts

`JobStore` also owns manual sender receipts under `agent-jobs/v1/messages/`.
Admission freezes the proven sender, exact requested target, raw-request hash,
envelope and envelope hash before target lookup. Lookup failure is a durable
failed receipt. Resolution freezes the exact conversation and target job before
effects; a later sender job or selector match cannot rewrite them. Per-ID claims
serialize only duplicate requests, and are acquired before the shutdown gate.

Running-job delivery holds a `JobStore` execution read grant from exact-current-job
validation through native custody admission. Execution transitions and successor
admission take that job's write grant, so an old delivery cannot cross into a
new invocation. Stop records and signals independently; it never waits for a model
turn or acquires the admission write grant. The owned message admission task
retains its per-ID claim and shutdown read guard after caller cancellation until
provider custody settles and its sender receipt is updated. Only admission is
fenced; queued turn execution remains owned by the native receiver.

The same delivery ID, sender, target and raw text reuse the retained receipt;
changed input conflicts. Sending is persisted before the native receiver acts.
Submitted, accepted and recorded receipts are never replayed. New Codex input
steers a positively identified running turn using its expected turn ID and stable
message ID; runtime targets must match their exact job binding. A refused or
uncertain steer never falls through to a queued successor. Native idle
conversations retain the existing native queue path. Explicit retries
reconcile unresolved native delivery using its original ID and envelope; a
superseded frozen target stays uncertain instead of receiving fresh input in a
newer invocation. There is no message scheduler or second provider registry.
`agent/messages/read` and `agent receipt ID --json` inspect the stored receipt.
A scoped client may read only receipts from its exact proven sender conversation.

A message to the latest completed or failed job admits one explicit successor
through the existing Continue owner, with a JobId derived from the delivery ID.
The expected previous job is checked again atomically at storage admission.
Accepted means that successor was admitted, not that the model consumed it.
Automatic message continuation cannot clear Stop; an explicit Continue remains
the deliberate restart operation. Parent callbacks retain their existing native
or gateway receiver and never take over a terminal parent.

Message records share the store's 512 MiB cap and process lease. Admission reserves
record and mutation space. Submitted, accepted and recorded receipts release
unresolved capacity immediately; submitted proves transport custody, not provider
acceptance or consumption. A failed lookup with no resolved target is also a
terminal receipt because no effect was attempted. These immutable receipts retain
their identity, hashes and delivery evidence while payloads expire after 30 days.
Blocked, unreachable, provider-side failures with a resolved target, and uncertain
receipts remain pinned for exact-ID reconciliation. Diagnostics are bounded, and
capacity refusal names the retained obligations that prevent admission. The
existing provider receiver owns reconciliation and Stop fences. Canonical native
selectors are `claude_UUID` for Claude and a bare UUID for Codex; `codex:UUID`
also selects Codex. A raw Claude session UUID never substitutes for its canonical
thread ID. Cross-host operations use the exact owning member and its pinned
cluster link; lookup failures never guess a host or fall back to an SSH send.

## Caller authority and read-only work

Caller capture checks kernel PID/birth ancestry against actual provider-owned
tool processes. One lazy walker stops at the first proven Codex tool root or
Claude session owner after checking its live birth identity and every intervening
parent link. Unrelated launcher
ancestors above that owner may be unreadable and carry no additional authority.
Without a proven owner, the complete walk retains its existing fail-closed
behavior. An unreadable caller, intervening process or owner retains its exact
error. This fixes the SSH-launched Claude caller failure present in 3.74.0 and
`aa96ebb`: their eager walk could reach a privileged SSH launcher before checking
the valid Claude owner. It never trusts `AGENT_ID`, provider environment IDs or tmux's
global environment. Capture briefly rechecks an unpublished process entry,
without changing the requested identity. The ephemeral captured handle is
revalidated before every mutation; detached work must pass it explicitly and
fails actionably when its owner is gone. Deliberate standalone work selects
operator intent explicitly.

The JobOwner owns one Unix coordination listener for the gateway lifetime,
namespaced by its actual store root. It verifies the kernel peer and current
provider process, then resolves the conversation's current job from the Agent
record. Jobs and native continuations share that endpoint; finishing a job does
not remove a conversation's tool route. Self reads, parent messaging, title
changes and reads of the caller's own message receipts are the only operations.
A process with no registered job is refused.

Older provider environments retain a per-job socket path. Only ENOENT for the
recognized old path can try the canonical local scoped listener, carrying the
old socket explicitly. Before any action, that listener proves the old path
belongs to a retained job in its own store and to the actual caller's exact
conversation. This prevents an isolated instance from falling into the default
host. Existing, refused and denied routes never try another endpoint. No scoped
failure falls back to the operator bearer. Remove this narrow migration once
retained provider environments no longer name per-job sockets. Full-access clients use the existing
credential owner for other operations. This preserves the current same-user
trust boundary, not a hostile same-UID security sandbox.

Local and remote starts share caller proof and scope inheritance. An unrestricted
native caller uses the existing full-access coordination contract; a managed
read-only caller's child retains that root and cannot widen its scope on a hop.
The receiver validates target paths inside that root. Parent tags grant no scope.

Codex read-only uses its native sandbox, core-only tool environment and disabled
inherited MCP/hooks/apps/plugins. Claude read-only preserves the limited tool
set and Bash policy but is honestly tool-limited, not an enforced sandbox.
Continue cannot escalate a conversation's scope or switch its provider home.

## Bounds and shutdown

The store owns an exclusive process lease and fsynced atomic files. Its 512 MiB
budget counts retained and temporary data; admission reserves future job,
result and provider-evidence space. Prompt, encoded result, job and provider
evidence bounds are 512 KiB, 256 KiB, 1 MiB and 1 MiB respectively. Up to 256
unsettled runtime jobs are admitted only while reservations fit. Settled payloads
can expire after 30 days or under pressure, preserving identities and hashes.
Unknown work and unresolved deliveries are not silently evicted.

The driver uses coalesced provider-change hints and bounded reconciliation.
Healthy running work is not polled for completion; retryable failures and
unsettled delivery use bounded backoff. Existing gateway admission and shutdown
own the drain. In-flight job operations quiesce before provider suspension;
`prepare-shutdown` must fail when its preservation contract cannot be met.
Normal restart recovery and ordinary progress use the same job owner. While a
Codex turn's activity is not yet observable, such as pending restart recovery
or an unbootstrapped inventory, reads report the job unknown and the driver
retries without an interim notice.

## Historical cutover

Private operations freeze old admission, drain existing writers and callbacks,
then convert immutable copied evidence once. The candidate gateway reads the
staged canonical records before activation. Unknown outcomes, timestamps,
ancestry and delivery certainty remain unknown. No runtime legacy reader,
second registry or import RPC remains. Provider history and rollback snapshots
are retained data, not an alternative execution path.

Explicit Continue can start a new job after an imported Claude record whose old
outcome remains unknown. Admission requires the recorded exact conversation and
provider home, retained permission scope, authoritative native model and working
directory, completed provider recovery, no gateway active turn and a successful
external-client inventory showing no other owner. Missing evidence refuses
admission. The old job and immutable ancestry remain unchanged. Historical
settings are resolved for the new invocation from native history; standard mode
is the new invocation default unless explicitly overridden, rather than an
assertion about the old run's speed setting.

## Retry-state rollout and rollback

A nonempty `providerRetries` record and the `retryWaiting` execution state require
a gateway that understands this format. Once retries have written these records,
keep a matching gateway reader during rollback; older gateways reject them.
Never restore an older store snapshot over jobs admitted or changed afterwards.

## Host identity

Authorized `/health` includes top-level `hostId` and `incarnation`, each a UUID.
The host UUID persists at `identity/v1` across restarts, address changes and key
rotation. The incarnation fences the job store and delivery receipts. Each store
has a random `.epoch` created once: `agent-jobs/v1/.epoch` and the configured
Claude home's `remotecoder-history/.epoch`. Startup rotates the incarnation when
an epoch is missing or differs from the retained identity record. An inconsistent
job store also invalidates it before startup fails. Remote input must match the
recipient's current incarnation before native delivery custody can have effects.

Restoring bytes in place within the same epoch is not automatically detectable.
After restoring backups, run `cluster reset-identity` before rejoining members.
A full disk clone requires that same reset. Existing membership is removed before
a new identity joins. Identity and epoch files use `storage/private_state` and
never derive identity from a hostname, address or authentication key.

## Cluster v1 contract

`wire::cluster` owns the versioned member, intent, cancel-fence, caller-authority
and protocol records. Remote provenance is `Origin::RemoteParent`; each Agent
has a separate nullable `parent` tag `{hostId, threadId}`. A per-job remote
recipient carries `hostId`, `incarnation` and the exact provider conversation.
Membership credentials prove `Grant::Peer {host, membership, digest}`; request
fields cannot choose that principal. Membership removal retains its tombstone.

Other modules use `Gateway::cluster_link().await` to obtain an `Arc<Link>`.
`Link::members().await` returns public `MemberView` rows; `host` is the UUID
(serialized as `hostId`), and `name` is its alias. `Link::call(host, method,
params).await` uses one pooled, pinned TLS connection per membership. A
`LinkError` retains `class` and `transmitted`; only `transmitted == false`
proves that the requested method was never sent. `Gateway::host_identity().await`
returns `HostIdentity {host_id, incarnation}`.

`cluster/list` returns `self {hostId,name,incarnation,version,protocol}` and
`members [{hostId,name,membership,state,reachability,version,protocol,load,routes}]`.
Reachability has `state`, `since` and nullable `lastSeenAt`, with RFC 3339 times.
Listing probes active members concurrently with a two-second hello deadline,
updates reachability and preserves the last successful `lastSeenAt`. A successful
hello resets that member's delivery backoff. There is no background polling.
Removed tombstones stay private. Load, when available, is
`{cpuPercent,memoryPressure,activeAgents}`. Every job read/list and conversation
agent row adds `ownerHostId`, `parent` and `recipient`. Parent references always
use `{hostId,threadId}`. A cross-host conversation-agent query uses
`{parent:{hostId,threadId}}`; omitted `hostId` means this host. The parent's own
host adds `kind:"remote_intent"` stub rows with `jobId`, `ownerHostId`,
`intentState`, `parent`, `lastActiveAt` in epoch seconds and string `title`. An owner's real row
replaces its stub by `(ownerHostId,jobId)`.

Cluster-wide CLI reads include `coverage [{hostId,state,since?,staleThrough?}]`,
where state is `ok`, `unreachable`, `unsupported` or `refused`.
`agent/parent/set {agent:{hostId,threadId},parent:{hostId,threadId}|null}` goes to
the agent's owner and returns the updated row. A cycle is `usage`; an unreachable
parent-chain hop is `unavailable`. Provenance and authority never change with the
tag. The caller starting a new turn receives its result; moving a tag transfers
unaccepted results to its new parent or to the user when promoted.

A move changes the parent tag immediately. Positively unaccepted completion
obligations follow the current tag. An uncertain send retains its frozen old
receiver and delivery identity until reconciliation proves non-acceptance; it
then follows the current tag. If that reconciliation cannot finish because the
old member was removed or its 24-hour receiver window expires, the delivery
stays uncertain and visible to the user with its saved result. It is never
readdressed to another parent or silently discarded. A promoted result remains
available to the user. Unknown native acceptance never authorizes another turn.

The authorized health response includes top-level `hostId` and `incarnation`
UUID strings. Operator key rotation changes neither. Cluster protocol 1 uses
`cluster/issue`, `cluster/accept` and `cluster/remove` with a membership UUID;
only a local operator can mutate membership. Each side stores its issued digest,
the other side's credential, direct `wss` routes and SPKI pin. Issue is idempotent
per membership. Removal revokes existing sockets, retains a tombstone, stops work
admitted by that membership and retains results. An unreachable half stays
`remove_pending`. Joining again requires a new membership UUID.

`agent/jobs/admit` returns the normal admission receipt plus `protocol`,
`ownerHostId`, `jobId`, `address`, typed `state` and `incarnation`. `address` is
null until a provider binds the exact conversation. The stable admission key is
`(ownerHostId, jobId)`. The parent's host saves a bounded RemoteIntent before
sending admission bytes. Uncertain admissions retry the same identity and
fingerprint. A definitive refusal closes the intent; a changed incarnation
makes it unknown. Stop is durable before transport, and a CancelFence on the
receiver prevents a delayed admission from starting native work. A confirmed
Stop closes transport retries without removing its retained receipt.

The execution driver owns provider custody and local delivery. The cluster
driver owns member network work, with independent member backoff, at most 64
members doing network work concurrently and at most 64 delivery operations per
member. Each member link serializes its socket. A slow member cannot block local
launches or another member. `cluster/hello` wakes that member's driver and resets
its backoff. Both drivers belong to the gateway lifecycle and resume durable
records after a planned restart. There is no separate remote outbox.
Accepting membership wakes the driver, whose new member worker sends hello and
retries an unavailable member with its bounded backoff.

`list_agents` defaults to the cluster; `--local` narrows it. Every fan-out result
includes per-host `coverage`, and `--cursor` resumes each host independently.
Bare IDs resolve locally first and then uniquely across members. Native session
inventory comes from the sessions projection; unavailable inventory remains an
error. Catalog schema 2 rebuilds provisional catalogs with UUID-scoped session
keys. Incoming peer searches stay local; cluster coverage retains each link's
unreachable, unsupported or refused state. Unknown native activity is excluded
from `--active`. Native conversations
can be inspected, messaged, stopped, adopted, moved or promoted. Continue refuses
with `unsupported` when native permission evidence is unavailable; it does not
invent a JobSpec from a thread header.

Claude child sidecars (`claude:<parent UUID>:<child ID>`) are listed and read
through sessions. They have no resumable provider thread, so lifecycle operations
return unsupported (exit 7). Unrecognized conversation IDs never route to Codex.

Every agent row includes `ownerHostId`, the current nullable `parent` address
and its turn's `recipient`. Native ancestry stays immutable provenance. Thread
headers with a current tag or native parent expose `parent: {hostId, threadId} | null`; untagged native roots preserve their provider response bytes. Relation JSON exposes
`parentHostID` and `parentThreadId`. Promotion classifies the conversation as a
root. Parent changes invalidate ancestry and agent-view caches. Remote-intent
stub rows use `lastActiveAt` in epoch seconds, matching real rows, and every
conversation-agent page carries a revision derived from its final rows.

`cluster add SSH_HOST` enrolls every pair through each host's operator SSH route,
skips active pairs and reports per-pair JSON. Partial enrollment exits 5;
rerunning finishes existing membership IDs. Peer credentials cannot issue or
accept another membership. `cluster list --json` reports reachability, version,
protocol and measured CPU percentage, typed memory pressure and active agents.

A failed first `hello` lookup returns unavailable (exit 5) before an immutable
admission or intent exists; nothing is queued for later transmission. Abandoned
applies after a complete immutable admission exists but cannot be sent. Admission
uses one typed operation, `start(JobSpec)` or `continue(ContinueParams)`, through
`agent/jobs/admit`; its fingerprint includes the operation kind and full payload.
Reusing a job ID with different admission inputs is conflict (exit 8), including
changing Start into Continue.

## Indexed lifecycle work

JobStore owns the derived conversation, parent, current-head, active-agent,
ordered-page, reversed job-ID suffix and per-member pending-work indexes. Every persisted agent, job or
intent transition publishes its index change in the same store critical section;
startup rebuilds the indexes from retained records. Parent moves and promotions
update the parent index and wake only members with affected pending deliveries.
Ambiguous continuation branches retain an unresolved head. Ordinary head reads do
not walk the continuation history. Job suffix resolution uses an ordered reversed-ID
range and returns at most two matches, keeping ambiguity explicit.

Network workers subscribe to their member's coalesced watch and read only that
member's pending jobs and intents. Delivery attempts that change only the retry
receipt do not wake themselves and bypass backoff. Each watch retains one revision;
record sets are derived from the retained store. New work has a 512 MiB storage
admission budget; runtime reservations and unconfirmed remote intents each cap at
256. Settled payloads expire after 30 days, but job records, receipt metadata and
their indexes have no count-based retention or eviction policy. Their size grows
with retained history even after payload expiry; record retention is separate
follow-up work.

Members owns one parsed immutable snapshot. Authentication and selector reads use
its indexes without disk reads. Its atomic file transaction serializes mutations;
a successful write swaps the snapshot and wakes membership observers. External
membership-file edits are unsupported while the gateway is running.

The existing JobStore persistence mutex still spans accounting and disk I/O.
The per-member Link socket mutex still spans one request/response exchange, with
a ten-second deadline, so one slow request can delay other requests to that peer.
These ordering boundaries remain explicit follow-up work; other peers proceed
independently. Native session inventory freshness and ingestion remain owned by
sessions, including its pending event-driven single-writer repair.
