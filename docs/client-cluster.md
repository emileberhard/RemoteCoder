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

`ConversationAgentsModel` owns the shared cluster refresh for a parent address.
It queries each configured host concurrently, publishes successful hosts as they
answer, and retains prior rows when one host fails. RemoteIntent rows come from
the parent's host. Real rows replace those stubs by `(ownerHostId, jobId)`.
Relationships use the current `parent` tag, including an explicit null parent;
spawn provenance never prevents a promoted agent from appearing in the sidebar.
Thread headers represent absent, root and child tags as one enum. Intent rows
use the same epoch-second activity time as real rows. Badges derive from coverage
by owner host; wire rows contain no client presentation fields.

`ClusterModel` owns pending Join and Remove operations. Each pair retains one
membership ID across retries and app restarts. It issues on both sides before
accepting, records each completed half, and retries a removal independently on
both sides. A later Join gets a new membership ID. Credentials remain transient;
only pair IDs, progress, and errors enter preferences. Missing host configurations
and installation-only connections remain visible as pending pairs with the
connection required to retry. Installation credentials
can read cluster status but cannot mutate membership.

The Settings Cluster page, child menus, sidebar menus and placement picker share
these owners. Menus send `agent/parent/set` to the exact owner's gateway. Coverage
strips preserve unknown, unreachable, unsupported and stale states. They appear
when coverage is incomplete, format typed dates for display, and tolerate newer
state values as unknown. The client
never redirects an unavailable remote agent to its parent's gateway.

Wire shapes follow the lead's cluster v1 read contract: `cluster/list` has `self`
and `members`, parent addresses are `{hostId, threadId}`, and the app queries
`conversation/agents/list {parent}` directly on each host. Cluster membership
requests carry `protocol: 1` and the pair's membership ID.
