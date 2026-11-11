# Sessions v1

Provider transcripts and sidecars remain authoritative and read-only. This module
owns a rebuildable SQLite projection, full-text trigram index, exact byte reads,
an evidence change feed, cluster search, and a private raw-evidence mirror.
It does not own semantic memory or agent execution.

`Gateway::session_inventory` exposes paged canonical provider headers to lifecycle
reads without introducing another transcript reader. The matching `sessions/list`
RPC returns at most 1,000 headers and 8 MiB per page. First-page callers check
directory revisions and already-indexed headers without the writer. Requests
that need new headers share a bounded worker mailbox (64 requests). The worker alone writes local projection and identity changes, serving
catch-up at record checkpoints and between source saves. Directory revisions find new files before
FSEvents delivery by statting known directories and enumerating only changed or
new directories, including nested Codex date folders. Removed directories leave
the map. Directory revisions and unresolved header paths are each capped at
100,000; overflow reports capacity without an unbounded walk. Full background
reconciles rebuild that discovery map and ingest missing headers before content.
Identity reads use the same parser with an 8 MiB/128-record budget. Partial
identities remain unavailable. An unusually long record or evidence check can
still reach the explicit five-second inventory deadline.
New sources and verified appends checkpoint at a complete record when inventory
waits, serve its headers, and resume from the persisted prefix. A changed-prefix
replacement rolls back before serving inventory and retries atomically. The same worker projects mirrored evidence and serves
inventory at the same checkpoints. Source-save durations are reported as aggregate
longestSourceSeconds and sourcesOverFiveSeconds by ingestion.

`schema.sql` is the versioned schema; `views.sql` provides analytics conveniences.
`source.local_path` separates an origin path from a mirror path. Byte spans and
record hashes in `item.source_ref` fence exact reads after a rewrite. Unknown
item timestamps and unobserved execution outcomes remain NULL. Claude historical
prompt UUIDs use the `record:` namespace when no provider turn ID was recorded;
these are analytical references and never control identities.

Claude transcript filenames own top-level identity, including an empty transcript.
Its inventory header uses that same path normalization without parsing message
content; unknown title, dates and ancestry remain absent until content supplies them. Native agent filenames at
any depth below a session's subagents directory own child identity, with that
session as parent. Discovery accepts top-level project transcripts and those
agent files; workflow journals and tool-result JSONL are evidence, not separate
conversations. Native thread suffix resolution seeks the indexed reversed UTF-8 bytes, scoped to the owning host, and stops at two matches.
Schema 3 rebuilds earlier development catalogs to normalize these
provider layouts; no provider evidence is rewritten.

The ingest worker is independent of jobs and retains one bounded provider record
at a time. notify 8.2.1 uses FSEvents on macOS. The watcher is armed before the
initial scan, stays armed through reconciliation, and queues at most 512
deduplicated paths per origin. Overflow collapses to a common subtree within
that origin; rescan flags recursively reconcile the affected subtree. A hot set covers macOS writers that keep their transcript fd open, where FSEvents reports content modifications on close. Recent source revisions seed at most 64 paths through the source_recent index; the worker stats only these paths once per second, evicts the least recent on overflow, and removes entries after ten minutes without a revision change. Empty hot sets have no timer, filesystem work or database work. A long-idle transcript resumed with a continuously open fd can wait for the next ten-minute reconcile before entering the set; create/close events and inventory-discovered files enter sooner. Quiet waits with an empty set touch neither the filesystem nor the database. A full reconciliation runs
every ten minutes, and pending events survive scans. Watches cover only existing
provider roots and are rearmed before each full scan. notify 8.2.1 can discard
an ancestor-level FSEvents rescan before delivery; the ten-minute full reconcile
bounds this upstream gap. Persistent scan errors back off from two seconds to
ten minutes, resetting on success. One storage writer serves
each batch of at most 32 sources. Missing sources reclaim their catalog rows
and emit feed tombstones through this same ingest owner. An unavailable provider
root preserves its rows and reports provider_unavailable instead of deletions. Source/dependency path
indexes bound incremental discovery; exact and subtree paths use separate indexed ranges, and dependency-driven checks join their source by primary key. Unchanged history is not walked per event. It reuses the provider bounded-line reader
and FileRevision. Changed prefixes rebuild one source transactionally. Source and dependency identities are inode, size, mtime and ctime; they omit st_dev, which changes when a reboot enumerates disks in another order. A changed identity with unchanged size verifies the accepted prefix chain and then updates only the stored identity, so metadata changes never rewrite items. Companion and image changes refresh their dependency rows; only a changed sidecar, whose text feeds items, rebuilds the source. Appends require strict size growth and matching 64 KiB head and tail windows of the previously accepted prefix, so a verified copy renamed over the source still appends. This bounds old-prefix reads to 128 KiB per check regardless of transcript length; short prefixes use one window. Only new complete records are parsed, and prefix_hash is a deterministic per-record hash chain, independent of event batching. Each ten-minute full reconcile verifies that chain for sources changed since their last full verification. A mid-file rewrite that preserves both windows and grows the file is detected within one reconcile interval; exact item reads still reject changed raw records immediately. Provider transcripts are append-only, so this is the deliberate bounded-lag trade. Companion discovery is limited to the changed source's subtree and capped at 100,000 evidence files. Malformed JSON and oversized complete records are skipped with a persistent per-source record_gap, a count and the first raw byte span in append_state. Their bytes participate in the same streaming record chain, and later records continue indexing without replaying the failed tail. Coverage stays incomplete until a rebuild removes the gap. Other ingestion errors retain accepted data and surface incomplete coverage. Missing dependencies
prevent the complete watermark from advancing.

Inventory pages seek the session primary key directly. Exact session reads union
three indexed address seeks (canonical key, bare thread ID, host plus thread ID),
with at most two candidates per arm and at most two distinct results. Unknown
addresses remain not_found; multiple canonical keys remain ambiguous usage.

SQL opens a separate read-only connection with query_only, no extensions or
attachments, a five-second progress deadline, 10,000 rows, and an 8 MiB response
budget. Read commands use byte ranges and return base64 plus UTF-8 when valid.
Any other schema version deletes the catalog, WAL and SHM under the storage lease
and rebuilds a fresh file with a new epoch, so deleted index pages never survive an
upgrade. Fresh files set incremental auto-vacuum before WAL mode, and each scan
returns freed pages to the filesystem. Provider evidence and mirrored raw files remain intact. Change cursors
carry schema version, database epoch and monotonic sequence. The feed records
only source and dependency evidence paths, in the transaction that changes their
identity or presence, and keeps the newest 1,000,000 rows; an expired cursor takes
a full listing. Retention never deletes raw
provider evidence. The catalog, WAL, raw mirror and temporary copies share one
64 GiB cap and a fixed 20 GiB free-space floor. One storage lock serializes disk
mutations. In-process contenders wait up to five seconds on the storage owner's
admission gate; an independent process holding the flock still refuses admission.
The mirror transfer owner never holds that lease across network I/O. Every flock lease explicitly unlocks before closing, so forked provider
children cannot prolong a released lease. Cached raw-byte accounting is adjusted on each owned mutation; DB, WAL
and SHM are measured by stat. Startup and bounded ten-minute reconciliation recover
orphans, and a dirty marker forces reconciliation after incomplete accounting. One headroom value governs growth: the smaller
of the cap's remainder and the free space above the floor, minus the unused part of
the 8 GiB WAL allowance. Writers cap max_page_count at the current pages plus
headroom, so reads, deletes and pruning continue at the limit, and raw transfers
admit each chunk within headroom. Coverage reports `budget` below 64 KiB of
headroom, and each full reconcile replaces
`~/.local/state/disk-cap-status/remotecoder-sessions.json` for the shared
disk-pressure owner. SQLite temporary query state stays in memory. The ingest worker is one
utility-QoS thread, separate from the live agent runtime. Unit stores explicitly
inject free capacity, so host disk reserves cannot fail fixtures; the same
production reserve calculation is tested below its free-space floor.

Mirroring requires an explicit host role, off by default. Private operations
projects `sessions/mirror-role.json` with `{"enabled":true}` on the always-on
mirror host. The private role alone enables copying; the CLI reports status.
The MacBook keeps only its own catalog and reads the Mini live.

The mirror reclaims its copies after the origin reports deletion or a complete
listing no longer includes them. Agent Memory's archive is independent retained
evidence and is never deleted here. Identity and revision fences protect each fetch; a verified
prefix permits append, while a rewrite restarts the file. SQL always runs on one
database and reports its covered origins. Search fans out, deduplicates mirrored
items and reports unreachable members without hiding successful results.

The gateway uses the retained host identity and cluster link for member reads.
Native suffix resolution reads its bounded index first and requests coalesced
worker catch-up only on a miss.
The CLI is `remote-coder-codex-gateway sessions`; `--local` and `--database`
permit gateway-independent reads. All output is JSON; errors go to stderr.

The installed skill catalog uses the user roots `.agents/skills` for Codex and
`.claude/skills` for Claude. Resolved paths deduplicate symlinks. The catalog
contains at most 10,000 skills; first_seen is the first catalog observation, so
newly discovered skills are excluded from claims about an earlier unused period.

The idle-cost decision keeps native events rather than directory-mtime polling:
resuming an old conversation appends without changing its parent directory mtime.
A bounded hot set covers writers that retain open files; no debouncer is needed.
The manual corpus probe also accepts
`RC_SESSIONS_MEASURE_IDLE=after` to measure a quiet minute and cold-append/new-file
latency on a prepared private full-history catalog. Full reconcile CPU is
reported separately and amortized over its ten-minute interval.

Schema 4 rebuilds earlier development catalogs with origin-indexed dependencies
and persisted provider roots. Mirror listings perform cursor seeks and limit in
SQL before materialization: a page performs O(R log H) index work and O(R)
filesystem checks for R <= 500, including shared evidence only once. A missing
provider root refuses even an empty continuation page; unknown presence never
authorizes mirror reclamation. Rotation retires a proven-missing source owner
inside the replacement transaction; an existing owner remains a conflict.

Canonical session and item reads route directly to the origin member. Explicit
local and database reads stay on that catalog, and peer reads cannot fan out.
Exact item and dependency responses return bytes captured from the same opened
handle used for validation. SQL bounds cumulative encoded response bytes before
allocating text or base64 values, with SQLITE_LIMIT_LENGTH on the query connection
only; ingestion and other SQLite users have no process-wide heap limit.

Search returns newest-ingested items first with a descending rowid cursor.
Background rebuilds ingest sources oldest-first by mtime; appended records enter
at the head of search naturally. Ordering uses FTS rowid directly and stops at
the page limit without sorting all matches. Timestamps remain exact predicates:
item timestamps and ingestion order are not interchangeable. A date window with
few qualifying hits, especially a historical before window if added later, can
still visit every matching posting; common since queries terminate once the page
fills. Cluster cursors retain failed or unqueried members for retry rather than
marking them exhausted. Feed pruning deletes one primary-key range below
the newest 1,000,000 rows and never scans the feed.


The private mirror role uses a per-member change cursor. Source and dependency
triggers record origin and path for inserts, identity or presence changes and
deletions. `sessions/mirror/changes` seeks the
origin/sequence index, reads at most 500 evidence events plus one
lookahead, deduplicates their paths and stats only affected evidence. An empty
page performs no raw-file work. A missing provider root refuses changed batches
instead of proving deletion.

The mirror persists its cursor only after transfers, deletions and projection
ingest finish. The same transfer path handles full and incremental pages. First
sync and cursor expiry use the paged full listing, capturing a feed cursor before
the first page so concurrent changes are replayed. Full listings and whole-tree
reconciliation otherwise run no more often than once per 600 seconds. Unchanged
ticks make one bounded feed request per member and write no catalog state.
Changed paths and full manifests are capped at 100,000, provider homes at 1,024;
overflow refuses the batch without advancing the cursor. The projection's last
completion state is retained separately from origin coverage so idle ticks do not
rescan history to recover it. The role remains off by default.

## Conversation search

`sessions/conversations/search {query, limit}` is a gateway-owned, Query-lifetime
read of this host's catalog, including every mirrored origin. It never contacts
cluster members. `host/info.conversationSearch` advertises support. The existing
`sessions/search` retains its literal, pageable, newest-ingested-item contract.
The debug CLI is `remote-coder-codex-gateway sessions conversations QUERY --limit 30`;
`--database PATH` and `--local` read that catalog directly.

The trimmed query accepts 1–512 UTF-8 bytes and at most eight deduplicated,
case-insensitive whitespace-separated terms. `limit` is required and accepts
1–50 conversations. Unknown fields are invalid params. All terms must be covered
by the conversation across its title, folder and messages; the final term is a
word prefix. Terms without a letter, number or private-use character are
ignored, including punctuation and emoji. A query with no searchable word is
invalid. SQLite unicode61 folds case and Latin diacritics, including
Malmö for `malmo`. Two- and three-character prefixes have dedicated indexes.
Word prefixes start at token boundaries. For example, `searchsession` does
not match `ConversationSearchSession`.

Conversation documents contain separately weighted title, typed-user,
assistant and folder columns. Title and typed text receive weights
8 and 4; assistant receives 1 and the folder contributes coverage only.
BM25 document score ranks first, followed by recency and canonical key. Grouped
search uses only document matches as candidates. It cannot find terms that occur
only in tool calls, tool output, reasoning or injected context. The existing trigram RPC
`sessions/search` retains literal substring access to that evidence. A grouped
result requires an all-terms title match or a message hit. Ranking never fetches
full message text. Codex assistant text uses model-facing response records as its
single owner. Native-only final answers with delivery/questions metadata are
not indexed; the copied 200-source audit found 2 among 2,633 completed assistant
events. Inter-agent response records are not assistant text.

Schema-version-1 responses contain `truncated` and ranked `conversations`. Each
conversation carries its root `sessionKey`, origin `hostId`, `provider`,
`threadId`, nullable `title`, `cwd` and `lastAt`, `titleMatch`, `hitCount`, and a
nullable `hit` object. A hit contains its exact `itemKey`, an excerpt of at most
240 Unicode characters, and nullable `agentThreadId`.
A hit opens in `agentThreadId` when present and the conversation's `threadId`
otherwise. `sessions/locate` returns that same destination for the item key.
A delegated child opens in its own thread. A native Claude child opens in the
thread owning its spawning Agent call, which can be the root or a delegated
thread. Unknown dates and metadata stay null. Deleted sources are
excluded. Native ancestry and persisted delegated parents fold through at most
16 links. A missing ancestor stops the walk at the nearest present ancestor.
Ambiguous delegated ownership and cycles leave the session unfolded.
Explicit promotion overrides native ancestry.

At most 128 ranked document candidates are fetched. The scoped item word index
uses the same user and assistant kinds as the document. It covers
at most 128 member sessions and finds 64 newest hits per term per
candidate. Ranking reads metadata. The gateway applies SQLite's tokenizer to
the selected text of one hit per result to build its excerpt. Items larger than
1 MiB still count toward `hitCount`. A conversation can match with `hit: null`.
Hits prefer distinct-term coverage, then recency. `hitCount`
counts unique items inside these bounded windows. The app clamps this displayed
count. Candidate, member and hit windows are ordinary result bounds.
`truncated` means catalog or derived backfill is unfinished, the mirror is
rebuilding, or the deadline cut the work. Coverage staleness is reported by
`sessions/sql`. The app can show finished results while indicating unfinished
search work through this flag.
Two dedicated reader permits isolate typing from the 16 inventory/mirror readers.
The one-second deadline includes FIFO, admission and execution. Completed
snapshots survive timeout with `truncated: true`, including when publishing the
prepared response waits for outbound capacity. Expiry before any stage completes
yields typed `requestTimedOut`. A request-owned drop guard signals cancellation,
disconnect and deadline to the same SQLite progress handler, checked every
1,000 VM instructions, releasing the blocking reader's permit promptly.

## Projection and search-index rebuilds

Schema 6 used model-facing user roles; schema 7 uses typed-user evidence. SQL
and literal-search consumers filtering `kind='user'` therefore exclude injected
context after the rebuild. Schema 7 is the single transcript rebuild for typed-user classification and
origin-owned facts. Codex typed prompts and steers primarily use paginated
`event_msg/item_completed` records whose item is `UserMessage`, using the fork's
prepared user input. Legacy-history `event_msg/user_message` records are the
other authoritative shape. Sources without either shape classify user-role
response records with the provider's contextual-message rules. The first
authoritative event demotes response-user rows after the last assistant item,
reconciling only its current prompt; earlier completed turns keep their typed
text. All later response rows remain system context. This source-level choice does
not compare text, so image labels and attached-file wrappers cannot duplicate
a prompt. Both authoritative shapes can coexist during a history-mode change.
Agent-message and injected-notification envelopes remain system items.
Claude uses the history projection's injected-record and queued
prompt owners. Compaction summaries, task notifications and agent-message
envelopes never become user items. The prompt-envelope owner extracts captions
and pasted payloads for the document, excluding the injected RemoteCoder note
and attached-file path list. Catalog text remains literal for the existing
search endpoint.

The origin records Codex names from its native append-only session index and
current delegated parents from `JobStore`'s authoritative parent tags. The ingest
worker applies these facts outside request lifetimes, only for changed identities on ownership changes and
when a new transcript can resolve a previously missing identity. Searches never consult the
job store. Optional `sessionMetadata` fields on mirror page envelopes carry the
facts with transcript evidence. Entry shapes and mirror schemaVersion remain
unchanged: older receivers ignore the envelope field and newer receivers accept
pages without it. Fact changes enter the existing evidence feed, including when
raw transcript bytes have not changed.

`search_schema.sql` owns independently versioned derived indexes. A search-version
mismatch drops only those indexes and rebuilds them from catalog rows, without
re-reading transcripts. The utility worker starts after the HTTP listener is
bound and owns the reset. Until the current derived schema is installed, search
returns an empty result with `truncated: true` and reads the canonical catalog
version marker only. The worker handles newest conversations first and
coalesces affected roots in a persistent dirty queue. Canonical item changes
maintain the scoped word index transactionally. A new conversation publishes its
document during ingest. Ancestry changes rebuild the previous and current roots.
Ordinary changes reuse the existing ancestry. A document refresh over 10 ms
defers the next refresh of that root for nine times the observed refresh cost.
The worker wakes at the next due refresh even if appends stop. The previous
document can supply candidates while a refresh waits. That freshness lag does
not set `truncated`. Initial catalog work, the derived rebuild backlog and mirror
rebuilds do set it.

Documents retain the entire title and folder. The typed-user and assistant
columns each use the newest whole items up to 2 MiB of catalog text across
128 member sessions. An item that would exceed the remaining column budget
ends that column's window. Earlier terms remain available in the scoped word
index for already matched conversations. `sessions/sql` reports the
number of capped roots in `coverage.conversationSearch.cappedRoots`. This count
is null while the derived schema is being installed.

Measured with isolated catalogs, the user/assistant word index and conversation
index occupied 196.4 MB and 143.3 MB on a fully re-ingested 7,330-source copy.
On a newer 7,394-session copy reprojected from prior canonical rows, version 5
used 402.3 MB and 310.4 MB after persisted ownership folding. That second sample
has 3,716 roots: 11 exceed the typed budget, 3 exceed the assistant budget, and
12 exceed either (0.32%). One additional root exceeds the member window.
These are different classification samples, not an index-size A/B comparison.
The initial version-5 derived pass over the copied rows took 227 seconds; the
fully re-ingested corpus's prior derived pass took 262 seconds including an
overlapping build. Neither pass read transcripts.

Forty-three warm limit-30 requests on the MacBook took 88 ms at p50 and 193 ms at
p95, with a 228 ms maximum at 0.555 load per core. On the newer copied-row corpus,
the same query sample on Linux took 159 ms at p50 and 296 ms at p95, with a 420 ms
maximum at 0.549–0.575 load per core. Every Linux response was finished, including
`search` with 1,654 matching candidates. Both samples stayed within the one-second
deadline. The host and corpus changes prevent attributing the difference to
statement preparation alone.

A sampled largest root refresh reads about 2.09 MB from each column, compared
with its earlier unbounded 4.85 MB typed column. It took 153 ms before commit,
734 ms including commit, and scheduled 1.38 seconds of cooldown (about 2.11 seconds
of candidate lag including a full cooldown). That Linux timing began at 0.560
load per core but ended at 0.729 and is unqualified. A p95 tree on the earlier
corpus took 37 ms before commit and 92 ms including commit, with 333 ms cooldown
and about 0.43 seconds of candidate lag at 0.595 load per core. Storage commit
time varies. The utility worker's cost-based cooldown limits tokenizing duty
cycle; inventory and history reads use their separate read paths.

Moving derived reset off startup reduced health readiness from 39.6 seconds to
2.1 seconds on the MacBook (0.267 and 0.637 load per core respectively). While
7,330 sources were pending, inventory and search answered in 1.38 and 1.28 ms at
0.401 load per core. A complete schema-6-to-7 replay of 197 copied Linux sources
(348 MB) became searchable in 41.7 seconds at 0.205–0.269 load per core. Headers
were available before content completed, and exact provider history reads
continued during ingestion. The one-time schema rebuild ingests oldest sources
first to preserve the existing literal-search rowid order.

## Locate a matching item

`sessions/locate {itemKey}` returns `{threadId,turnId,turnsCursor,itemId,itemsCursor}`.
All fields except `threadId` are nullable. `turnsCursor` starts `thread/turns/list`
ascending at the located turn inclusive; `itemsCursor` starts thread-wide
`thread/items/list` ascending at its anchor inclusive. The capability is
`conversationSearch`; the shell entry point is `sessions locate ITEM_KEY`.

The catalog verifies the exact source record before locating. Claude uses the
existing projection's byte span and content part, preserving provider item and
turn identities. Its item cursor anchors the exact item. Native Claude children
resolve to the parent conversation's spawning Agent call only when its
structured result links the exact child agent id; otherwise the parent thread
is returned with null position fields.

Codex preserves the catalog's native turn when known. At most two occurrence
pages and one exact `thread/items/read` verify a unique text/item identity. One
`thread/items/list` filtered to the known turn with limit 1 yields its inclusive
`backwardsCursor`, which the fork accepts thread-wide. It anchors the first item
of the turn. Tool output and reasoning can use that turn anchor while `itemId`
remains null. Locate never resumes or subscribes a thread. Its one-second Query
deadline and cancel-on-drop path interrupt catalog and Claude work. Native Codex
reads share the request's absolute deadline. Cancelling releases the waiter,
and a stalled native read releases its permit at that deadline with its known
turn-level fallback. A third locate returns its turn-level answer immediately.

## Search by meaning

`sessions/conversations/searchByMeaning {query,limit}` accepts 1–512 trimmed
UTF-8 query bytes and 1–50 results, rejecting unknown fields. It returns
`{schemaVersion:1,conversations:[{sessionKey,hostId,provider,threadId,title,cwd,lastAt,excerpt}]}`.
The operator sets `RC_CODEX_GATEWAY_CONVERSATION_SEARCH_PROVIDER_FILE` to a
regular JSON file of at most 64 KiB containing an absolute `command` and `args`
array. No shell expansion is performed. Only configured hosts advertise
`host/info.conversationSearchByMeaning:true`. The debug CLI is
`sessions meaning QUERY --limit 20` through the gateway.

Each request writes `{query,limit}` JSON to stdin and reads
`{conversations:[{sessionId,provider,excerpt}]}` from stdout. The provider
ranks results; the gateway preserves that order, resolves provider/native id
exactly to one present catalog session, folds its persisted ancestry, dedupes
roots and drops unresolved or ambiguous identities. Dates and metadata remain
nullable. The query is never logged. The eight-second deadline includes
admission and two provider permits. Stdout is capped at 1 MiB; malformed output,
provider failure and overflow are errors. Cancellation, disconnect and timeout
kill the unreaped provider process group. Reaping disarms that signal owner.
Catalog resolution uses the same SQLite
cancellation path as keyword search.

`bun dev-tools/probes/conversation-search.mjs /absolute/candidate` verifies
search, a split-message query, diacritic folding, exact Claude locate and its
inclusive history cursor, parameter rejection and a stub meaning provider in
private state. It removes its root and processes on success, retaining evidence
on failure.
