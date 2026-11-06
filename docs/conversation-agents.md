# Conversation agents

RemoteCoder keeps verified delegated conversations out of the ordinary drawer.
The subagents pill opens the conversation's roster, and each row opens the
agent's own conversation like any other thread. Unknown
relationships remain ordinary accessible conversations; neither XML messages,
working directories, titles nor `agentInitiated` establish ancestry.

## Owners and identities

`host-daemon-rs/src/agents/` translates two owners into one view:

- Native Codex: account-scoped thread ancestry and native turn/item pagination.
- External workers: the gateway-owned `agents::jobs::JobOwner`, shared with the
  installed `agent` client. Its records supply exact origin, current job,
  immutable result and delivery state; there is no launcher subprocess or registry.

An agent is a conversation and a job is one invocation. Continue creates a new
job without changing origin or provider scope. Exact identities include the
provider home; historical missing or conflicting evidence stays unknown.
[Delegated jobs](delegated-jobs.md) defines the execution and cutover contracts.

Claude Code's native Task subagents run inside their parent's turn and have no
conversation of their own, so the roster never lists them: they appear only as
the parent's Agent tool item. A Claude conversation's agents are its external
workers.

## Gateway interface

All operations use the existing authenticated, account-scoped WebSocket.

| Method | Required input | Result |
| --- | --- | --- |
| `conversation/agents/list` | `threadId` | `agents`, content `revision`, coverage `warnings` |
| `conversation/agents/classify` | up to 200 `threadIds` | verified `relations` keyed by thread, explicit `knownRoots`, coverage `warnings` |
| `conversation/agents/read` | root `threadId`, `agentId` | bounded text `messages`, `truncated`; read by the web bridge's agents panel and older apps |
| `conversation/agents/action` | root `threadId`, `agentId`, current `executionId`, `action`, `mutationId`, and text when required | owner admission receipt |

An agent exposes its stable ID, direct parent ID, owning provider thread,
provider/source, title/model, independently observed state, current execution,
account, available capabilities and `lastActiveAt`: the newest observed
activity in Unix seconds, or null when unknown. Codex reports the thread's
`updatedAt`; external jobs use their authoritative record's mutation time.
List and read do not resume execution. An unavailable provider or job store
produces explicit incomplete coverage. A conflicting historical continuation stays
visible as an unknown agent without execution controls; other verified agents
remain available. Retained continuation checkpoints and a single active runtime
job resolve current execution without ordering jobs by timestamps.

The list is capped at 512 agents. Native subtree expansion retains its existing
bounded reads. External descendant selection includes at most 32 native roots,
reads at most 256 jobs per root, deduplicates agents and reports omitted pages.
Exact canonical origins are checked before provider ancestry; scoped historical
uncertainty cannot silently become root. Classification reads the in-process
job owner and provider headers, never an external launcher or a second cache of
launcher projections. The whole list shares a two-second deadline; already
collected native headers survive optional execution-enrichment failure, with
unfinished state reported as unknown. A missing agent in an incomplete list
returns retryable `agentDiscoveryIncomplete`, not proof that it is gone.

Native child execution snapshots retain at most 16
roots and reuse terminal results for up to 30 seconds while the provider's
header revision and status match; active children are read each refresh.
The roster refreshes when it opens and when the app returns to the foreground
while it is open. The chat shows a subagents pill above the composer only when
the conversation has direct agents, and its number counts them
(`ConversationAgentRoster`). Each host's chat model
keeps the agents model of its eight most recent conversations in
`RecentConversationCache` and reads the lists of the top two unsettled drawer
conversations in the background when they have none cached, so a known pill appears with the transcript instead of after a
read. A conversation without a cached model has no summary until its first
read returns: the history list does not keep finished agent threads, so it
cannot count them. One model coalesces the selection probe, roster and warmer
into one refresh and reuses successful reads
for 15 seconds. Freshness controls reads, never elapsed-time notices or empty-state
labels. A roster Stop or a placement change bypasses freshness; a changed
set of child threads invalidates it. The last cancelled caller stops the RPC,
while other callers keep their shared read, including its bounded capacity
recovery through `GatewayRequestRecovery` within one RPC deadline. Confirmed
empty results remain visible during revalidation. The automatic
selection probe waits for the transcript tail and pauses outside `.active`; an
opened roster reads immediately. Failed refreshes retain old rows with an error, and an unread list
never displays No Agents. There is no polling timer. A
conversation without a successful read keeps the pill hidden. The pill floats
beside the jump-to-latest control; the transcript reserves its measured height
inside the latest turn's tail padding, so it never covers the last line and its
arrival never moves a top-anchored turn.

## Controls

| Operation | Owner |
| --- | --- |
| Native Codex Stop | Exact current `turn/interrupt` through `CodexStop`, the path the parent's Stop uses: it also interrupts the child's running descendants and ends their background terminals |
| Native follow-up | Ask Parent opens the nearest ancestor that accepts input and appends an explicit agent reference to its composer draft; it is hidden while no such ancestor is known |
| External Send (web bridge) | Gateway delivery to the exact current running job |
| External Continue (web bridge) | Durable new job in the same exact provider conversation |
| External Stop | Persisted job Stop, then the existing exact provider interrupt/cleanup owner |

The conversation's own Stop on a Codex parent, once the gateway confirms it
names the running turn, also interrupts every running native descendant,
ends the shell commands of each stopped thread, and fails visibly when it
cannot reach one of them; a refused Stop interrupts nothing
(`host-daemon-rs/AGENTS.md`, *Gateway RPCs*).

A stop receipt means requested, not completed. Terminal state requires provider
or fenced Stop evidence. Stale execution controls require refresh. Job admission
fingerprints and the single current-job invariant prevent a repeated Continue
from starting duplicate work. Unknown holds the slot until evidence or an
explicit Stop resolves it. Provider scope and read-only permissions remain fixed.

## History, activity and attention

Thread headers persist verified relationships alongside existing history state.
Classification happens while paging until enough root conversations are obtained,
with bounded continuation. The client retains up to 4,096 ancestry entries and
4 MiB of strings under its host/account history owner, clearing them on host
invalidation. Each refresh also discovers at most 200 retained unresolved rows
with a rotating scan. Definitive ancestry skips further RPCs; unchanged unknown
rows retry at doubling intervals from 30 seconds to ten minutes. A changed
unresolved header retries immediately. Metadata failures retain known
relationships and leave unclassified rows visible. An in-flight
refresh cannot overwrite a local create/remove/completion.

Titles prefer a local pin, then the explicit provider name, then preview text.
Native v2 `subAgentActivity` records and single-receiver collaboration calls
preserve the child identity in the parent's timeline, and tapping one opens the
child's conversation. The roster lists the conversation's direct agents, newest
first, under Active (working, waiting or unknown) and Done (completed,
interrupted or failed). Each agent's own agents appear in its own conversation's
roster. A row's context menu moves the agent or stops it.

`daemon/activeTurns` retains detailed execution inventory and adds `agentOwners`
for same-account root activity grouping. Each completed ownership observation
refreshes its positive links even when another thread remains unresolved.
`agentOwnersCoverage` is `complete` only when every current thread resolved;
partial, timed-out and expired observations remain `unavailable`. This map is display data, never
cross-account routing or execution authority. Live Activities count owning work;
descendant work does not make a parent turn directly steerable.

All child alerts, including questions, use the same verified ancestry owner.
The notification-coherence companion change owns final alert suppression and
presentation; this change supplies `is_agent_thread -> Result<bool>` so unavailable
ancestry cannot be mistaken for a root. Question state and exact command/file approval requests retain
their original identities and routes. Native Codex question tools are root-only;
external Codex workers can own questions because their sessions are ordinary
provider threads. Claude's durable question API remains unsupported. Notification
presentation is a separate owner and must not infer relationships from text.

Opening a child uses the ordinary conversation switch to its exact host and
account and retains its question cards. Its header reads "Subagent of" the parent,
and Back returns to the parent. Native Codex child conversations are read-only:
a bar with Ask Parent and Stop replaces the composer. External workers keep the
composer when the gateway accepts their input.
A native Codex child's completion does not wake an idle root: upstream delivers
it with `trigger_turn: false`, so the root reads it on its next turn. The gateway
forwards any turn the app-server starts itself, so a missing wake is upstream
policy, not a gateway defect.
Recorded cross-home children can be inspected and controlled from the parent;
their native descendants are inspected through that child account's own roster,
with this coverage boundary shown explicitly.
