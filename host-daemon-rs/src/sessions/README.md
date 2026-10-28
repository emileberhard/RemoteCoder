# Sessions v1

Provider transcripts and sidecars remain authoritative and read-only. This module
owns a rebuildable SQLite projection, full-text trigram index, exact byte reads,
a transactional change feed, cluster search, and a private raw-evidence mirror.
It does not own semantic memory or agent execution.

`Gateway::session_inventory` exposes paged canonical provider headers to lifecycle
reads without introducing another transcript reader. The matching `sessions/list`
RPC returns at most 1,000 headers and 8 MiB per page. The first page catches up
new transcript identities through the same parser, with a five-second discovery
deadline and an 8 MiB/128-record identity budget per new source. Partial identities
and concurrent ingest return unavailable rather than a false empty inventory.

`schema.sql` is the versioned schema; `views.sql` provides analytics conveniences.
`source.local_path` separates an origin path from a mirror path. Byte spans and
record hashes in `item.source_ref` fence exact reads after a rewrite. Unknown
item timestamps and unobserved execution outcomes remain NULL. Claude historical
prompt UUIDs use the `record:` namespace when no provider turn ID was recorded;
these are analytical references and never control identities.

The ingest worker is independent of jobs, polls every two seconds, and retains
one bounded provider record at a time. It reuses the provider bounded-line reader
and FileRevision. Changed prefixes rebuild one source transactionally; verified
append prefixes continue at the last complete record. Malformed or oversized
records retain accepted data and surface incomplete coverage. Missing dependencies
prevent the complete watermark from advancing.

SQL opens a separate read-only connection with query_only, no extensions or
attachments, a five-second progress deadline, 10,000 rows, and an 8 MiB response
budget. Read commands use byte ranges and return base64 plus UTF-8 when valid.
A catalog-version mismatch drops the rebuildable projection and creates a new
epoch; provider evidence and mirrored raw files remain intact. Change cursors
carry schema version, database epoch and monotonic sequence;
30-day expiry requires a SQL snapshot and its changeCursor. Item and source
updates and their feed records share a transaction. Retention never deletes raw
provider evidence. The catalog, WAL, raw mirror and temporary copies share one
64 GiB cap and a fixed 20 GiB free-space floor. One storage lock serializes disk
mutations. Every flock lease explicitly unlocks before closing, so forked provider
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

The gateway's internal local_cluster adapter is deliberately local-only until
lane L's identity and link merge. Its replacement is the single integration seam;
no cluster transport, member credentials, or identity owner is duplicated here.
The CLI is `remote-coder-codex-gateway sessions`; `--local` and `--database`
permit gateway-independent reads. All output is JSON; errors go to stderr.

The installed skill catalog uses the user roots `.agents/skills` for Codex and
`.claude/skills` for Claude. Resolved paths deduplicate symlinks. The catalog
contains at most 10,000 skills; first_seen is the first catalog observation, so
newly discovered skills are excluded from claims about an earlier unused period.
