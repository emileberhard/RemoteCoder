# Host observability

Everything the host records lives under `~/Library/Logs/remote-coder/`. The
point is retroactive debugging: a session from days ago must be reconstructable
without a live listener attached. Verbosity is a feature; unboundedness is a
bug, so every surface below rotates after 30 days unless its row says otherwise;
there is no flag that turns any of this off.

| Surface | Path | What it holds |
| --- | --- | --- |
| Gateway journal | `journal/gateway-YYYYMMDD.jsonl` | Every frame in or out of a client, Claude runtime lifecycle, every push attempt |
| Gateway tracing | `codex-gateway.YYYY-MM-DD.log` | The `RUST_LOG` stream (INFO by default) |
| Managed app-server stderr | `~/.codex/app-server-daemon/app-server.stderr.log` | Codex/app-server errors, including persistence and tool failures |
| Desktop decisions | `desktop/desktop-YYYYMMDD.jsonl` | Every ChatGPT reconciliation: what it observed, the reason it chose, and every signal or relaunch that followed |
| Desktop helper | `chatgpt-shared-codex.log` / `.error.log` | The launcher's stdout/stderr — a bare startup banner, and the final error when a check fails |
| App logs | `app-logs/<device>/YYYYMMDD-<segment>.jsonl.gz` | The iOS OSLog stream, versioned MetricKit reports and [field telemetry](#field-telemetry), uploaded from the phone (14 days, 1 GiB in total) |
| Voice sessions | `voice-sessions/<started>-<thread>.jsonl` | Per-call transcripts, delegation lifecycle, latencies, close summary (newest 100) |
| Deployments | `deployments/*.log` | Install runs with their git commit (per-run entries kept 7 days, pruned by each app install) |
| launchd redirect | `codex-gateway.out.log` / `.err.log` | Startup banner and panics only |
| Relay tunnel | `relay-tunnel.log` | SSH errors from this Mac's relay tunnel ([relay route](relay-route.md#logs)) |

Codex rollouts and Claude project JSONL remain the canonical conversation
content. Title-decision traces additionally preserve the bounded model view
actually submitted, including its frozen title and any middle truncation;
a later transcript cannot reconstruct that exact request reliably.

The official ChatGPT clients are not gateway clients. ChatGPT on macOS talks
directly to the managed Unix socket, and the official iOS remote-control UI is
a cloud client of that same app-server thread. Their frames therefore do not
appear in the gateway journal. For macOS UI evidence use the Desktop helper
logs above and Apple's unified log (`log show --predicate 'process ==
"ChatGPT"'`). For an iOS display problem, reproduce the authoritative server
view with `thread/read` and compare it with the rollout before treating it as a
client-rendering bug.

### Why ChatGPT quit and reopened

`com.remote-coder.chatgpt-shared-codex` runs `runtime desktop launch` every 300
seconds, and stopping ChatGPT is one of its normal outcomes. It is the
RemoteCoder-owned component that does so, so an unexplained quit/reopen is
triaged here first — but a quit this journal does not account for is evidence
that something else on the host ended the app, not proof that no reconciliation
ran.

Its stdout log carries only a startup banner and its stderr only the final
error, and it shares the tracing file with the gateway — an invocation of the
helper and a gateway start both print `remote-coder-codex-gateway ... starting`
there. Neither surface says which branch a reconciliation took. The desktop
journal exists for exactly that: one `invocation` id per run, with the observed
pids and the chosen reason recorded *before* anything is signalled.

```bash
just gateway-desktop-journal --since 6h                     # recent decisions
just gateway-desktop-journal --since 3d --event decision    # just the reasons
just gateway-desktop-journal --invocation 4f1c9a2b --json   # one run, end to end
```

Exit status separates coverage from content: `0` matched, `1` read cleanly but
matched nothing, `2` read only partially or skipped corrupt records. A journal
that could not be read at all fails loudly rather than returning an empty
result, so an unreachable host is never mistaken for a quiet one.

Each run emits `desktop/started`, `desktop/version`, `desktop/observed`,
`desktop/decision`, then only the events its reason authorizes, and finally
`desktop/finished`. The `reason` vocabulary is fixed:

| Reason | Action | Meaning |
| --- | --- | --- |
| `healthy` | none | Attached to the managed app-server; nothing is touched |
| `app-absent` | launch | No ChatGPT process; Launch Services opens one |
| `environment-mismatch` | stop-mismatched | A readable process is provably on another daemon |
| `incompatible-version` | abort | The bundle does not carry the approved Codex version |
| `observation-failed` | abort | The host could not be read; the running app is left alone |
| `not-installed` | none | No ChatGPT bundle on this host |
| `disabled` | none | the private `~/.remote-coder/host-profiles.json` runs this host without ChatGPT Desktop |

`observation-failed` is deliberately not a mismatch. `ps eww` exits non-zero for
a pid that has gone away and can fail transiently under load, and the earlier
probe flattened that into "does not match" — which stops and relaunches the app.
Only a *readable* process on the wrong daemon may end a running ChatGPT.

Only a process whose command is exactly the ChatGPT app executable is a Desktop
instance, and only its own readable environment is evidence. A bundled
`codex app-server` can belong to ChatGPT, the managed runtime, the standalone
Computer Use bridge's `node_repl`, or another agent; the executable name proves
none of those, so its presence never stops, restarts or fails Desktop and it is
never a stop target. The earlier `private-app-server` rule treated "outside the
managed daemon's tree" as "Desktop fallback" and repeatedly killed ChatGPT and
the bridge's authentication helper on 15–16 September. The check guarantees the
app's managed configuration and runtime readiness; it does not probe whether
Desktop actually opened a working connection.

Each listed instance is identified by its pid, kernel start time
(`startedMicros`) and current executable, read together, so a pid reused by
another process is never adopted. A pid whose identity cannot be read fails the
listing (`observation-failed`) rather than counting as absent. A stop records
`desktop/stop` with its `authority` (`requested` for install, transition,
recovery cleanup and `runtime desktop stop`, or the reconciliation reason) and
every target's pid, start time and `evidence` (`requested`, or that pid's
observation). It sends the standard quit Apple Event (`method: quit`) so ChatGPT
runs its own shutdown and ends the helpers it owns. SIGTERM bypasses an app's
own termination path, which matches the `bare-modifier-monitor` processes that
replaced instances left reparented to launchd. Only a target that is still the
same process after 10 seconds receives `SIGKILL`. Identity is revalidated
immediately before every quit or kill; macOS cannot address a process by
identity, so only the instant between that check and the request stays open.
`desktop/signal` records each request's target identity, `method` and
`outcome`: `sent`, `target-gone` (nothing was sent because the pid no longer
holds the target) or `failed`. A stop fails with `desktop/stopFailed`
`reason: targets-survived`, or with `reason: unselected-instance` when an
instance it never selected appeared meanwhile; that instance is left running.

Reconciliation stops only the observed instances whose own readable environment
differs; matching and unreadable siblings are never targets. It then observes
again and records a second decision with `stage: post-stop`: an empty host is
relaunched (`app-absent`, `launch`), a matching sibling ends the run
(`healthy`, `none`), and anything else aborts with the sibling left running.

For acceptance, exercise Computer Use across a normal periodic reconciliation;
healthy ticks with no helper running do not cover this boundary.

`desktop/observed` records the expected `CODEX_APP_SERVER_WS_URL`, and for a
differing process the observed value plus presence flags for the obsolete
`CODEX_APP_SERVER_FORCE_CLI` / `CODEX_APP_SERVER_USE_LOCAL_DAEMON` controls.
Raw `ps eww` output carries the whole process environment — on these hosts that
includes live API tokens — and never reaches a record. The allowlist at the
call site is what makes that true; `sanitize_detail` only bounds and flattens a
string, so routing process output through it would still leak. Keep it that way
when adding fields.

An observation is only ever an attachment verdict when `ps` returned that pid's
recognizable command line. Blank, truncated or foreign output is `unreadable`,
because a line we cannot recognize is not evidence about what ChatGPT is
attached to. A recognizable line carrying *none* of the expected variables is a
real mismatch and still restarts the app.

`trigger` separates the launchd job (`periodic`, set by the plist) from a
hand-run check (`manual`) and from reconciliations the gateway starts itself
during an install, restart or recovery (`install`, `transition`,
`restart-abort`, `reconcile`, `recovery-complete`, `recovery-failed`).

### History projection integrity

Paginated history has two intentionally different stores: the rollout JSONL is
canonical, while `~/.codex/thread_history_1.sqlite` is a rebuildable read
projection. A live notification can make a client temporarily display work
that a later reload loses if that projection is stale. Diagnose that shape in
this order:

1. Read the canonical session with `agent-session summary <thread-id>` and
   `agent-session read <thread-id> --last-turns 8`.
2. Read the client-facing view with native `thread/turns/list`
   (`itemsView: "summary"`, limit 10) and `thread/items/list` (limit 50).
   Summaries omit intermediate messages; compare the item pages before claiming
   anything is missing. `./dev-tools/rc-gateway e2e-reads --thread-id <thread-id>
   --expect-fork` checks native cursor/identity coverage for a known fork and
   walks its items back to the start; `--claude-thread-id` does the same for a
   Claude thread. Avoid a full `thread/read includeTurns=true` on large
   histories.
3. Resolve the rollout path from `~/.codex/state_5.sqlite`, then compare its
   byte length and last ordinal with `next_rollout_byte_offset` and
   `next_rollout_ordinal` in `thread_history_projection_state` inside
   `~/.codex/thread_history_1.sqlite`.
4. Search `~/.codex/app-server-daemon/app-server.stderr.log` for the thread id
   and `durable rollout history projection failed`.

Do not repair this by editing the client cache or inventing a second history
path. Preserve the rollout first, stop its writer, repair the canonical ordinal
sequence if necessary, and let the projection catch up from its last valid
checkpoint. A paginated read retries projection before returning and reports a
persistent integrity error instead of successfully serving an older prefix.

### Gateway journal

Default-on, one JSONL file per UTC day, written by a single task fed through a
bounded channel — the hot path only clones a payload handle and returns, so a
journal write can never block, slow, or fail gateway traffic. A full channel
drops records and the writer reports the count in-band as a `journal_drop`
line. Retention is swept at rotation time, so a day change both opens the new
file and prunes expired ones; no cron is involved.

Every line is self-contained: `ts` (RFC3339 UTC with millis), `kind`, and
kind-specific fields.

- `transport` — `outboundFrameCapacity` records an oversized outbound text
  frame once: client, method, thread and actual/limit byte counts only. It
  contains no frame content. A correlated response receives a request-local
  capacity error; an uncorrelated notification/server request closes with 1009
  for canonical history recovery. The connection does not close for a response
  capacity error. Replay excludes oversized content under its existing bounds.
  `request_capacity` and `query_cancelled` record method, client, optional thread,
  resource and queue depth without request content. `query_timed_out` records a
  read that exceeded 60 s from receipt, including queue and account admission
  (`clientId`, `method`, `threadId`, `limitMs`, and queue depth when queued);
  the client got `requestTimedOut`.
- `notify` — a notification leaving the gateway: `method`, `threadId`,
  `turnId`, `source` (`codex|claude|gateway`), `clients` at broadcast (or
  `clientId` for single-client routing such as voice), and the full `payload`.
- `deliver_drop` — a client's bounded outbound queue rejected a frame:
  `clientId`, `method`, `reason`. This is the smoking gun for "the app missed a
  frame"; before the journal it was one log line that scrolled away.
  Unguarded forwarding, responses, marks/questions and unlocked call-state
  publications allow 100 ms for
  capacity in the 32-frame queue before dropping the connection. Guarded
  control/voice fanout and transition notifications use immediate bounded
  admission, so caller guards never wait on unrelated client capacity.
  Tracing records the attempted WebSocket Close (1013, or 4012 during a planned
  restart) and
  whether it was sent; a 750 ms deadline bounds a stuck writer. A sent Close
  is not proof that the client received it.
- `client` — `connect`/`disconnect` with the resulting connected count.
- `rpc` — client requests and their responses, passthrough Codex RPCs
  included. Requests carry `method`, `id`, `clientId`, `payload`; responses
  carry `ok` plus the `method` and `elapsedMs` of the request they answer,
  correlated by the writer so a response line stands alone.
- `transport` / `readPhase` — client activity reads, agent inventories and Claude
  header/list/settings phases taking at least 250 ms. Each record contains only
  `method`, fixed `phase`, `elapsedMs` and `completed`. `completed: false`
  records cancellation or an early error while that phase was active, including
  the phase dropped by a query deadline; it does not claim the dependency died.
  Activity distinguishes publication-lock wait from current-turn assembly.
  Background discovery and internal Claude header reads emit no read phases.
  Claude reads distinguish header/index work from runtime settings.
- `runtime` — Claude runtime `spawn`, `retire` (configuration change, idle
  timeout, idle cap, or release), `hold` (an idle retirement deferred for a
  pending scheduled wake, with `holdSeconds`), `stop`, and `billing_kill`,
  with model, effort, cwd,
  voice-backed flag, pid and generation. `spawn_refused` records a launch that
  would have started a fresh session under an existing id, with the reason.
  `input_stalled` (`threadId`, `pid`, `operation`) records a Claude that has
  not read its stdin for 10 s and keeps the process. The usual cause is an
  unanswered macOS privacy prompt, which the primary service host's resource watchdog reports. `full_disk_access`
  (`required`, `state`, `detail`) is the startup Full Disk Access probe that
  `/health.fullDiskAccess` also reports. The
  [scheduling owner](owned-operations.md#gateway-scheduling) emits
  `scheduling_restored` (`before`, `after`: `darwinBackground`, `basePriority`),
  `scheduling_demoted` and `scheduling_recovered` (`state`),
  `scheduling_guard_failed` (`error`), and `scheduling_qos_failed`
  (`qosClass`, `error`, once per process).
  Gateway restarts add `restart_capture` (`provider`, `generationId`, `account`,
  `itemCount` and one entry per recovered thread with `threadId`, `recoveryId`,
  `status`, `cause`, `attempts`, `backgroundTasks`, `scheduledWakes` and
  `queuedInputs`), `restart_suspend` (`provider`, `threadId`, and `exited` when
  its process group was reaped), `restart_codex` (`decision`: `preparedHandoff`,
  `suspend`, `idle` or `notOwner`) and `restart_codex_suspended`. The
  replacement journals `restart_dispatch` and `restart_dispatch_failed` per
  attempt, then `restart_resume` (`delivery`: `started`, `steered` or
  `alreadyInHistory`) or `restart_failed` with the error and `cause`
  (`restart`; migrated captures may retain historical `move` or `moveFailed`).
  Retired Claude enrollment redirects log each use at info with the ID and no
  prompt text. Migration receipts list sessions, preserved conflicts and archive
  paths. Filter one restart
  with `just gateway-journal --kind runtime --since 1h --json | jq
  'select(.event | startswith("restart_"))'`.
- `push` — every APNs and Live Activity broker attempt with its outcome,
  including skips such as `broker disabled`. Device tokens appear only as
  fingerprints.
- `devices` — `registered` (the device's ids, environment and token
  fingerprints) and `unregistered` records from `devices/register` and
  `devices/unregister`.
- `tool` — one agent tool dispatch: `tool`, `source` (`codex|claude`),
  `threadId`, `arguments` as an audit projection (identities
  and sizes, not what the model sent; `ToolCall::audit`), `outcome`, the `text` returned to it, and
  `elapsedMs`. Never the per-runtime MCP token.
- `question` — lifecycle transitions from the host owner: `reconciled`, `dismissed`, `dismissConflict`, and `unavailable`, with thread/item identities,
  epoch/revision or the recovery error where applicable. Ask alerts are deduplicated
  durably; old history reconstruction does not replay them. Canonical answers remain
  in the ordinary RPC/item journal, not a second copy of answer text. See
  `docs/async-questions.md` for recovery and isolated-probe receipts.

- `upload` — one `/uploads/<id>` request, keyed by the upload `id`: `stored`
  with the requested `name`, the absolute `path` on disk and `bytes`; `paused`
  with the `offset` kept and the `reason` the append stopped (the body ended,
  went idle, was superseded or the gateway drained); `rejected` with the
  `reason` the client received; or `discarded`. Never the file's contents.
- `speech` — one speech relay: `relayed` when an admitted relay ends, with
  `provider`, `operation` (the allowlist name, such as `realtime` or
  `streamGenerateContent`), `transport` (`http|webSocket`), `principal`
  (`operator` or the installation ID), `outcome` (`completed`, `clientClosed`
  including a client that stopped answering pings, or the rejection kind that
  stopped it), the upstream HTTP `status`, the WebSocket
  `closeCode`, `bytesUp`, `bytesDown` and `durationMs`; or `rejected` with the
  `rejection` kind for a request refused after authentication. Failed authentication is not
  journalled. Never keys, URLs, query strings, audio or transcripts.
- `app_logs` — `cap_evicted` when the uploaded app-log store went over its
  1 GiB cap and lost segments still inside the 14-day window, or `cap_unmet`
  when it is still over the cap afterwards: `files`, `bytes`, `retainedBytes`,
  `capBytes`, `unreadableEntries` (which make the total a lower bound),
  `evictedThroughMs` (the newest removed segment's mtime, or null) and `atMs`.
  An eviction also writes those fields to `app-logs/retention.json` for the
  reader.

- `review` — each automatic turn-review opportunity for Codex or Claude, each
  early title and each requested regeneration. `trigger` separates them:
  `turnCompleted`, `earlyTitle` (with `delayMs` and no judge fields) and
  `requested` (`turnId` null). An early title
  that could not start is a separate `earlyTitleSkipped` record with `reason`
  `capacity` or `checkFailed`.
  `traceId`, per-run `sequence`, host/account/provider/thread/turn identity,
  gateway version/commit and `policyVersion` correlate all stages. Policy version
  4 isolates the consumers and replaces done revision fences with settlement
  semantics. Version 3 added done suggestions; version 2 added the frozen user
  request and writer repair: `writerRepair` records an initial echo,
  `candidate.attempt` distinguishes the two answers,
  and `writerEchoedRejectedTitleAfterRepair` explicitly records a second echo.
  `request` and `response` preserve the actual Jev JSON body, prompts, HTTP status,
  upstream identifiers, byte hashes, elapsed time and reported usage/cost;
  unknown provider data stays null. Retried requests have separate `requestId`s.
  `decision` stores title probabilities and triggers plus `doneProbability`,
  `doneThreshold` and `probablyDone`. `doneMarks` records the requested
  `doneThrough`, whether it changed and the committed revision. `consumerFailed`
  records the title or done consumer, failure reason and error without stopping
  the other consumer. `sideQuestion`
  and `sideAnswer` hold the title question, the thread's answer, its elapsed
  time and, for Codex, the fork turn's token usage with cached input (Claude
  reports none, so it stays null); `candidate`,
  native revalidation, `renameRequest`, `renameResponse` and `renameReadback`
  explain what was proposed, applied and observed. `finished` records `kept`, `reviewed` (done only),
  `renamed`, `skipped`, `failed` or `abandoned` with a reason and a `consumers`
  object holding each consumer's outcome and reason. Busy slots,
  excluded threads, an unreadable router key, stale state and incomplete turns
  therefore cannot be mistaken for model keep decisions. A rename acknowledgement
  is distinguished from readback: a missing or failed readback is unknown, and a
  differing readback can indicate subsequent activity. Canonical naming
  notifications remain in the normal notification journal.

  Review payloads are an explicit exception to ordinary string/record elision:
  they preserve the exact bounded model input up to 512 KiB per record. Capacity
  elision and incomplete/non-UTF-8 responses set `payloadComplete: false`;
  credential substitutions set `redacted: true`. Authentication headers are
  never captured. Journal files are private (0600), including files reopened
  after an upgrade. They share the existing queue bounds, writer, shutdown drain
  and 30-day rotation. `journal_drop`, missing sequences or a missing terminal
  record indicate incomplete coverage, not a keep verdict. The gateway README
  owns the stage and model-policy details. These records are evaluation evidence;
  human labels or later corrections are still needed to measure quality.

Payloads are recorded whole, under two trimming rules. Any JSON string over
16 KB becomes `{"_elided": true, "bytes": N, "sha256Prefix": "…"}`, which
catches base64 images in `turn/start` inputs while letting deltas, diffs and
tool output through intact. A record over 64 KB additionally has its bulk
`result`/`params` member replaced by the same stub while the JSON-RPC
envelope (id, method, ok) survives — per-string elision cannot catch a
payload made of thousands of small strings (one day of bounded history
responses, since retired, was 377 MB of a 402 MB file), and rollouts
already hold that content in full fidelity. Response lines resolve their
method and latency from a pending map that survives client disconnect —
slow Claude RPCs routinely outlive their socket — with stale entries aged
out rather than cleared wholesale.

Query it with `just gateway-journal …` (or `./dev-tools/rc-gateway journal`),
which reads the day files directly over the same SSH-discovered host as the
rest of rc-gateway — no RPC and no running gateway required:

```bash
just gateway-journal --thread claude_abc --since 2h
just gateway-journal --kind deliver_drop,journal_drop --since 3d
just gateway-journal --method turn/completed --last 20 --json | jq .payload
just gateway-journal --follow
just gateway-journal --kind review --since 7d
just gateway-journal --trace <traceId> --since 30d --json
```

`just gateway-e2e-journal-live` runs one live Claude turn and asserts it lands
in the journal as `notify` lines for `turn/started` and `turn/completed`, a
matched `turn/start` request/response pair, and a runtime lifecycle line.

One gateway per host owns these files. A second gateway started by hand for
debugging appends to the same day file and tracing log; that is fine for a
short session but the records interleave.

### App logs

OSLog on the phone rotates away within hours, so by the time anyone asks about
a rendering, reconnect, scenePhase or Live Activity problem the evidence is
gone. `DiagnosticsOutbox` (`Core/Diagnostics/`) drains
`OSLogStore(scope: .currentProcessIdentifier)` — every subsystem and every
category the process logged, not a curated subset — into JSONL segments under
Application Support, then ships them to the host. Keep it that way: the host
copy exists so a future session can investigate a reported issue without
asking for a repro.

**Log levels decide what the host copy can see.** On iOS a `.debug` message is
memory-only: persisting it needs a logging configuration profile, and both
mechanisms for that (`log config`, the `OSLogPreferences` Info.plist key) are
macOS-only. `OSLogStore` therefore never returns a `.debug` record, so
choosing `.debug` is choosing invisibility — correct only for high-frequency
stream-path noise the gateway journal already captures better, and wrong for
anything else. In this app:

- `.notice` is the default and means "I want to read this back later". Use it
  for lifecycle, state transitions, decisions and outcomes.
- `.error` / `.fault` for failures, as usual.
- `.debug` only for per-frame or per-item logging on a streaming path, and
  only where the journal holds the same information. The existing exceptions
  are `GatewayClient.logWebSocketFrame`, its two notification-routing
  lines, and the three gateway-note sites in `ChatTargetModel`; each carries
  a comment saying why. Adding one is a
  deliberate decision, not a default.
- `.info` persists only while a log stream is attached, so it reaches the host
  copy erratically. Prefer `.notice` for anything you would want to find later.

Gateway frame decode failures record the text/binary opcode, byte count, header
or envelope decode stage, error kind and bounded coding path before closing the
connection. A prefix of at most 64 bytes retains JSON punctuation outside strings
only for valid UTF-8 without NUL bytes; other encodings are completely masked.
All string content is masked. Arbitrary coding keys and decoder
context/underlying-error text never enter the log. The client also logs expired receive
progress deadlines; its connection-owned ping task is cancelled and fenced on
replacement. A single wake loop checks scheduling delay between probes and
while awaiting pongs. Completed messages or pong callbacks normally extend its
four-second grace. An ordered `connection/largeFrame {bytes}` announcement
before text messages above 16 KiB extends the deadline to `bytes / 8,000 + 4`
seconds. The next completed application message ends it; pongs do not change
it. A stalled transfer still expires at that bound. Partial-frame bytes are
not observed. The existing 60-second writer and request budgets remain
independent; the announcement prevents false four-second reconnects only for
transfers that fit those budgets.
Backgrounding suspends probes; activation and delayed scheduler wakes reset
the normal grace while preserving an announced frame's original bound.

**Interpolated values need `privacy: .public`.** OSLog redacts dynamic values
by default, and reading your own process's store does not lift that — an
unannotated `\(path)` arrives on the host as `<private>`, which leaves the
message text and drops the one thing that made it worth logging. So every
interpolation in an app log call carries `privacy: .public`. The exception is
anything that could be a credential — tokens, API keys, `Authorization` values
— which stays redacted and is logged as a fingerprint instead, the way the
gateway does for push tokens. This is not a relaxation of
privacy: the gateway journal already stores full prompts and payloads on the
same disk over the same authenticated channel, so redacting paths and error
detail in the app's own uploads would protect nothing while making the host
copy useless for its purpose.

- **Cursor.** A drain resumes from the last drained date *plus* the signature
  of the last record emitted at that date. A date alone loses entries that
  share a timestamp, and re-emits the boundary entry; `AppLogResume` is a pure
  value so both behaviours are unit-tested. A drain streams the store and writes
  a segment every 10,000 kept records or 4 MiB, advancing the cursor and
  enforcing the queue cap per segment, so neither memory nor disk grows with the
  backlog.
- **Cadence.** Every 5 minutes while the scene is active, plus on launch, on
  foreground, and on background. Pending segments upload after every drain.
  `DiagnosticsLifecycle` owns one latest-state worker; superseded background
  drains cannot stop a reactivated pump, and host changes do not rescan logs.
  Overlapping outbox drains share one scan/upload pass. Each pass rescans the
  process's whole log store, because iOS `OSLogStore`
  ignores start positions and reverse enumeration, so its cost grows with
  process lifetime. The interval trades that CPU against the entries a crash
  or kill can lose: the store is process-scoped, so undrained entries are gone
  once the process dies.
- **Bounded.** 50 MB of undelivered segments on device. Over the cap, raw log
  segments go first, then telemetry batches, then MetricKit reports, oldest
  first within each; each segment actually removed becomes a `loss` record, and
  a cap the queue still exceeds is logged as an error. A MetricKit report is one
  record of whatever size MetricKit delivered, up to the queue cap, so its
  upload compresses it whole.
  A segment is deleted locally only after a 2xx, so a broken upload path
  retries rather than losing data.
- **Transport.** `POST /app-logs` on the gateway, bearer-authed like `/health`,
  body is gzipped JSONL, `X-RemoteCoder-Device` and `X-RemoteCoder-Segment`
  headers name the file. Foundation has no gzip writer, so `GzipEncoding`
  wraps Apple's raw DEFLATE in a gzip container — the host stores the body
  verbatim and `gunzip` has to read it back.
- **Host side.** `observability/app_logs.rs` reduces the device and segment names to one safe
  path component each (everything outside `[A-Za-z0-9._-]` becomes `-`), so a
  name arriving from the network can never escape the store. Bodies are stored
  unparsed after a gzip magic-byte check, with a 16 MiB per-request ceiling.
  Segments age out after 14 days; past 1 GiB for all devices together the oldest
  go first, which the `app_logs` journal kind and `retention.json` report.

Two rules that must not be relaxed: the app never logs the gateway bearer
token, and the uploader's own category (`AppLogExport`) is filtered out of
every drain — otherwise uploading a segment generates the next one.

**Reading it back.** The phone uploads to whichever gateway it can reach, so one
device's history is split across hosts. `just app-telemetry stores` lists every
device directory on this host and the configured gateway hosts (read over SSH);
`metrickit`, `diagnostics --symbolicate`, `counts`, `persistence`, `timeline`,
`activity` and `export-cost` take the exact `--device` and print JSON that names
the stores read and any that failed, and when the host cap removed data.
MetricKit reports and diagnostics are selected by the time they cover, not when
they arrived, and `metrickit` lists the window's present, missing and not yet
due daily reports.
Each segment is indexed once into a rebuildable cache under
`~/Library/Caches/RemoteCoder/app-telemetry/`, capped at 256 MiB, oldest first;
an entry goes when its segment does. MetricKit's daily entry is never added to
its subintervals, subintervals get no clock times, and per-foreground-minute
rates are labelled as normalizations because the daily totals include background
work. Persistence counters are cumulative per run, so the reader splits runs where
a counter falls. `scripts/symbols.py`, shared with `perf-trace`, matches retained
dSYMs and Xcode's DeviceSupport symbols by UUID. Raw records remain readable with
`gunzip -c ~/Library/Logs/remote-coder/app-logs/<device>/*.jsonl.gz | jq`.
A conversation switch leaves one `.notice` trail: `history select` (the tapped
address, outcome and what was on screen), `window select` (a target change),
`chat screen presents` and `transcript presents` (what the window actually
shows), and `drawer state`. A tap whose `transcript presents` never names the
tapped thread did not reach the screen.
Settings → Hosts → **Export logs** shares the raw segments off the phone when
it cannot reach a gateway at all.

### Field telemetry

The OSLog stream and MetricKit say what happened; field telemetry says what the
process spent while it happened, so a day of ordinary use can be read back as
CPU, wakeups and memory per app state. It complements Instruments and Power
Profiler runs rather than replacing them: it measures the RemoteCoder process
only, never WebKit's processes, and it cannot apportion battery to a feature.

- **Sampling.** `ProcessResourceSampler` (Core) reads `TASK_POWER_INFO_V2` and
  `TASK_VM_INFO`: user and system CPU in nanoseconds (converted from Mach time),
  interrupt, idle and timer wakeups, and the physical footprint. It samples on
  launch, every 30 s while a scene is active, on each state change (at least
  1 s apart), once on backgrounding and once on return. A change it could not
  sample at once marks the next sample `mixed`. It runs on the main actor, where
  a read takes microseconds, and hands each sample to a lock-owned
  `TelemetryBuffer` without waiting for the exporter, so samples carry the time
  of their read and lifecycle work never waits behind a log scan. It stops in
  the background, so nothing runs or wakes while suspended.
  P-core time, CPU energy and GPU time stay out until a device run validates them.
- **State.** `TelemetryContext` (app) projects the scene, the visible surface
  (chat or drawer), whether the shown conversation has a running turn, a voice
  call, thermal state and Low Power Mode, battery level, charging and
  brightness in 10 % steps (iOS), the network interface and the shown host's
  route. Each sample carries the whole state; an absent field is unknown.
- **Records.** `TelemetryRecord` lines go into `<stamp>-<id>-telemetry.jsonl`
  batches: a `run` header (`runID`, installation ID, model, app version and
  build, OS build, wall and monotonic anchors, `flushedThroughSeq`), then
  `sample`, `export` and `loss` lines with `schemaVersion`, `runID`, a per-run
  `seq`, `ts` and `monoNs`. Samples hold cumulative counters and the
  `PersistenceMetrics` snapshot; the reader takes the deltas. `export` records
  each drain's stage times (scan, encode, write, compress, upload), records
  scanned and kept, bytes, the footprint before, after the scan and after the
  upload (`footprintSampledMax` is the largest of those three, not the peak,
  which needs Instruments), and the whole-process CPU during the drain. Up to
  256 records wait in the buffer; a batch is written before each drain's log
  scan and after its export record, so an abrupt kill normally loses at most
  the last drain interval. An overflow keeps the newest and writes a `loss` line.
- **Reading.** `just app-telemetry timeline` merges sample intervals into
  stretches of unchanged state; `activity` sums them per state; `export-cost`
  totals the drains and their CPU share, counting only exports that lie inside
  a run's sampled span. Intervals are `incomplete` (records missing in between),
  `background` (all use from backgrounding until the return, sampler stopped),
  `gap` (no sample for 45 s while not backgrounded), `mixed` (a state change
  without its own sample) or `measured`, in that precedence, and only
  `measured` ones describe a single state. All of it is association: work that
  started in one state and finished in the next counts toward the next. Battery
  levels appear on timeline stretches only; a 1 % step lands in whichever state
  held when iOS reported it, so no per-state battery rate is computed.
- **Switching it off.** `perf-sim --disable resourceSampler` turns it off in
  `RC_PERF_HARNESS` builds for the overhead comparison. There is no user setting.

Decision summary (2026-10-24). The goal is to answer, for any hour in the last
14 days, which version, state and minute spent CPU, wakeups, memory or disk, and
what the telemetry itself cost, with a phone-side cost small enough to measure.
`DiagnosticsOutbox` owns durable batches, upload and loss records;
`ProcessResourceSampler` owns the Mach reads; `TelemetryContext` owns only the
state projection and its observation lifetime; `AppPerformanceDiagnostics`
stays the single MetricKit owner; `AppLogStore` owns host retention and the
byte cap; the reader owns its rebuildable index. Rejected: inferring battery
share from `task_energy` (CPU energy only), long-lived signposts per activity
(overlaps count twice), features reporting their own state, a file per sample,
and a new identity (the installation ID exists). Deliberate departures from the
reviewed plan: state rides on every sample instead of separate `context`
records, live web views come from the existing renderer logs, Settings is not a
tracked surface because its presentation is view-local, the network interface
comes from one path monitor in `TelemetryContext`, and on-device segments stay
uncompressed with their size bounded by the record cap. Costly to change later:
the record schema and identity fields, hence `schemaVersion` from the first
record. Next, once two days of `export-cost` exist: the log diet (raw
RemoteCoder, error and selected Apple records, per-minute counts for the rest),
then MetricKit activity states, operation signposts, per-purpose network
counters and gateway connection correlation, as far as the data still shows
gaps.

### iOS 27 performance reports and history timing

`AppPerformanceDiagnostics` owns one `MetricManager`, one consumer for each
report stream, and StateReporting domains
`emileberhard.RemoteCoder.history` and `emileberhard.RemoteCoder.connection`.
History states cover a foreground open or page load and clear when it finishes;
connection states describe the selected host. Stable metadata contains only provider and
cache/network mode. Volatile fields carry a local operation UUID and byte/read
counters; prompts, paths, credentials and conversation IDs are excluded.

Full Codable metrics/diagnostics are versioned JSONL envelopes from
`AppPerformanceReportRecord`, retaining receipt time, coverage and content hash.
`DiagnosticsOutbox` persists them atomically into the existing 50 MiB segment queue
before ingestion succeeds, deduplicates the latest 1,024 report identities across
relaunch/upload, and uses the same authenticated `/app-logs` uploader and Settings
export. Failed HTTP uploads stay queued. Unreadable or oversized compressed segments
move to an export-only state under the same queue cap, avoiding repeated gzip
work. Settings export skips unreadable entries and includes an explicit warning
record, while exporting healthy and oversized retained reports. Capacity eviction
is logged. A report beyond the 50 MiB queue cap fails
explicitly. No external analytics destination is introduced.

Immediate history evidence includes safe RPC method/bytes/elapsed time,
queue wait/source, decode time, cache hits, stream drops, and the
`HistorySelectionToFirstContent` interval. It runs from the tap to the first
visible message row, cached content included. MetricKit aggregates intervals by
name, so only opens that reach content end it; superseded, cancelled, empty and
failed opens are `HistoryOpenAbandoned` events instead. Apple metrics
are delayed and diagnostics sampled. State metadata annotates supported
hang/hitch/termination/runtime/signpost evidence; CPU, memory and network remain
interval metrics. An empty report stream proves no absence of failures.
Simulated ingestion and real sampled delivery are separate acceptance facts.

On the host, every Claude `thread/items/list` or `thread/turns/list` writes one
`claude history page` line to the gateway tracing log with the entry count,
response bytes, projection cache outcome (`hit`, `built` or `uncached`), and
the read and send time. A `built` read includes parsing the whole session.

### Device traces

`just perf-trace record <label> --device <UDID> [--seconds N]` records a
system-wide Time Profiler, Hitches and GPU trace of an iPhone or iPad on the
Mac mini, where the agent iPad is cabled (`--host` selects another Mac), and
prints a JSON summary: the app's CPU time by thread, Core
Animation commits per second, GPU time, hitches, and the render server's CPU and
GPU time, plus the recording's `endReason`; `record` fails when the recording
stopped before its time limit, such as on "Device disconnected".
`--swiftui` adds the SwiftUI instrument after a bounded, non-recording
`xctrace record --show-recording-options` capability check of that exact device
and template. Unsupported Xcode/device combinations fail with the check command
and a remedy before recording. A requested device SwiftUI trace also fails if
its guarded export finds no `swiftui-updates` for RemoteCoder; keep the app
foregrounded and exercise its views during the recording.
`just perf-trace summarize <trace>` re-reads an existing trace;
`--frames N` adds the N heaviest frames by inclusive time on the main thread and
on background threads, split into the app's own code (`appFramesInclusiveMs`)
and the system frameworks it runs (`systemFramesInclusiveMs`). `--callers REGEX`
attributes the time spent in frames matching the pattern, such as text layout,
to the nearest RemoteCoder frame that called them (`nearestAppCallersMs`).
`--frames` also adds `mainTopFunctionsSelfMs`, the main thread's leaf functions
by self time as Instruments' Top Functions view ranks them, with unsymbolicated
leaves named by their binary.

`motion` covers only the app's `TranscriptScroll` Points of Interest intervals,
which `TranscriptVisibility` emits while the transcript moves (interacting,
decelerating or animating, but not while a finger only rests on it) and closes
when the transcript disappears or is torn down: their seconds, the app's and
main thread's CPU time, the main thread's busy share, commits per second,
hitches by type and Apple's hitch rate in ms of hitch time per second of motion,
rated `good` up to 10, `warning` up to 25, `critical` up to 50 and `severe`
above that. A hitch counts only the part of it that overlaps the windows. With
`--frames` it adds the main thread's top functions inside the windows. Compare
runs by `motion`, not by whole-trace totals that include idle time and the
journey's setup. `motionUnavailableReason` says why `motion` is `null`: the
trace has no signpost table, or no interval completed. Inside `motion`,
`cpuUnavailableReason`, `commitsUnavailableReason` and
`hitchesUnavailableReason` replace metrics whose rows lack a timestamp or
duration, or whose table the trace did not collect; `app.cpuUnavailableReason`
and `renderServer.cpuUnavailableReason` do the same for samples without a
weight.

A trace is rejected (exit 1, after the JSON) when any app sample ran inside
XCTest's automation frameworks under `/System/Developer/Library/`. agent-device,
XCUITest and Xcode's device interaction take accessibility snapshots on the
app's main thread; on 2026-10-19 they made a fling look 70–90 % main-busy when
the app's own work was about 15 %. `app.automation` counts those samples and
their CPU time by thread; rejection rests on the count, so a sample without a
weight still rejects the trace. Drive measured journeys with `dev-tools/perf-sim`
or by hand, never with an XCTest-based driver, and close any such session before
recording.
Traces stay on
the GUI test host under `~/perf-traces/remotecoder/`. Compare two runs of the same
journey on the same build conditions; a single trace is not a baseline.

`just perf-trace record <label> --mac --seconds 60` attaches to the GUI test host's
Mac app, which must be the only process named RemoteCoder. The trace holds no
other process, so `renderServer` is `null`. `--swiftui` adds the SwiftUI
instrument, and the summary then adds `swiftui` from its `swiftui-updates` table:
update count, rate, types and the ten most frequent descriptions, since views
created before the recording can have no name. Both device and Mac summaries
also report `updateMs`, `updateMsByType` and `topDescriptionsByUpdateMs` from
the table's nanosecond `duration` column. These are summed, possibly overlapping
wall-time intervals, not exclusive CPU time. An unavailable duration makes its
type, description and overall duration unknown; counts remain available and
`updatesWithUnavailableDuration` reports the affected rows.
`swiftui` is `null` when the table is absent or holds no updates for the app.
The instrument does not capture every running Mac app (xctrace then warns
"Trace file had no SwiftUI data"), so a missing count is unknown, not zero.
`record --mac` also adds `top`,
the app's CPU and idle wakeups over the recording window, which `summarize`
cannot recover.

Every `xctrace export` loads the whole trace into memory, whatever table it
selects. On 2026-10-05, a 45 s system-wide Mac trace with the SwiftUI
instrument took about 40 GB per export. Two concurrent summaries then hung the
GUI test host into a watchdog panic. `perf-trace` therefore runs exports one at a time
and kills any export above a quarter of physical memory, or when less than 25 %
of memory remains available, or after 120 seconds. It allows one recording or
summary per host, and it refuses to start with less than half of memory available. A remote run stops,
including its xctrace children, when its SSH client exits or disconnects. Each
export reports its time and peak resident memory on stderr.
The export deadline runs independently of memory monitoring. Each `ps` or
`sysctl` probe has a two-second timeout; a failed probe stops the export rather
than letting it continue without monitoring.

`just perf-trace record <label> --mac --scroll --seconds 30` scrolls the
transcript for the recording minus a two-second warmup and tail, starting once
xctrace reports that it is recording. `dev-tools/mac-scroll-driver.swift` is
compiled on the recording host and cached by source hash under
`~/Library/Caches/RemoteCoder/mac-scroll-driver/`. It posts continuous pixel
scroll phases to the app's pid at the display's maximum rate, alternating down
and up at 900 px/s every 2 s (`--scroll-velocity`, `--scroll-swipe-seconds`),
at 65 % across and 45 % down the largest visible app window. It neither moves
the pointer nor activates the app. Open the same transcript at the same position
and window size before each run, and keep the parameters identical across builds.

The driver needs Post Event (Accessibility) permission for the process that
launches it and 10 s without pointer, key, scroll or gesture input
(`--scroll-idle-seconds`; `--force` skips only this gate). The any-event idle
time does not work here: the driver's own pid-posted swipes reset it. Over SSH, macOS may attribute the permission to sshd; do not grant
it there, because every SSH session could then synthesize input. Real input,
an exited app or SIGINT/SIGTERM/SIGHUP end the gesture and abort the scroll.
The bridge's guarded session consumes synthetic input from other processes,
Peekaboo's included, so scripted scrolls need a Mac the user unlocked.
`<label>.scroll.json` keeps the driver receipt:
times, parameters, window, posted events and status. Posted events do not prove
that the transcript moved.

`dev-tools/scroll-cadence-report <video> --crop x:y:w:h` measures scroll motion
in a screen recording (`screencapture -v`). It reports how far the transcript
crop moved between recorded frames, the frame intervals in vsyncs at
`--refresh-hz` (120 by default), skipped frames, judder and the effective frame
rate while moving. The recorder writes a frame only when the screen changes, so
calibrate against a known smooth scroll before blaming the app for gaps.

`app.hitchesByType` groups the Hitches table's Potential Issue column
(`narrative-description`) into `commit`, `render`, `commit+render` and
`unknown`; `hitchIssues` keeps the exact texts. They are the instrument's
suspected causes, not proof.

`app.presentedFrames` leaves presentation cadence (median, p95, 120/60 Hz
deadline shares, frames per second) `null`: no table in the inspected Xcode 27
traces covers every app presentation. `frameWait` reports what the trace does
hold: frame-wait durations and the intervals between observed wait ends, per
display, for the whole trace and for the scripted scroll. They are a subset of
frames, not the frame rate.

The summary symbolicates frames itself and never rewrites the trace. It matches
each image's UUID in the trace to the retained dSYMs under
`~/Library/Logs/remote-coder/deployments/` (device and Mac installs from the last
seven days and the newest of each kind, plus the newest ten TestFlight archives
as `testflight-<platform>-<version>-<build>`, which the release lane keeps on the
primary service host and the GUI test host catch-up mirrors onto the GUI test host) and to the shared-cache symbols Xcode
extracts into `~/Library/Developer/Xcode/iOS DeviceSupport/` when the phone first
connects to it, then resolves addresses with `atos`, including inlined frames.
A build without retained dSYMs, such as a `dev-tools/perf-sim` build, is
matched by passing its `RemoteCoder.app` with `--symbols`; simulator images
resolve from their own paths on the host, except those in the simulator's
shared cache.
Images with no UUID match are named on stderr and keep whatever names the trace
recorded. `xctrace symbolicate` is not used: traces recorded by Xcode 27.0
(27A266a) keep symbol stores only for Instruments' own device agent, so it
reports "No dSYMs were found or relevant to this trace" even for a matching dSYM.

The iPhone must be unlocked: `xctrace` reports "Waiting for device to boot" for
a locked device, and iPhone Mirroring only connects while the phone is locked, so
a journey cannot be driven through Mirroring and traced at the same time.
`xctrace --attach` does not find the app by name or pid over USB, which is why
the recorder traces all processes and filters to RemoteCoder.
