# Persistence and idle energy

History pages persist RPC result content rather than request IDs. The typed
response decoder validates the envelope once; a structural byte scan then retains
the exact result slice, including unknown provider fields, number spellings and
opaque cursors, without a second JSON object graph or serialization. Typed re-encoding would
lose unknown fields, so JSONDecoder remains the validator and the byte scan
only locates the retained span. Duplicate
result keys are rejected. Existing canonical JSON cache entries remain readable.

The assembled tail window is the one durable tail representation. Its raw
cursorless item/turn pages use only the existing bounded memory cache; older
cursor-addressed pages remain independently durable. Refreshing a cursorless
page removes its obsolete disk copy, including files from older app versions.
The window's persisted content uses fixed page freshness timestamps and sorted
keys, so freshness alone cannot rewrite it. Actual freshness remains in the cache
envelope and memory; a cold restore is conservative. Failed replacements keep the
last-good file and retry on the next save. Cache access recency is memory-only.

Page byte budgets use the result bytes already received rather than encoding
every decoded item and turn again. Pages changed by overlap still remeasure their
retained content before enforcing the window budget.


An optimized macOS Core workload (50 synthetic items, about 480 KB, one initial
read and 20 unchanged forced tail refreshes) reduced logical persistence from
23 writes / 10,709,397 bytes to 1 write / 486,769 bytes. Process CPU fell from
71.609 ms to 31.267 ms. Both runs used SwiftPM Release on the same machine;
these measure this path, not device energy or physical flash amplification.
The regression also verifies changed replies survive a cold read, independent
older pages keep exact unknown fields and cursors, and invalidation removes
both memory and disk state.

Conversation persistence revisions are separate from presentation revisions.
Clean flushes skip serialization. One owned task coalesces remote checkpoints
over five seconds during an active turn and one second while idle; terminal
events and local submission/receipt changes
commit immediately. Submissions remain durable before dispatch. Generation checks,
local-only records, unreadable-file preservation and cold restore remain intact.

Checkpoint generations come from one monotonic store counter. The session registry
releases them after a session is no longer retained; active operations and failed
invalidations keep their fence state. Completed invalidations persist one SQLite
row while a rollback source exists, protecting it from re-import without retaining an
in-memory fence. Pending cleanup retries before new records are admitted; completed
cleanup never deletes a later durable submission. Invalidation compacts freed
pages before publishing completed cleanup. A successful save clears the row;
later cache eviction retains a compact row when a rollback
source still exists, so that source cannot reappear after a rebuild.
Markers count as protected bytes in warm and cold disk accounting. They are
outside primary admission, so invalidation always frees state even at capacity.
Warm access and cold indexing reclaim a marker once its rollback source is gone;
the marker count is bounded by the retained sources. Reclamation preserves any
later durable submission. An existing thread with no checkpoint still requires
an authoritative history read before an empty checkpoint can be saved.
Session-creation epochs follow the same lifetime. A pruned generation is never
accepted again. Active checkpoint operations also pin their files against budget
eviction until they finish. An invalidated empty restore keeps history unknown and
waits for the authoritative read before saving an empty checkpoint.

The evictable-history target is 64 MiB. Non-rebuildable data has a separate
512 MiB admission cap per host/account: local records, unique presentation and
attachment data, submission sidecars and protected recovery bytes. Confirmed
remote items and history never consume that cap. Pressure sheds rebuildable
history from mixed checkpoints; reopening fetches it from the host. Pending
images remain protected. A matching canonical image releases the duplicate
local bytes. Settled images missing from canonical history are shed oldest-first
by message date before capacity refusal, retaining their attachment identity
and an explicit unavailable-image state.

The store requires that policy explicitly. Admission checks the projected total
on its actor immediately before publication, with no intervening await. A typed
capacity error preserves primary data, stops send/queue dispatch, appears through
the existing message-save error with the draft intact and journals once. Pending
charges retire on canonical settlement and sidecar absorption; subsequent sends
can proceed as soon as space is available. Unknown bytes count by their stored
footprint. Residual JSON and submission copies keep their charge until deletion
succeeds, including after restart. Existing over-cap data remains readable. A readable retained timeline import also
opens at capacity: unpublished local records stay charged to their source, and
history is fetched normally. The source remains intact until publication succeeds;
its provisional charge retires on publication, invalidation or source removal.

Fully decoded content determines preservation; a redundant protection flag
cannot hide local records or make readable content fail. An unreadable source is
preserved in owner-scoped recovery storage before a fresh active checkpoint can
replace it. SQLite recovery publishes a copy of the exact main/WAL/SHM file set
before closing the active connection; JSON recovery moves the source. Generation
and source-identity checks reject stale decode failures. An unreadable retained
rollback source is copied without changing the rollback file. Recovery bytes are
never automatically deleted. Readable sidecars remain usable, and opening still
fetches authoritative history. Recovery journals one notice without content.
Revision metadata retires with its fence and cached connection; active operations
keep the revision comparisons they need. Submission admission also checks the
persisted revision for that message, preserving distinct pending submissions and
rejecting an older replacement after memory metadata retires.

Send admission writes a small atomic submission record through
ConversationCheckpointStore. It stores the exact client message identity and
input without encoding retained history. Cold loading combines newer records
with the canonical checkpoint and leaves their delivery uncertain. A successful
checkpoint retires a record only when its client identity and content are absorbed
and its revision is covered. Distinct client IDs restore even below the checkpoint's
revision. Newer records remain protected; conflicting payloads move to recovery.
Canonical absorption compares the dispatched trimmed text and the encoded message
after canonical image normalization, retaining the exact local presentation.
Unreadable records move to recovery while readable submissions and
new input remain durable. The regular checkpoint cadence and immediate
acknowledgement saves remain unchanged.

Checkpoint saves use system SQLite behind the same actor. Each conversation has
one WAL database with a bounded sixteen-connection cache. A transaction replaces
changed metadata, turns and item payload chunks, then removes obsolete records.
Unchanged turn and history stamps avoid re-encoding settled text. WAL checkpoints
run automatically at 256 pages; no periodic vacuum or connection-per-save path
is introduced. Auxiliary WAL and SHM files retire when the last connection closes.
FULL synchronization preserves the durable commit boundary.

Existing JSON checkpoints remain readable. The first changed save commits the
complete imported state before removing its JSON source. A failed import leaves
the source intact and remains retryable. Coexisting JSON contributes local records
by identity, regardless of its revision relative to SQLite. Disjoint records are
committed together before JSON cleanup. Cleanup proves that its local payloads
are present in the committed checkpoint; otherwise the exact JSON moves to recovery.
Local item absorption compares encoded durable payloads, including image bytes,
format and dimensions, independently of UI equality.
Conflicting local payloads preserve the SQLite file set in recovery and reopen
the JSON source. Recovery copies remain protected but are not shown in the transcript;
they require explicit inspection. Unknown database schemas and malformed
records remain protected from eviction and move to recovery before replacement.
The v2 header must leave turns, submissions and history empty; those payloads
belong in split records. A populated header is preserved as malformed input.
PersistenceMetrics byte counts represent
changed payload chunks; process logical-write measurements also include SQLite
pages and WAL checkpoints. File protection remains until first authentication.

Mac quit closes chat and composer admission synchronously before waiting. The
existing owners cancel and drain gateway delivery, dispatch, history navigation,
question commands and dictation. Drains include cancelled predecessor tasks and
externally retained conversation sessions and host retirements already admitted
at quit, so final saves follow every admitted mutation. Captured dictation audio
remains recoverable when transcription is
cancelled; a completed admitted transcript can still enter its draft.
Admitted sends and draft transfers retain their reservations until persistence
and cleanup settle. If quit or cancellation closes dispatch while the sent draft
is being saved, the exact durable message remains with a failed receipt and its
original text. Keep Open does not dispatch it automatically.

Final flush returns failed host/category names for drafts, checkpoints, marks
and voice history. After five seconds, any still-pending operations also appear
in one native alert offering Keep Open or Quit Anyway. Keep Open waits for the
same admitted work to drain before reopening intake and activating the existing
reconnect path. Quit Anyway keeps intake closed and accepts incomplete work.
A SIGTERM, as the installers send, gets no alert and dismisses one already
shown: it waits up to sixty seconds, then quits as Quit Anyway would.
Both the
failure and the chosen outcome are logged. Real target retirement remains
terminal and independent of reversible quit quiescing.

The phone requests completion metadata with thread/list instead of downloading
turn summaries for sidebar sorting. The native canonical history owner respects
fork cutoffs, rollback and same-second completions. Missing evidence is distinct
from a known empty result. Recurring list refresh runs only while the drawer is
open; host sockets, running turns and voice calls retain their existing ownership.

PersistenceMetrics aggregates logical writes, bytes, skips, failures and duration
by writer through the existing log pump. There is no per-write logging or new
timer. Diagnostic writes alone do not trigger reports. SwiftData physical byte
counts remain unknown, not fabricated.

Physical development installs default to optimized Debug builds. Select
`just optimized=false install-dev` for breakpoint-oriented debugging. Actual
compiler settings and bundle identity are verified before installation. Each
build has a unique number and source identity, with matching binary UUIDs and
symbols retained privately. Device version/build readback and launch are separate
verification steps. The bundle identifier and user data do not change.

Regression tests cover unchanged file bytes/inodes/timestamps, conservative cold
freshness, failed-save retries, clean checkpoint restores, revision races,
same-second completion, unknown metadata, fork lineage and matching symbols.
Reduced app writes are not a guarantee that unrelated iOS media processing or
other sources of device heat have stopped.

## Memory pressure

Memory-pressure cleanup releases each host's decoded image-preview cache and the
workspace renderer's unused HTML visual rasters. Displayed or preparation-pinned
rasters stay available. Mounted image rows retain their displayed preview, including
cache hits, so cache cleanup does not replace visible images with placeholders.
Preview loads admitted before cleanup can still deliver
their image to the caller, but cannot refill the cleared cache. Small image-size
metadata and persisted visual snapshots remain available for layout and reload.
On macOS, a retained Dispatch memory-pressure source delivers warning and critical
events to the same cleanup owner on the main queue; iOS uses UIKit's warning.

## Deployment and validation

The native completion-metadata companion is committed on the private Codex
fork's main branch and deployed through the tracked recovery transaction to both
Macs. Live list metadata matched terminal history on three conversations per
host; read-only pagination probes passed independently on each host.

The iOS regression suite checks unchanged cache and header file identity,
failed-write retry, clean/cold checkpoint flushes, durability before dispatch and
concurrent persistence revisions. A repeat exposed an existing scheduler-test
poll loop that exhausted 100,000 yields in 128 milliseconds; the test now uses a
five-second monotonic deadline with asynchronous sleeps rather than a CPU-speed
iteration budget. No production scheduler behavior changed.

Direct local installs record source provenance when they were not launched by
the snapshot worker, and preserve an existing worker identity when they were.
The installer checks actual optimization settings and UUID-matching symbols;
a requested optimization flag alone is not installation evidence.

Historical deployment receipts and device readbacks stay in the private operator
archive. They establish installation only, not a measured reduction in heat or
battery drain; unrelated system-media workload is independent.

## Question refresh amplification

Post-install owner counters exposed a separate source of writes: successful
question-status rereads advanced the host's observation revision without changing
any question records. The client persisted that bookkeeping change as a complete
conversation checkpoint. In one captured interval no turns completed, while
question-state notifications and empty ready inventories continued arriving.

The conversation owner now keeps observation revision and connection coverage in
memory. Only changed question records/epochs or local receipts and dismissals
mark its checkpoint dirty. Coverage transitions still update the UI immediately;
a cold restore still requires authoritative question refresh before actions.

The host retains an already verified, quiescent question snapshot for at most ten
seconds without retaining a provider subscription. Relevant source invalidation,
a connection generation change, or expiration requires reconciliation. This
prevents completion of an unloaded read from immediately causing another scan in
response to its own notification, without making stale state indefinitely fresh.

Regression coverage uses a large retained conversation and repeated empty ready
inventories with advancing observation revisions: checkpoint bytes, inode and
modification time must not change. A genuine question still persists. Host tests
cover repeated unloaded reads, expiry and invalidation inside the freshness window.

Historical deployment receipts, live readbacks and device acceptance remain in
the private operator archive. Verify current behavior through the focused
regressions above; old installation evidence is not current acceptance.

Checkpoint phase and input/changed-payload aggregates use the existing bounded
`PersistenceMetrics` owner and JSONL samples. See
[Checkpoint save phases](host-observability.md#checkpoint-save-phases) for fields
and interpretation.

## Exhausted checkpoint history

Over-budget saves can revisit preserved conversations even when all rebuildable
history has already been removed. `DiskRecord.historyExhausted` remembers that
proof at the checkpoint owner, so later saves skip inspection and decoding.
Loads clear the proof before reading: an admission-limited rollback restore can
return early without replacing its disk record. Writes and invalidation clear the
proof through `sourceChanged`. Recovery-only protection can also prove exhaustion.
Failed inspections remain unknown and retryable. No storage format or retention
policy changes, and unique local records, pending sends and recovery bytes stay
protected. Inspection already reuses an owned database connection when available.

Decision (2026-10-25): keep one transient bit with the existing disk accounting,
rather than retaining decoded checkpoints or adding a connection/cache owner.
The bit lasts only until an owner-observed source change or load. Repeated failed
reads are deliberately not cached; any later identity-based backoff must preserve
retry after the source changes.

Optimized MacBook measurement (SwiftPM Release/`-O`, serial cases, schema 1):
four preserved conversations each started with a 1,114,112-byte pending message
and 1,179,648 bytes of remote-message text. A one-byte cache budget forced repeated
pressure after the history was shed; primary admission remained 512 MiB.
The table excludes the first save and reports the median of eleven repeats.

| Store | Before memo | After memo | History inspections per repeated save |
|---|---:|---:|---:|
| Warm | 21.286 ms | 0.851 ms | 4 → 0 |
| Cold-opened, after its first save | 20.587 ms | 0.856 ms | 4 → 0 |

Warm ranges were 20.347–21.808 ms before and 0.807–1.262 ms after; cold-opened
repeat ranges were 19.751–21.235 ms before and 0.795–1.248 ms after. The first
cold save still inspected/indexed existing files: 92.908 ms before, 80.899 ms
after. These are synthetic host measurements, not phone energy acceptance.
The three owner regressions fail with the memo disabled, including recovery-only
protection, and cover retry after a failed inspection plus proof reset on load
and write. Benchmark clocks, prints and serialization are not retained in tests.

## Deferred content-defined checkpoint chunks

`checkpoint-cdc` is an unshipped prototype for reducing changed payload bytes on
older-page prepends and early edits. Schema 1 remains the shipped format. The
prototype's schema 2 is currently unsafe for rollback: an older reader treats it
as unreadable, moves the original into recovery and discards the canonical file;
a later upgrade does not re-import those unique local records.

Before a later PR:

- Record the decision and obtain an independent architecture challenge. Keep the
  database as the chunk/reference/transaction owner and validate the costs of
  chunking, hashing and SQL separately in optimized, serial measurements.
- Roll out in two releases: first read schema 2 while still writing schema 1;
  only a later release may write schema 2, once every supported rollback build
  can read it. Preview/branch installs and both Mac app builders are rollback
  consumers too. Track that boundary in the
  [compatibility register](compatibility-register.md#planned-checkpoint-database-rollout).
- Reclaim migration space once with `VACUUM` and `wal_checkpoint(TRUNCATE)` before
  budget eviction uses the migrated disk total. Migration currently roughly
  doubles counted bytes and can evict offline caches. This one-time format
  transition does not justify vacuuming on ordinary saves.
- Replace global unreferenced-chunk scans on every save with collection of only
  hashes formerly held by changed or removed record rows.
- Frame the later change and its title around prepends and early edits, rather
  than 436a281's streaming-delta title: the measured six-byte streaming save
  remains 31,002 changed payload bytes. Keep the existing prototype commits
  unchanged and reword when preparing the later PR.

Image admission (`preservedImageEvictions` and `oldestSettledImage`) also decodes
image-bearing items on saves/loop passes. This is separate follow-up work if the
new admission phase measurements show a material cost.
