# Swift cluster clients

The client uses a gateway's authenticated `/health.hostId` as its canonical host
identity. Configuration UUIDs remain persisted aliases for old addresses and
notification links. An unavailable or older gateway keeps its configuration
identity until an authenticated identity read succeeds. Canonical hosts skip
launch identity work. Unresolved identity reads share a two-second launch budget;
unanswered hosts retry through the same fenced verification operation on
foreground entry or reconnect, after restore.

The existing account-retirement owner drains enrollment stores first.
`GatewayIdentityMigration` serializes imports per destination gateway before
host models open their stores. It preserves source data until the import's
completion marker exists, merges drafts through their import receipts, merges
pending mark identities without rewriting their scope, and imports checkpoints
through the checkpoint owner. Host preferences and saved conversation addresses
are rewritten only after protected host persistence succeeds. The preference
migration reads only the owning persistent domain and removes renamed keys. Duplicate verified
configurations collapse into one configuration; operator credentials take
precedence over an installation credential. Identity changes fail visibly rather
than reassigning existing data to another gateway. After protected identity
persistence, completed imports reclaim their source stores and remap recovery
recordings. Legacy aliases remain; rollback must retain the canonical identity
and stores. A host that was unreachable can be verified from its Hosts menu.
On restart, canonical hosts check only their alias import receipts. Unfinished
receipts resume preference migration and cleanup through the existing identity
retry task after launch; only that host's stores remain closed until completion.
Completed receipts skip all imports and preference scans. Preference completion
is recorded after renamed values are written and old keys removed. Adoption and
both verification paths share the exact set of matching configurations and aliases.

`ConversationAgentsModel` owns the shared cluster refresh for a parent address.
It queries configured hosts through `BoundedFanOut.hostLimit` (three), shares
overlapping reads and a ten-second deadline, and retains prior rows when one
host fails. Responses retain at most 512 rows per host. Projection runs off the
main actor, coalesces publications to an 80 ms interval, and fences prepared
results by refresh generation and input revision. RemoteIntent rows come from
the parent's host. Real rows replace those stubs by `(ownerHostId, jobId)`.
Relationships use the current `parent` tag, including an explicit null parent;
spawn provenance never prevents a promoted agent from appearing in the sidebar.
Thread headers represent absent, root and child tags as one enum. Intent rows
use the same epoch-second activity time as real rows. Badges derive from coverage
by owner host; wire rows contain no client presentation fields.

`ClusterModel` coalesces reads with unchanged configurations; changed inputs
cancel and fence the older generation. Reads use the same three-host fan-out and
ten-second deadline. Member indexes are prepared off the main actor and shared
by membership checks and coverage. The model also owns pending Join and Remove
operations. Each pair retains one
membership ID across retries and app restarts. It issues on both sides before
accepting, records each completed half, and retries a removal independently on
both sides. A later Join gets a new membership ID. Credentials remain transient;
only pair IDs, progress, and errors enter preferences. Missing host configurations
and installation-only connections remain visible as pending pairs with the
connection required to retry. Installation credentials
can read cluster status but cannot mutate membership.

The Settings Cluster page, child menus, sidebar menus and placement picker share
these owners. Menus send `agent/parent/set` to the exact owner's gateway. Coverage
strips preserve unknown, unreachable, unsupported, refused, unavailable and stale
states. They appear
when coverage is incomplete, format typed dates for display, and tolerate newer
state values as unknown. The client
never redirects an unavailable remote agent to its parent's gateway.

Wire shapes follow the lead's cluster v1 read contract: `cluster/list` has `self`
and `members`, parent addresses are `{hostId, threadId}`, and the app queries
`conversation/agents/list {parent}` directly on each host. Cluster membership
requests carry `protocol: 1` and the pair's membership ID.

## Refresh costs

Let M be the number of hosts, R the returned or retained rows, and A the unique
agents after merging. Array and dictionary snapshots share their storage until
changed. Refreshes do not sort the full result set.

| Owner | Main actor | Background work and bounds |
| --- | --- | --- |
| Launch identity | O(M) configuration filtering and result application; no network for canonical hosts | Canonical aliases read only receipt markers, O(R) receipts; unfinished work resumes after launch. At most three health reads, one shared two-second deadline; unresolved hosts retry after launch |
| Cluster refresh | O(M) host metadata, O(1) response application | O(R) member indexing and union; R is at most M times the cluster size; one shared refresh and deadline |
| Agent refresh | O(M) host metadata, O(1) response and prepared snapshot application | O(M + R + A) per coalesced projection; R ≤ 512M; O(M + R + A) retained storage; badge and detail lookups O(1) |
| Parent picker | O(M) header snapshots | O(R) filtering per query; cancelled queries cannot publish; preserves source order |
| Identity migration | O(M) verified host configuration changes once per adoption | Actor-owned store I/O; orchestration sorts checkpoint IDs once, O(R log R), plus the existing checkpoint/draft owners' import work and B imported bytes; manifest scans O(MR) across M legacy sources; preferences scan only the owning persistent domain off the main actor, once per alias |

Hierarchy construction uses indexed parents and an iterative traversal, O(A),
including cycles. Agent refresh callers share one read, reuse results for 15
seconds and have at most 32 waiting surfaces. Join and Remove are explicit user
operations; their persisted pair journal is capped at 256 entries. The account
retirement ledger runs again only if identity adoption changes the host set.
