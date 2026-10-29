# Swift cluster clients

The client uses a gateway's authenticated `/health.hostId` as its canonical host
identity. Configuration UUIDs remain persisted aliases for old addresses and
notification links. An unavailable or older gateway keeps its configuration
identity until an authenticated identity read succeeds. Canonical hosts skip
launch identity work. Unresolved identity reads share a two-second launch budget;
unanswered hosts retry through the same fenced verification operation on
foreground entry or reconnect, after restore.

The existing account-retirement owner drains enrollment stores first.
`HostStore` writes a verified source-to-target journal into its protected snapshot
before importing. That journal fences source and target stores and connection
edits, including after a crash before canonical configuration persistence.
Launch resumes it offline before model stores open. One serialized HostStore
operation imports drafts, pending mark identities and checkpoints, persists the
canonical configuration, rewrites preferences and recordings, and removes source
files. Local I/O failure keeps the journal, fence and visible error. Foreground
or reconnect resumes that same operation; neither network access nor a new
verification is needed. Receipts are scoped to the journal and cannot authorize
adoption independently. A canonical host without a journal does no identity I/O.
Protected recovery bytes move intact through the checkpoint store into the canonical
conversation's budget and source-keyed recovery tree before source folders retire;
invalidated checkpoints retain local records and require authoritative history.

Preference migration reads only the owning persistent domain, removes renamed
keys, and records completion last. Duplicate verified configurations collapse
into one configuration; operator credentials take precedence over installation
credentials. Identity changes fail visibly rather than reassigning existing data.
Legacy aliases remain for addresses and notification links; rollback must retain
the canonical identity and stores. An unreachable host can be verified from its
Hosts menu. Both verification paths derive matching configurations and aliases
from HostStore.

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
both sides. Remove journals every exact edge found in cluster listings, including
peers without app configurations. A pending acknowledgement retains Retry until
that half completes. A later Join gets a new membership ID. Credentials remain transient;
only pair IDs, progress, and errors enter preferences. Missing host configurations
remain visible as pending pairs with the connection required to retry. Operator
and installation credentials both manage membership; peer gateways cannot.

The Settings Cluster page, child menus, sidebar menus and placement picker share
these owners. Menus send `agent/parent/set` to the exact owner's gateway. On
acknowledgement, ConversationList reads an uncached child's exact header and
admits it through the history owner. Visible parents refresh immediately; changes
during an in-flight read coalesce into one trailing read, with pre-acknowledgement
results fenced. Coverage
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
| Launch identity | O(M) configuration filtering and result application; no network for canonical hosts | No identity disk or network I/O for canonical hosts without a journal. Journaled work completes locally before affected stores open. At most three health reads, one shared two-second deadline; unresolved hosts retry after launch |
| Cluster refresh | O(M) host metadata, O(1) response application | O(R) member indexing and union; R is at most M times the cluster size; one shared refresh and deadline |
| Agent refresh | O(M) host metadata, O(1) response and prepared snapshot application | O(M + R + A) per coalesced projection; R ≤ 512M; O(M + R + A) retained storage; badge and detail lookups O(1) |
| Parent picker | O(M) header snapshots | O(R) filtering per query; cancelled queries cannot publish; preserves source order |
| Identity migration | O(M) verified host configuration changes once per adoption | Actor-owned store I/O; orchestration sorts checkpoint IDs once, O(R log R), plus the existing checkpoint/draft owners' import work and B imported bytes; one manifest scan O(R) for all journaled sources; preferences scan only the owning persistent domain off the main actor, once per alias |

Hierarchy construction uses indexed parents and an iterative traversal, O(A),
including cycles. Agent refresh callers share one read, reuse results for 15
seconds and have at most 32 waiting surfaces. Join and Remove are explicit user
operations; their persisted pair journal is capped at 256 entries. The account
retirement ledger runs again only if identity adoption changes the host set.
