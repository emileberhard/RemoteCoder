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

Admission, exact conversation binding and ancestry commit before useful provider
work starts. The initial input has a deterministic UUID derived from the JobId.
A job moves through admitted, bound, dispatching, running or recovering, and a
terminal outcome. Unknown is nonterminal. Connection loss, process signals,
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

## Caller authority and read-only work

Caller capture checks kernel PID/birth ancestry against actual provider-owned
tool processes. It never trusts `AGENT_ID`, provider environment IDs or tmux's
global environment. Capture briefly rechecks an unpublished process entry,
without changing the requested identity. The ephemeral captured handle is
revalidated before every mutation; detached work must pass it explicitly and
fails actionably when its owner is gone. Deliberate standalone work selects
operator intent explicitly.

A job's Unix coordination socket verifies its actual peer and permits only
self read, parent messaging and title changes. An inherited or failed socket
never falls back to the operator bearer. Full-access clients use the existing
credential owner for other operations. This preserves the current same-user
trust boundary, not a hostile same-UID security sandbox.

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
