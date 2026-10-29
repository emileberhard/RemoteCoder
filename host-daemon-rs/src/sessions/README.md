# Sessions v1

Provider transcripts and sidecars remain authoritative and read-only. This module
owns a rebuildable SQLite projection, full-text trigram index, exact byte reads,
a transactional change feed, cluster search, and a private raw-evidence mirror.
It does not own semantic memory or agent execution.

`Gateway::session_inventory` exposes paged canonical provider headers to lifecycle
reads without introducing another transcript reader. The matching `sessions/list`
RPC returns at most 1,000 headers and 8 MiB per page. First-page callers share a
bounded worker mailbox (64 requests); one discovery pass serves the waiting
callers. The worker alone writes local projection and identity changes, serving
catch-up between atomic source saves. Directory revisions find new files before
FSEvents delivery by statting known directories and enumerating only changed or
new directories, including nested Codex date folders. Removed directories leave
the map. Directory revisions and unresolved header paths are each capped at
100,000; overflow reports capacity without an unbounded walk. Full background
reconciles rebuild that discovery map and ingest missing headers before content.
Identity reads use the same parser with an 8 MiB/128-record budget. Partial
identities remain unavailable. A file created during an unusually long atomic
source save can hit the explicit five-second inventory deadline; its rows never
become a false empty result. Source-save durations are reported as aggregate
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
and FileRevision. Changed prefixes rebuild one source transactionally. Appends require the same device/inode, strict size growth, and matching 64 KiB head and tail windows of the previously accepted prefix. This bounds old-prefix reads to 128 KiB per check regardless of transcript length; short prefixes use one window. Only new complete records are parsed, and prefix_hash is a deterministic per-record hash chain, independent of event batching. Each ten-minute full reconcile verifies that chain for sources changed since their last full verification. A mid-file rewrite that preserves both windows and grows the file is detected within one reconcile interval; exact item reads still reject changed raw records immediately. Provider transcripts are append-only, so this is the deliberate bounded-lag trade. Companion discovery is limited to the changed source's subtree and capped at 100,000 evidence files. Malformed JSON and oversized complete records are skipped with a persistent per-source record_gap, a count and the first raw byte span in append_state. Their bytes participate in the same streaming record chain, and later records continue indexing without replaying the failed tail. Coverage stays incomplete until a rebuild removes the gap. Other ingestion errors retain accepted data and surface incomplete coverage. Missing dependencies
prevent the complete watermark from advancing.

Inventory pages seek the session primary key directly. Exact session reads union
three indexed address seeks (canonical key, bare thread ID, host plus thread ID),
with at most two candidates per arm and at most two distinct results. Unknown
addresses remain not_found; multiple canonical keys remain ambiguous usage.

SQL opens a separate read-only connection with query_only, no extensions or
attachments, a five-second progress deadline, 10,000 rows, and an 8 MiB response
budget. Read commands use byte ranges and return base64 plus UTF-8 when valid.
Earlier normalization-schema mismatches rebuild the projection with a new epoch.
The mirror feed metadata upgrade adds columns and replaces its source/dependency
triggers in place on v4, preserving accepted rows and the epoch; fresh v4 needs no
ALTER. Provider evidence and mirrored raw files remain intact. Change cursors
carry schema version, database epoch and monotonic sequence;
30-day expiry requires a SQL snapshot and its changeCursor. Item and source
updates and their feed records share a transaction. Retention never deletes raw
provider evidence. The catalog, WAL, raw mirror and temporary copies share one
64 GiB cap and a fixed 20 GiB free-space floor. One storage lock serializes disk
mutations. In-process contenders wait up to five seconds on the storage owner's
admission gate; an independent process holding the flock still refuses admission.
The mirror transfer owner never holds that lease across network I/O. Every flock lease explicitly unlocks before closing, so forked provider
children cannot prolong a released lease. Cached raw-byte accounting is adjusted on each owned mutation; DB, WAL
and SHM are measured by stat. Startup and bounded ten-minute reconciliation recover
orphans, and a dirty marker forces reconciliation after incomplete accounting. Catalog writes reserve room for both database pages and a full WAL;
raw transfers admit each chunk. Refusal appears in coverage without growing the
store. SQLite temporary query state stays in memory. The ingest worker is one
utility-QoS thread, separate from the live agent runtime.

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
marking them exhausted. Feed pruning seeks expired entries through change_age;
a catalog with no expired entries does not scan the feed during restart.


The private mirror role uses a per-member change cursor. Source and dependency
feed triggers retain origin/path metadata for upserts and tombstones while the
generic change-feed keys remain unchanged. `sessions/mirror/changes` seeks the
partial origin/sequence index, reads at most 500 evidence events plus one
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
