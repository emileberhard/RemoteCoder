# Conversation agents

RemoteCoder keeps verified delegated conversations out of the ordinary drawer.
The conversation's Agents sheet owns inspection and execution controls. Unknown
relationships remain ordinary accessible conversations; neither XML messages,
working directories, titles nor `agentInitiated` establish ancestry.

## Owners and identities

`host-daemon-rs/src/agents/` translates three owners into one view:

- Native Codex: account-scoped thread ancestry and native turn/item pagination.
- Native Claude: attributed complete messages, Agent tool results, task lifecycle,
  and the root session's `subagents` transcripts. Shell tasks are excluded.
- External workers: the gateway-owned `agents::jobs::JobOwner`, shared with the
  installed `agent` client. Its records supply exact origin, current job,
  immutable result and delivery state; there is no launcher subprocess or registry.

An agent is a conversation and a job is one invocation. Continue creates a new
job without changing origin or provider scope. Exact identities include the
provider home; historical missing or conflicting evidence stays unknown.
[Delegated jobs](delegated-jobs.md) defines the execution and cutover contracts.

Claude task, invocation and agent IDs remain distinct. Its projection stores
bounded terminal evidence under the owning Claude home, with atomic writes and a
runtime-generation fence. Reloading history does not prove a live execution.
Native child text stays out of the parent's transcript. A child known only from
its `subagents` transcript, such as one beyond the root session's bounded tail,
takes its title, parent and model from Claude Code's `agent-<id>.meta.json`
beside it. It is completed when its final event is an `end_turn` assistant
message, stopped when the meta file records `stoppedByUser`, and otherwise
unknown. `stoppedByUser` also settles a child the root session already knows
whose state is working, waiting or unknown, so a Stop reads as stopped rather
than unknown after its runtime ends.

## Gateway interface

All operations use the existing authenticated, account-scoped WebSocket.

| Method | Required input | Result |
| --- | --- | --- |
| `conversation/agents/list` | `threadId` | `agents`, content `revision`, coverage `warnings` |
| `conversation/agents/classify` | up to 200 `threadIds` | verified `relations` keyed by thread, explicit `knownRoots`, coverage `warnings` |
| `conversation/agents/read` | root `threadId`, `agentId` | bounded text `messages`, `truncated` |
| `conversation/agents/action` | root `threadId`, `agentId`, current `executionId`, `action`, `mutationId`, and text when required | owner admission receipt |

An agent exposes its stable ID, direct parent ID, owning provider thread,
provider/source, title/model, independently observed state, current execution,
account, available capabilities and `lastActiveAt`: the newest observed
activity in Unix seconds, or null when unknown. Codex reports the thread's
`updatedAt`; Claude the newer of its latest event and its `subagents/`
transcript write; external jobs use their authoritative record's mutation time.
List and read do not resume execution. An unavailable provider or job store
produces explicit incomplete coverage.

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
header revision and status match; active children are read each refresh. Claude history projections
retain at most 16 roots and recheck bounded transcript file revisions.
Transcript tails and messages have byte/count limits.
The sheet refreshes only while visible and foregrounded; closed panels do not
poll child output. Detail output refresh is explicit. The chat shows a subagents
pill above the composer only when the list has agents. Its number counts the
recent agents: those working or waiting, or active within the last 12 hours
(`ConversationAgentsModel.recentWindow`), plus the ancestors that connect them.
An agent without a known activity time is not counted but stays listed. With
no recent agent the pill reads "Subagents" without a number, because it is the
only way into the sheet. Each host's chat model
keeps the agents model of its eight most recent conversations in
`RecentConversationCache` and reads the lists of the top two unsettled drawer
conversations in the background when they have none cached, so a known pill appears with the transcript instead of after a
read. A conversation without a cached model has no summary until its first
read returns: the history list does not keep finished agent threads, so it
cannot count them. Every successful read recomputes the recency split, so agents age
out at the next refresh without a timer. One model coalesces the selection probe,
Mac inspector, iOS sheet and warmer into one refresh and reuses successful reads
for 15 seconds. Freshness controls reads, never elapsed-time notices or empty-state
labels. Explicit refresh and agent actions bypass freshness; a changed
set of child threads invalidates it. The last cancelled caller stops the RPC,
while other callers keep their shared read, including its bounded capacity
recovery through `GatewayRequestRecovery` within one RPC deadline. Confirmed
empty results remain visible during revalidation. The automatic
selection probe waits for the transcript tail and pauses outside `.active`; explicit details can read
immediately. Failed refreshes retain old rows with an error, and an unread list
never displays No Agents. There is no polling timer. A
conversation without a successful read keeps the pill hidden. The pill floats
beside the jump-to-latest control; the transcript reserves its measured height
inside the latest turn's tail padding, so it never covers the last line and its
arrival never moves a top-anchored turn.

## Controls

| Operation | Owner |
| --- | --- |
| Native Codex Stop | Exact current `turn/interrupt` through `CodexStop`, the path the parent's Stop uses: it also interrupts the child's running descendants and ends their background terminals |
| Native Claude Stop | Installed CLI `stop_task`, checked against runtime, task and execution revision |
| Native follow-up | Adds an explicit agent reference to the parent's composer draft |
| External Send | Gateway delivery to the exact current running job |
| External Continue | Durable new job in the same exact provider conversation |
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

Native Claude Stop was verified against CLI 2.1.280 with a disposable background
agent: the selected task emitted `killed`, then `stopped`, and disappeared from
the live background set. Source/docs alone are insufficient to add a control.

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
Native v2 `subAgentActivity` records preserve the child identity in the timeline.
The Agents sheet lists the pill's recent agents first, nested, and collapses
every other agent under Earlier, which forms its own tree.

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

Opening a child selects its exact host and account and retains its question cards.
Native Codex child conversations are read-only and point back to their parent.
A native Codex child's completion does not wake an idle root: upstream delivers
it with `trigger_turn: false`, so the root reads it on its next turn. The gateway
forwards any turn the app-server starts itself, so a missing wake is upstream
policy, not a gateway defect.
Recorded cross-home children can be inspected and controlled from the parent;
their native descendants are inspected through that child account's own Agents sheet,
with this coverage boundary shown explicitly.
