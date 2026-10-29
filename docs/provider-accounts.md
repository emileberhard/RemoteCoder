# Provider accounts

Basic chat uses native provider logins: Codex in the managed home and Claude
Code in the host-default profile. No router or personal dotfiles are required.

The account-management and external-token contracts below apply when an
operator explicitly enables llm-router. In that mode the router owns
subscriptions, login, renewal and failover; each gateway holds one host key.
Without it, router-only inventory, preference, redemption and speech features
remain unavailable while native chat continues to use its own CLI login.

## App workflow

**Settings → Accounts** shows Codex subscriptions grouped by verified identity
and Claude subscriptions from llm-router, deduplicated by router account ID
across hosts. The newest successful router list replaces every Claude account
record and its membership, even when usage becomes unknown after a restart.
The drawer shows the selected Claude and Codex subscriptions in separate usage
rings. Claude rows show the plan, a shared marker, 5-hour and weekly usage with
reset times, and availability. **Automatic** follows the router's own choice and
marks the account it picks; choosing an account stores RemoteCoder's router
preference, shared by both hosts, and choosing Automatic clears it. An error
keeps the prior preference.

Each Codex account has one name across its hosts: a nickname from the overview's
row menu, else its verified email, else "Codex account". Names sync as user
preferences and can be changed offline. The overview and Codex usage circle
show the selected host's default account, with 5-hour and weekly percentages,
reset times and model-specific limits. Details contain usage and reset offers.

New chats, questions, voice calls and automations use their physical host's
default runtime for both providers. Changing a model keeps the draft, its
attachments and its host. The automation editor chooses a host and model;
saved enrollment fields are removed on save or restore. Historical execution
receipts and old conversation links resolve by their recorded host and thread,
ignoring retired enrollment IDs and generations. An older gateway may still list
enrollments during rollout; the app uses its default runtime, and migrated
enrollment threads become available when that host updates.

Local retirement discovers account folders and legacy pins from storage, even
when host settings cannot load. Each host becomes available after its import
attempt. Independent New Chat drafts keep separate deterministic slots and
restored windows follow those slots; conversation drafts merge by thread.
Checkpoint imports record durable receipts before consuming their sources.
Pending account-wide reads become `markRetiredScopeRead` operations. Cached read
coverage stays unknown until a full host snapshot advertises
`supportsRetiredScopeRead`. Old gateways retain pending edits until they catch up. Existing Claude
completion markers remain authoritative. Completed source folders are reclaimed;
failed imports retain their sources, stop after three attempts per importer
version and show an issue in the workspace. An importer fix grants incomplete
imports one new bounded attempt budget while retaining their existing receipts.
Metadata imports use `ConversationMetadataStore`'s versioned codec so dates and
all saved metadata state survive consolidation.

Claude's subscription preference remains owned by llm-router and does not move
conversations. RemoteCoder has no account enrollment, sign-in, enable/disable,
remove or reconnect controls. Provider credentials are managed in llm-router.

Both providers show available usage resets beside usage in the popover and
account overview. Details list each offer's title, expiry and Use action. Use
confirms the exact account and offer; stale or ineligible offers are disabled.
Opening the overview or Claude details requests an interactive refresh. Sign-in
failures name the account whose router grant an agent needs to reconnect.

An unconfirmed attempt keeps its host, exact gateway account ID, offer and
idempotency key across app restarts and offers Retry. It blocks another reset
until a known outcome or an explicit Forget attempt. Forget is available after a
definitely refused retry and confirms that the original outcome stays unknown.
A refused retry still offers same-key Retry. Account absence and host
configuration changes cancel a call without discarding same-key Retry. Keys are
persisted and submitted as lowercase UUID strings. Claude reset freshness uses
its own observation, independent of inference usage. The overview keeps removed
accounts' pending attempts reachable. A submitted reset survives backgrounding
under bounded platform execution, and its owning directory refreshes usage
after each outcome. Reset observations distinguish unread, unavailable,
count-only and known-empty details; see [Usage resets](usage-status.md#usage-resets).

## External Codex authentication

The host-default Codex runtime authenticates through the private router API using
`RC_CODEX_GATEWAY_ROUTER_CODEX_ACCOUNT`. The gateway authenticates on its persistent
control connection before recovery, observers, voice preparation or client admission.
A replacement connection authenticates again when it attaches to a surviving daemon.

The router issues tokens with at least 20 minutes remaining. The gateway signs
in again 15 minutes before expiry and retries a failed proactive renewal every
30 seconds. A 401 callback uses the rejected token generation, serializes with
other renewal work, and replies within a 6.5-second budget plus at most 500 ms
of queue admission. The router's caller budget is seven seconds; its rotation child has a separate
30-second deadline and survives caller cancellation. Callback work, state and replies belong to the exact
control connection generation. At most 16 refresh callbacks are admitted.

External tokens take precedence over a native `auth.json` in the same home.
When the app-server reports `account/updated` with any other auth mode, the
gateway installs router tokens again immediately; ChatGPT Desktop on the shared
socket can still sign out or sign in natively, and both are reversed this way.

Only the login connection receives native refresh requests. The gateway also
drops them on consumer streams; the apps and launcher ignore an unexpected copy.
External consumer connections cannot invoke `account/login/*`, logout, legacy
login mutations, or `getAuthStatus` with `includeToken: true`. Authentication
requests and token replies never enter the journal. Quota reads go through the
router and must return the bound account ID. Admission validates the installed
token claims and native account identity. The quota cache
owns usage only; unavailable quota does not block a valid installed token.

Each host uses one separately revocable router key, mode 0600, for inference,
accounts and Codex tokens. Origins can be loopback or explicitly allowlisted
operator endpoints. `RC_CODEX_GATEWAY_ROUTER_URL`,
`RC_CODEX_GATEWAY_ROUTER_ACCOUNTS_URL` and `RC_CODEX_GATEWAY_ROUTER_KEY_FILE`
stay gateway-owned and are not inherited by Codex. HTTP redirects and proxy
routing are disabled. The key is read for each request and never stored in an
environment variable. The router's `provision-remotecoder-key.sh` creates it and
RemoteCoder's `install-router-key.zsh` installs it.

A router outage leaves the last issued token in memory while it remains valid.
Renewal errors remain visible, new authentication fails, and expired tokens
cannot admit Codex work. Claude requests on the host default do not depend on
the Codex token. A control connection that cannot authenticate is not ready and
reconnects with backoff of up to five seconds. There is no local refresher or account fallback. A mismatched installed token fails closed.

`just shared-codex-check` requires the synthetic external-auth compatibility
matrix for every approved package. A passing matrix is reused only for an
identical package, probe inputs and execution host, after the requested host's
running package identity is verified again. Its private homes, loopback fixtures
and network restriction do not use real grants. `externalAuthAcceptance` in
`docs/codex/compatibility.json` separates that evidence from live subscription
acceptance.

### Operator authentication migration

Enabling router mode changes the active account owner: external tokens shadow a
native grant in the managed home. Changing or removing that mode on a live host
requires the transactional runtime owner and an exact interruption/recovery
check. Do not revoke a native login or replace credentials as part of an ordinary
source build. Historical maintainer migration and rollback procedures live in
the private [operations entrypoint](https://github.com/emileberhard/RemoteCoder-deploy/blob/main/AGENTS.md).

`AccountRetirementMigration` adopts every former Codex and Claude account
folder into the same host's default storage before chat models are constructed.
Discovery scans UUID account directories off the main actor, so missing cached
identities cannot strand local data. An on-disk ledger records checkpoint
receipts and completed imports. Failed imports retain their source files and
retry at most three times before surfacing a workspace issue; completed imports
reclaim their former folders only after the checkpoint store adopts protected recovery
bytes intact into the host's budget and source-keyed conversation recovery tree.
Invalidated imports retain pending submissions and unique local records while
continuing to require authoritative history.

Draft imports preserve draft IDs, setup, attachments and dictation receipts.
Drafts for the same conversation merge content once using import receipts.
Independent New Chat drafts and restored windows keep distinct destinations. Session indexes
retain one conversation per thread; checkpoints merge through the checkpoint
store, including pending submissions. Header and page caches, metadata, voice
history and per-thread marks adopt the host address. Cached pin, purpose and
settlement metadata remains available while read coverage reloads. Pending edits
keep their IDs and order; old host-default read-all operations are scoped once
before models start. New host-wide read actions remain global. Restored windows, deep links and pending
notifications retain their host and thread identities. Pending Codex reset
attempts retain their offer and idempotency key while using `default-codex`.

## Ownership

`ExecutionTarget` identifies a physical host. `ConversationAddress` adds its
native thread ID. Storage, questions, completion routing, notification replay
and voice ownership use that host and thread, independently of visible selection.

`ExecutionTargetRegistry` owns one `ChatTargetModel` and native connection per
configured host. Its `HostServices` owns directory discovery, device registration
and aggregate Live Activity. The account directory owns quota refresh; chat
models do not poll per-account usage.

The stable `ChatRootView` owns workspace bootstrap, scene lifecycle,
notification routing and diagnostic uploads. The selected chat screen owns its
presentation and quick actions. Codex usage follows the selected host's default
account; no Codex account choice is persisted. Claude preferences remain in the
router.

The host owns one Codex home (`CODEX_HOME` or `~/.codex`), one Claude profile
(`RC_CLAUDE_HOME` or `~/.claude`) and their gateway state in `~/.remote-coder`.
`account-enrollments.json`, its router-binding companion and `.rca/*` are legacy
migration input. Ordinary operation has no enrollment registry writes, provisioning,
account runtime slots or account-local gateway instances. Native credentials stay
with llm-router; each host holds one private router key. These homes are private
state, not security tenants against processes running as the same macOS user.

## Runtime protocol and lifecycle

The `/ws` endpoint serves every conversation through the host default. Retired
Codex and Claude enrollment IDs, including any `accountGeneration`, redirect to
that same context. Unknown IDs are refused. A restarting gateway answers 503;
accepted sockets receive the ordinary ready frame. Native JSON-RPC request IDs,
capabilities and subscriptions remain connection-local.

The host control API uses the existing gateway installation/operator credential:

| Operation | Method and path |
|---|---|
| Read the cached directory; optionally refresh, and optionally wait for the in-flight refresh | `GET /accounts?refresh=true&wait=refresh` |
| List Claude router subscriptions, usage, the automatic choice and RemoteCoder's preference | `GET /claude/accounts` |
| Set RemoteCoder's Claude preference, or `null` for automatic | `PUT /claude/accounts/preference` |
| Explicitly refresh stale Claude observations | `POST /claude/accounts/refresh` |
| Redeem a reset on the host-default Codex account | `POST /accounts/default-codex/resets/redeem` |
| Redeem a reset on a Claude router account | `POST /claude/accounts/resets/redeem` |

`wait=refresh` returns once the in-flight refresh round settles, bounded at 30 s
on the server; when the bound passes or no refresh is running, it returns the
current snapshot, whose `refreshing` says whether a round is still open.

The preference takes `{account: <router account ID> | null}` and refresh takes
`{}`; `null` returns to the router's automatic choice. The gateway reads the
router's `GET /accounts`, `PUT /accounts/preference` and `POST /accounts/refresh`
with the host's key and returns only Claude accounts. The preference belongs to
the `remotecoder` principal, so both hosts share it.
Claude account creation, removal and credential management remain in llm-router.
Configuration, transport and router failures return typed errors with actionable
messages. See [Subscription usage](usage-status.md) for observation semantics.

Each account carries `resets: null | {state, observedAt, available, offers, error}`.
`state` is `known` or `unavailable`; timestamps are Unix seconds. `available`
is the provider count, independent of the possibly capped offer list. A null
snapshot or count is unknown; `offers: null` means unknown details and `[]`
means fetched and empty. Each offer has `{id, title, remaining, expiresAt,
usableNow, requiresLimit, clears}`; a null expiry means no expiration.
Unavailable snapshots carry an error code string and no count or offers.
Codex and Claude use one translator for the router's normalized reset object,
from `POST /codex/quota` and the account inventory respectively. A malformed
reset object makes only that account's resets unavailable (`upstream_unavailable`).
Codex clears resets with expired usage windows and does not restore persisted
resets as current observations after restarting.

Codex redemption takes `{resetId, idempotencyKey, generation}` and verifies the
host-default generation `1` before submitting (`reset_account_changed` on a
mismatch). Claude takes `{accountId, resetId, idempotencyKey}`. The key must be a
UUID naming one attempt; the gateway normalizes it to canonical lowercase for
the router. Codex resolves the
host-default router configuration; enrollment IDs cannot redeem resets. Both routes call the router's
`POST /accounts/resets/redeem` once with `{provider, account_id, reset_id,
idempotency_key}`, using the host key's `accounts:redeem` scope and a 35-second
request deadline around the router's 30-second budget. Responses are
`{outcome: reset | alreadyRedeemed | notNeeded | refused, reason: string | null}`.

Errors use `{error: {code, message}}`: `redeem_in_progress` (409),
`redeem_unconfirmed_pending` (409), `redeem_unconfirmed` (504),
`router_stopping` or `reset_credential_unavailable` (503),
`router_unauthorized` (502, including insufficient host-key scope),
`router_key_unavailable` or `router_unavailable` (503), and
`account_not_found` (404). Router `codex_credential_unavailable` maps to
`reset_credential_unavailable`. Temporary `reset_state_unavailable`,
`account_store_unavailable` and `upstream_unavailable` errors map to
`router_retry_later` (503). A gateway without account management returns
`account_management_unavailable` (503). Router 4xx and 503 responses remain
definite refusals even with unreadable bodies; unspecified refusals use
`router_request_refused` (502). Router 504 and unexpected statuses, a failure
after submission, or an unreadable success response produce an unconfirmed
outcome. Connect failures are definite refusals. An unconfirmed attempt can be retried with the
same key, account and reset through configured routes to that same account owner;
the providers deduplicate by key. The gateway never retries redemption. After a
non-refused or unconfirmed outcome, tracked host work refreshes that account's
observations; a refresh failure never changes the redemption outcome. Codex
clears the cached observations after older refresh work settles before reading
fresh quota and repeats the read if another redemption completes during it.
Claude starts `POST /claude/accounts/refresh` as gateway-owned background work
after replying; it never waits for that refresh to return the redemption outcome.

The directory reports schema version 2 with exactly `default-codex` and
`default-claude`, independent readiness, stale/error state, observation time and
usage windows. `retiredClaudeAccountIds` and `retiredCodexAccountIds` identify the
legacy redirects. No provider credential is returned. Reset operations remain
owned by tracked host tasks if the requesting phone disconnects.

Codex identity uses the native email and the backend workspace/account identifier
from the installed router token. Unverifiable quota remains unavailable.

## Usage and voice

The overview groups Codex by verified identity, keeping distinct
workspaces separate even when they share an email. Claude subscriptions are
deduplicated by router account ID. Observations of the same Codex identity
across hosts are grouped without adding their allowances. It chooses a fresh, identity-matching observation and
retains per-host authentication/availability. Account groups have stable ordering
across quota refreshes. `AccountDirectory` stores Codex groups and rebuilds them
only when host configuration, accounts or names change. Its
`ClaudeAccountDirectory` owns router reads and the preference, fences
results when hosts change and cancels its work on teardown. Periodic reads use
GET. Only the Claude ring, its popover and All Accounts request quota probes;
Codex notification, automation and account-detail work refresh Codex separately.
A partial host failure keeps the successful router response and shows no error.
When every host fails, one error per failing host identifies the unavailable
routes. Initial and background reconciliation only updates configuration. The
foreground loop owns the first read; connection changes request a read only
while that loop is running. Renames preserve the responding route.
A preference change checks that route first, then others, and sends one
mutation. A lost response triggers an immediate read; confirmation clears the
error, while a failed read or unchanged preference leaves the failure visible.
Unknown windows remain unknown. Failed Codex hosts retain clearly stale data.
When a verified account's quota read fails, the account stays ready, the router
or app-server error is logged, and the last observation of that same identity
and generation is kept, marked stale, for up to 30 minutes. Any failed refresh
drops older observations entirely. Codex window duration and provider/model scope determine the
quota label, not the primary/secondary slot.

Both providers use the physical host's default Codex realtime voice runtime.
Calls retain their exact host, thread and call ownership; later UI selection
does not change an ongoing call.

The shared ChatGPT Desktop socket remains the default. In router mode, external
tokens remain authoritative and replace a native login changed outside
RemoteCoder; native mode leaves the CLI login authoritative.
Version upgrades of the approved Codex package need acceptance on both hosts.
Runtime retirement keeps the approved Codex version unchanged.

## Native goal and injection fences

A native goal or history-injection request whose reply is lost after enqueue
leaves a durable pending marker. Ordinary messages
remain available, but another goal/injection can be
refused even when no turn or call is visibly running. A send
that provably never reached the queue clears its marker immediately. An unknown
queued outcome remains fenced until the recorded native process is proven gone
and a different current process can be verified. If the runtime is unavailable,
reconciliation waits for its verified replacement to become ready.

Operator recovery belongs to the tracked runtime replacement/recovery transaction
in [Codex runtime and Desktop](../host-daemon-rs/AGENTS.md#codex-runtime-and-desktop).
Use the approved matched package and gateway, preserving the exact thread/turn
identity and its fence/suspend/recover journal. An ordinary gateway restart may
reattach to the same daemon and therefore need not clear this condition.
Do not delete pending markers or stop a daemon outside that transaction to bypass
the proof. Once the managed replacement is verified, retry the original action;
the next mutation reconciles proven-dead owners.

## Claude router and profile migration

Without a router, Claude uses its own login and settings in the configured
host-default home; readiness uses the unmodified CLI's native auth check.

In router mode, every Claude command reads the host's router key anew and injects
`RC_CODEX_GATEWAY_ROUTER_URL` as `ANTHROPIC_BASE_URL` plus only
`ANTHROPIC_AUTH_TOKEN` into its otherwise cleared provider environment. Rotation
requires no restart. The key never appears in diagnostics or receipts.

`GET /accounts` retains `default-claude` with `isDefault: true` on each host.
In router mode, readiness checks configuration and key readability; failures carry the
cause in the account snapshot's `error`. The execution target has no
subscription identity. Claude subscription accounts and usage are read
separately through the private router API. Router mode does not run `claude auth status` or a local quota client.
Claude Code's billing and permission guard still applies. Router authentication
disables claude.ai connectors and Remote Control. Local MCP uses the normal
configuration: the gateway sets `CLAUDE_CONFIG_DIR` only for explicit
`RC_CLAUDE_HOME`, preserving `~/.claude.json` with the default home.
`REMOTE_CODER_PARENT_CONTEXT` carries no account. The router key is inherited by
Claude subprocesses. Same-user processes can read the private key file and
inspect process environments; environment-aware process listings can expose it.
Command arguments, diagnostics and receipts never contain the key.

Before its first ordinary startup, the gateway clones every
`~/.rca/<id without hyphens>/claude` profile, including disabled, signed-out and
orphaned profiles, into `RC_CLAUDE_HOME` or `~/.claude`. APFS cloning falls back
to a copy only when cloning is unsupported. Source profiles, companion `state`
and `handoff-backups` remain intact for detached agents and recorded resume
paths. Codex profiles are untouched. The resumable migration carries transcripts,
sidecars, agent and parent records, metadata, calls, marks, questions and pending
restart recovery. `memory/MEMORY.md` merges exact lines in order: host first,
then profiles sorted by ID. Other memory conflicts follow the normal rule.
Metadata keeps the latest entry and advances its revision beyond every source.

Duplicate session UUIDs keep the longer byte-prefix transcript. Divergent copies
use the latest recorded handoff or pending recovery owner; absent that evidence,
native root conversation timestamps select the latest history. Unresolved
ownership fails startup with the affected paths and preserves all originals.
Other conflict variants, including divergent pre-merge state documents, are
cloned into `~/.remote-coder/claude-profile-conflicts/`; selection evidence and retired IDs
are in `~/.remote-coder/claude-profile-migration.json`. Completion retires Claude
enrollment and handoff records. Later startups do not rescan `.rca`.

While the migration is unsettled, the installer snapshots the gateway state owners
before candidate startup and keeps that snapshot through health-gated installation.
A settled migration (complete, nothing pending) writes nothing, so the installer
takes no snapshot and a rollback keeps the state the candidate accepted, so a
changed owner-file format needs its own downgrade path in
[`compatibility-register.md`](compatibility-register.md). A failed startup stops
the candidate, restores Codex recovery and gateway state, then starts the previous
binary. Existing host-profile files addressed by incoming data enter the snapshot,
including equal copies that a detached source process could append to before
migration. Unrelated symlinks and other entries stay untouched; project aliases
do not count as additional session copies. A project alias pointing directly to
a real directory in the same host `projects` root maps incoming data to that
canonical directory. Other incoming
symlink paths fail with their path. Migration writes and rollback restores
use directory descriptors without following symlinks. Newly cloned host-profile
additions may stay after rollback. Source profiles remain usable.
Restoring the pre-upgrade receipt state lets the next upgrade run migration
again when the first migration was rolled back. Temporary `--recovery-only` gateways preserve legacy Claude handoffs
without migrating Claude profiles or writing those handoff records.

Retired Claude enrollment IDs persist as temporary redirects. Account-scoped
requests, including `/ws?accountId=<retired>` with any generation, resolve to the
host default. `GET /accounts` includes `retiredClaudeAccountIds`, an array of
these IDs, empty when none. Only served redirects log usage; refusals do not.
Remove the redirect and directory field together after no served use for 14 days
and all old app windows, automation receipts, parent callbacks and launcher resume
paths have been migrated or retired. The operator may then remove source
profiles; conflict variants remain in gateway state. Claude enrollment and login
requests return a clear 4xx error. Account update and removal routes are retired.

## Codex enrollment adoption

Before ordinary bootstrap, `runtime::retire_codex_accounts` discovers registered
and orphaned `.rca/<id>/c` homes, including disabled enrollments. It fences live
source daemons, records every exact task tree, suspends leaves before parents
and stops the source through Codex's official daemon commands. Native data and
gateway state are adopted before ingress opens. Source homes are copied, never
moved or deleted, and become cold rollback copies.

The adapter is pinned to the exact approved Codex source in
`docs/codex/compatibility.json`. Filesystem repair cannot preserve SQLite-only
metadata or paginated projections, so `accounts/codex_migration/native.py` is the
single private-schema boundary. It checks schema and SQLx migration checksums of
both sides before writing. It copies thread metadata, selected rollout paths,
archive state, titles, dynamic tools, spawn edges, projects and attachments from
`state_5.sqlite`; the full history projection and observation versions from
`thread_history_1.sqlite`; and thread queues, goals and memory from `queue_1.sqlite`,
`goals_1.sqlite`, `memories_1.sqlite` and `memories_v2_1.sqlite`, together with
the `memories/` and `memories_v2/` files. Global migration cursors and provider
registrations stay with the default runtime. Each database commits independently;
file copies and recorded import plans make an interrupted import safe to repeat.
Divergent histories or incompatible schemas fail startup with originals intact.
Snapshot rollback takes the same native write lock as the importer, so a helper
surviving a killed gateway finishes before restoration can replace its databases.

Memory adoption keeps the default workspace's generated global files and Git
baseline. Unique source files copy to their canonical paths; divergent memory
files become byte-exact resources under
`<memory-root>/extensions/remotecoder-retired-<id>/resources/original/`. The
extension instructions make that curated knowledge an input to Codex's existing
Phase 2 consolidation for both memory versions, including knowledge no longer
present in stage-1 rows. Source Git metadata and stale workspace-diff artifacts
are never copied. Codex rebuilds raw memories and rollout summaries from the
merged stage-1 database normally; its own global consolidation job stays with
the default runtime. The existing installer snapshot includes imported resources
and their instructions, and retries reuse the same paths without appending text
or exceeding the v2 summary's size limit. Source profiles remain unchanged.

The pinned release creates two history layouts: freshly created databases and
databases upgraded through its earlier migrations order several columns
differently. The adapter accepts only their two exact schema fingerprints and
the same exact migration checksums. It selects and inserts columns by name, so
the layouts can be adopted into each other without swapping values.

The receipt in `~/.remote-coder/codex-profile-migration.json` records source IDs,
thread IDs, import progress and exact gateway state writes. Before importing,
its immutable `readScopes` records the original default Codex and Claude IDs
and explicit mark-only IDs, plus each retired source's complete scope. Native
rollout filename IDs supplement SQLite, including compressed archives and stable
thread IDs in reverted filenames, so filesystem read-repair cannot expose a
conversation outside its original read scope. The
older Claude receipt has only aggregate sessions; per-source scope comes from
its intact cold profile. Missing evidence stays unavailable, distinct from a
known empty scope. These ID sets survive profile deletion and are never rebuilt
by subtracting current history. A completed older adoption without these sets
cannot prove the original default scope.

Pending pre-retirement mark-all edits use `conversation/marks/update` with one
`{op: "markRetiredScopeRead", scopeId, through}` change. `scopeId: "default"`
selects the original host scope, and a canonical retired UUID selects its source
scope. The existing marks owner applies per-thread read semantics through at
most the gateway clock, without raising the shared baseline or including newer
threads. A missing scope fails the whole update without mutation, so clients
retain their pending edit. Older gateways reject the unknown operation. A full
`conversation/marks/read` adds `supportsRetiredScopeRead: true`; deltas omit it.
Clients wait for that full snapshot before flushing any imported retirement
edits, including per-thread reads or settlements that an older baseline could
otherwise acknowledge as a no-op. Missing or false support preserves pending
edits and unknown coverage.

Replaced native
databases and pre-merge gateway state remain in `codex-profile-conflicts`. Stopped native database
and WAL snapshots use the existing APFS clone owner under the adoption lock.
Adoption merges metadata,
marks, questions, calls, finished turns and the active-turn ledger, including
queued submissions. The active-turn owner validates merged documents before
staging and again before applying persisted writes; excess queues or pending
native mutations fail without trimming or applying any staged state. The marks
owner likewise validates the merged schema and its 8 MiB capacity before planning
or replaying any staged write; a refusal retains the preimages and prevents the
adoption commit. The existing
runtime transaction transfers suspended tasks
into the default recovery journal. Native adoption requires a stopped default
through that tracked transaction, even when a source has no running tasks.
Bootstrap then resumes the exact original thread and turn IDs. No cross-runtime
activity aggregation remains.

Adoption commits forward. The default journal must durably own every adopted
task before a registry commit removes the enrollments. The existing pending
registry document is the atomic removal boundary understood by older gateways;
the migration receipt binds its exact contents. Before that boundary, installer
snapshots restore native files, gateway state and source recovery journals.
After it, a binary rollback keeps the adopted native data, gateway state and
default recovery journal: the previous binary sees no enrollments and resumes
work through the default. It never restarts the cold source homes. Old app
windows that name a retired enrollment may fail against that rolled-back binary.

The current gateway redirects retired Codex IDs at any generation through the
same mechanism as retired Claude IDs and logs each accepted redirect with its ID
and generation. Remove redirects and both directory fields
after 14 days with no served use and after old app windows, automation receipts,
callbacks and launcher resume paths are migrated or retired. Source homes may
then be removed by an explicit operator action. Archived automation records may
retain their former IDs while the redirects remain.
The call worker still forwards legacy receipt query parameters through its
internal transport config; CLI account selectors are removed.

## Verification

`just gateway-check` and focused `just gateway-test` filters cover default usage,
resets, redirects, state adoption, exact recovery and the installer commit boundary.
Native adoption fixtures are written by the pinned Codex binary in temporary homes;
unit tests never use live provider homes. The isolated driver is:

```sh
bun dev-tools/probes/codex-adoption.mjs /absolute/path/to/candidate-gateway
```

It uses private homes or APFS clones of real homes, rebases clone-only absolute
rollout paths, and compares original IDs, titles and full turn/item pagination
before and after adoption. Repeating startup verifies idempotency. Live deployment
belongs to the transactional shared-stack installer and the owning release agent.
