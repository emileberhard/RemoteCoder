# dev-tools Agent Context

Maintainers: configured hosts, devices and private operational prerequisites live
in the [private operations entrypoint](https://github.com/emileberhard/RemoteCoder-deploy/blob/main/AGENTS.md).

Debug tools for the RemoteCoder gateway (JSON-RPC over WebSocket) and the app's
performance and voice checks. `--help` on each tool is its command reference;
this file holds the contracts `--help` cannot: what a result proves, what a probe
leaves behind, and which invariants a change must keep. `README.md` lists the
tools. `host-daemon-rs/AGENTS.md` (*Verify*) maps each gateway surface to the
probe that exercises it, and gateway-only methods and wire contracts live there
and in `docs/system-architecture.md`.

The Python tools are one locked uv project (`src/remotecoder_tools/`, wrappers in
this directory). Update dependencies deliberately with `uv lock --project
dev-tools` and warm a wrapper with `--help` before unattended use.
`just tools-test` and `just gateway-check` run every `tests/test_*.py` through
`just dev-tools-test-local`, so a new test file needs no wiring.

## Query admission probe

`just gateway-e2e-query-admission-isolated /absolute/gateway/binary` runs
`probes/query-admission.mjs` against its own gateway, Codex daemon, private state
and stub launcher. It checks a burst of owned reads, exact cancellations, the
advertised capability and a usable connection afterwards. It stops its own
processes and removes the private root on success; failure retains the root as
evidence. It never connects to an installed gateway or starts an agent turn.

## Delegated-job isolation probe

`bun dev-tools/probes/delegated-jobs.mjs <candidate> <matched-runtime-package>`
uses `IsolatedGateway`, a loopback Responses model, and isolated provider homes.
Its Claude child uses the host router without copying provider credentials.
It checks running-job messages through the candidate CLI while the native model
response is held, then requires the stable message ID and body in that original
turn's canonical items and model input after release. Same-ID requests retain
their receipt. It also checks message-to-finished continuation deduplication and
failure receipts through the candidate CLI, including isolated gateway restart.
A native continuation of a completed Codex job also sets its title and sends a
parent message through the inherited scoped endpoint; the original parent's
canonical items must contain the exact delivery ID.
It also copies its completed Claude probe child's transcript into a deleted-cwd
fixture, resumes that exact session through RPC, and requires both the unique
input UUID and the new response in that same copied transcript. This fixture
changes the first user cwd and project directory; it never executes a copied
historical task. A second stage marks only that completed lab job imported with
unknown settings, preserves its known conversation and scope, then continues it
through the real installed candidate CLI. Its exact input and response must
appear in the same copied transcript.

Optional `--seed <absolute-private-manifest.json>` checks copied conversation
agent projections through real RPC. The version-1 manifest has `snapshot: true`,
`jobStore` (relative directory with bounded `jobs`, `agents`, `uncertainties`),
`transcripts` (`threadId`, relative `path`), and `queries` (`threadId`,
`expectedAgentIds`, optional `warningContains`). Capture the selected jobs,
continuation branches and ancestors outside Git; include matching agent records
and every job referenced by their origin and latest pointers.
Provider homes and directory/transcript references are remapped into the lab.
Copied jobs become imported snapshots with Stop intent cleared, preventing the
job driver from executing historical work. The receipt names these alterations:
this proves static projection and isolation, not historical execution state.
The probe verifies the copied job records remain unchanged during reads.
It then runs the actual configs worktree cleanup planner as a dry run, routing
only its two gateway clients to the isolated candidate. The receipt requires
known activity and no applied deletions; the planner keeps the real home context.

## rc-gateway

- **Config discovery:** CLI flags, then `RC_CODEX_GATEWAY_*` env vars, then the
  selected host's `~/.remote-coder/codex-gateway.env`, then the ignored
  `RemoteCoder/Resources/RemoteCoderLocalConfig.json`. Explicit SSH targets
  always use noninteractive SSH with a ten-second read deadline. With no host
  selection, discovery and journals read this machine directly, and the endpoint
  defaults to `127.0.0.1`. A named gateway
  selection uses the JSON's primary host/secondary host hostname fields and reads locally only
  for an exact OS or local Tailscale identity match; see `README.md`. A missing
  configuration reports the discovery error without printing credentials, and
  `config` redacts the token. A deploy runs `rc-gateway e2e-reads` without
  arguments on a host that deploys itself and with `--host`/`--ssh-host` for a
  remote target (`scripts/shared-codex-host`), so prove a change to that default
  by running it without arguments on both hosts.
- **Exit status:** a turn command succeeds only after the matching
  `turn/completed` reports `status: completed`, so a failed or interrupted turn is
  nonzero and a scheduler never records it as success. `turn` and `claude-turn`
  accept `--event-log PATH` for a JSONL lifecycle trace. `rpc` prints the matching
  response, including a JSON-RPC error, and exits 0. It exits 75 (`EX_TEMPFAIL`)
  with an `error:` line for a transient connection failure (refused, reset or
  timed-out before the request is sent, an upgrade answered with 5xx, or a close
  with code 1001, 1012, 1013 or 4012); callers may retry, and a `claude/message` retry reuses its `deliveryId`. Every other failure
  exits 2. A 409 is a permanent rejection with the gateway
  response body. Turn connection
  setup failures, including configuration discovery before opening a socket,
  write `dispatch.not_started` and their retryability to the event log. TLS identity
  discovery preserves retryable health connection refusal/reset, timeout and 5xx
  failures; rejected authentication and malformed identity remain permanent. So does a thread/turn request the gateway refuses before dispatch: a
  JSON-RPC error with code -32600..-32602, -32001, -32002, -32003 or -32009 and no
  `data.kind` ending in `Uncertain`/`Unknown`; `data.retryable` wins, else the
  -3200x codes are retryable. Any other failure after handoff, including -32603
  (Claude can fail after writing the prompt), stays uncertain.
- **Fresh admission:** `thread/start` owns the selected harness, model provider,
  model and effort. Turn commands use its returned thread identity and settings
  for `turn/start`, including fallback across harnesses. Exact resumes retain
  their explicitly selected settings and provider. Restricted Codex requests
  cannot execute through unrestricted Claude. Provider acceptance probes refuse
  admission to another harness before submitting a turn; their resumed turns
  inherit the admitted thread model.
- **Streams:** `turn` filters events to its own thread (`_event_thread_id` in
  `src/remotecoder_tools/rpc.py` is the one place that finds a notification's
  thread) and `listen` takes `--thread-id`. Stored notifications carry
  `rcSequence`; unstored streaming methods, responses and server requests do not.
- **`active-turns`** calls `daemon/activeTurns`. Inspect `coverage` before treating
  an empty result as authoritative: a provider reporting `false` has not
  established its passive inventory yet.
- **`steer`** discovers the exact active turn id from `daemon/activeTurns` (5 s by
  default). Unavailable inventory stays unknown, no matching turn is a clear
  error, and the gateway rejects a steer that arrives after the turn completed.
- **`proxy`** is the gateway's counterpart of `codex app-server proxy` for
  clients that speak the app-server protocol on stdio, such as the agents
  launcher, so their threads pass the gateway's provider admission. Client lines
  go out verbatim and the client owns `initialize`/`initialized`; gateway
  messages come back one JSON object per line through the same reader that
  consumed `ready`, so request IDs and server requests are untouched. stdio must
  be pipes or sockets (asyncio pipe transports, no reader threads) and
  diagnostics go only to stderr. stdin EOF or a closed stdout reader closes the
  socket normally and exits 0. A gateway close flushes queued messages for up to
  five seconds and exits by the `rpc` rule above (75 for a retryable close or a
  transient setup failure, else 2); a stdout still blocked after that grace is
  aborted. The closing diagnostic is one bounded, best-effort stderr line, so
  the exit status is authoritative. A reader more than 1024 messages or 8 MiB behind fails with exit 2
  instead of dropping messages. After 75 the client reconnects and resumes its
  thread; the bridge never replays a request.
- **Wire notes:** method, item and enum shapes are not copied here. Read the pinned
  schema (`CODEX_BIN=<candidate>/bin/codex just codex-schema`, the fork's
  `codex-rs/app-server-protocol/` and the root `AGENTS.md`, *Protocol drift*).
  `sandbox` on `thread/start` and `thread/resume` takes kebab-case (`read-only`,
  `workspace-write`, `danger-full-access`) and rejects camelCase with -32600, while
  the `sandboxPolicy` object on turn requests is a separate wire type. `turn/steer`
  fails with `NoActiveTurn` or `ExpectedTurnMismatch` rather than queueing. Render
  from `item/*` and `turn/*`; the `codex/event/*` duplicates are legacy.

### Live probes

Each `e2e-*` command drives a real agent. Read `--help` for options and the
receipt shape, and note what each leaves behind:

- Every probe marks each thread it creates, forks included, with the `probe`
  purpose right after `thread/start` or `thread/fork`, so its completions are
  never unread and the drawer hides it unless it is running or selected.
  `turn` and `claude-turn` take `--purpose probe|automation` for the same mark
  on a new thread; schedulers pass `automation` (`codex-threads start
  --purpose`). A probe that creates threads another way must mark them too.
  `e2e-files-live` is the exception: its conversations stay visible for
  opening the files on the phone.

- `e2e-reads` is read-only. `e2e-fork-live` and `e2e-claude-fork-live` leave their
  source and two forks in history. The Codex `e2e-thread-name-live` probe thread
  is archived; the Claude session stays in history like the other Claude probes.
- `e2e-device-tools-live` issues a temporary installation through the owning
  host's credential CLI (`--ssh-host` must name that gateway host), then uses
  its authenticated socket as a fake iPhone. It creates one hidden turn per
  provider, returns a JPEG and uploaded original, verifies the visual
  description, one dispatch/invoke in the journal and the saved original's
  SHA-256. Cleanup revokes that installation and removes its private token file,
  including after failed or uncertain issuance. It uses the already running
  gateway and subscription stores; never copy provider logins into a lab home.
  Run after gateway deployment. This proves transport and inference, not the
  physical camera or Voice Mode audio behavior.
- `e2e-upload-live` is the acceptance probe for attachments: a `201` proves
  storage, not the handoff, so a live agent on each provider must read the file at
  the absolute path the prompt names. `attached_files_block` in
  `src/remotecoder_tools/probes.py` must stay byte-identical to the app's
  `AttachedFilesPromptBlock`. `protocol-fixtures/attached-files-block.json` holds
  the expected block and message, and `protocol-fixtures/fixture-manifest.json`
  lists every fixture with its contract and readers;
  `tests/test_protocol_fixtures.py` fails on an unlisted, missing or unread
  fixture, so add a fixture and its manifest entry together.
- `e2e-files-live` covers remote-file download and link generation with harmless
  PDF, Markdown and 40 MiB binary fixtures kept under the 30-day upload retention.
  It creates two real turns per selected provider (fresh, then an exact resume over
  a new connection) and retains those conversations for opening the files on the
  phone. Codex gets an explicit thread name and Claude a unique marker in its first
  prompt, because the probe never calls `thread/name/set` for Claude; the receipt's
  label, `threadNameSet` and exact ids tell the outcomes apart. Success proves HTTP
  and provider output, not Quick Look rendering, VoiceOver navigation or Save to
  Files and Share, which stay physical-device acceptance
  ([Remote files](../docs/remote-files.md)).
- `e2e-questions-live --cwd <harmless-host-directory> --receipt <json>` is opt-in
  and creates its own two-turn conversation to exercise the question tool, a
  partial-index answer, host-only idempotent dismissal, a bounded native history
  page and a fresh connection. It never edits the working directory; the receipt
  holds exact thread and item ids and the final snapshot, never credentials.
  `question_model_fixture.py` is a deterministic loopback Responses provider for an
  isolated Codex app-server and gateway on the GUI test host: it accepts `RCQ_ASK_*`
  markers, has no account credentials and is not production inference. The
  `QuestionLifecycleUITests` opt-in scenario needs `RCQ_ASK_UI_ANSWER` and
  `RCQ_ASK_UI_DISMISS` seed conversations plus the isolated local app
  configuration. Keep all lab state under a temporary `HOME`/`CODEX_HOME`, disable
  pushes and Claude, and stop only the recorded lab processes afterwards.
- `e2e-queue-live` creates one hidden Codex probe conversation and runs four short
  turns in it: a busy shell sleep with two queued messages behind it, then a
  second busy turn stopped with a third message queued. It watches 25 s for an
  unwanted start before Send Now. On failure it removes only its own queued
  messages and stops only its own unfinished turns. Run it only against a
  gateway that serves `thread/queue/*`.
- Receipts and journals never contain credentials. A live probe that passes proves
  the exercised path, not the surfaces it does not touch.

## agent-call

`agent-call` wraps the root `agent-calls/` uv project with the same gateway
discovery as `rc-gateway`. Its explicit thread argument is an authenticated
operator surface; agents normally use the injected calling tools, whose provider
runtime supplies the exact originating identity. `--worker` is private,
stdin-driven primary host carrier execution owned by a gateway SSH lease. See
[the runbook](../agent-calls/README.md). Never print its stdin, the private media
URL or full carrier numbers.

## live-navigation

Agent-facing live-location control (`src/remotecoder_tools/navigation.py`). A
destination is optional. `fix` takes one precise fix through a single-fix session
and exits non-zero when none arrives within `--wait`. `--json` before the
subcommand gives compact request/response output, and `watch` always emits one
compact JSON event per line.
`docs/live-navigation.md` holds the contract.

## perf-sim

`perf-sim` runs repeatable performance windows against a `RC_PERF_HARNESS` build
(`build`, then `install`) in its own simulator on the Mac that runs it or, with
`--device`, on an explicitly selected physical test device paired with that Mac.
The argument must exactly match a UDID in the private maintainer configuration's
`testDeviceUDIDs` list; names, aliases and unlisted devices are rejected before
device work. A missing or invalid list fails closed. Fresh runs uninstall the
app, so this list must never include the daily phone. A device build is the Release
configuration signed with the release lane's ad hoc profiles, so it measures
what ships; Debug adds `#if DEBUG` work, testability and unoptimized C.
`build --signing development` keeps Release optimization but uses development
profiles to permit profiling attachment; its reports compare only with each
other. A simulator build is Debug at `-O`, good for checking a journey, not for numbers. Harness builds never enroll shared-gateway notifications. `stream` replays a recorded turn into an open
thread and `open-bench` opens a thread in a window that ends `--tail` seconds after
its transcript loads. Both fresh-install per run and print one JSON window per run;
a window is rejected unless the app stayed active at full energy and drew frames.

A saved trace template does not prove the recorded mode. Missing journey or scroll signposts leave hitch coverage unknown even when app CPU counters and timestamped CPU samples remain usable. Supply the matching dSYM explicitly when resolving sampled app frames.

The implementation is `src/remotecoder_tools/perf_harness.py`. `build` takes the
worktree's source lease and a background compiler slot from
`scripts/build_support.py`, so it queues behind `just install-dev`; every command
that touches the simulator or iPad holds that target's per-device lease, the one
`scripts/install-built-app.py` takes. The Mac writes one command to the app's
`Library/Caches/perf/command.json` and posts `com.remotecoder.perf.command`;
`PerfHarness` appends results, matched by `id`, to `results.jsonl`. `load` rewrites
a recording onto the open thread off the main actor and stages it for one `replay`,
keeping the rewrite outside the window and any trace. `--trace-template` records
Instruments around each window; a trace that stopped early (for example "Device
disconnected") or does not span the window's `startedAt` and `endedAt` fails the
run. Summarize one with
`just perf-trace --symbols <perf-sim RemoteCoder.app> summarize <trace>`; for
scrolling, compare its `motion` block, which covers only the transcript's
`TranscriptScroll` signposts. The harness drives the app in-process, so its
traces carry no XCTest automation, which `perf-trace` rejects.

`cmd '{"cmd":"sidebar","open":true}'` drives the existing SwiftUI drawer
control and waits for its published presentation state. Use the corresponding
`false` command before measuring a warm-idle opening; it does not report HTML paint.

To attribute a code change, alternate installs of both Release builds in one
session (`xcrun devicectl device install app` between runs, same journey, at
least three runs each) and compare the `motion` block's main-thread CPU per
second. Sessions drift by up to 20 %, and a `--disable` switch also removes
everything its feature gates: on 2026-10-20 `--disable readingFrames` cut
scroll CPU 15 % because it also removed the reading target and runway
trimming, while actually replacing those observers measured no change. Each
run has only a handful of hitches, so rank by CPU, not hitch rate. A
scroll-loop result's `counts` show work beside timing; `layout.measure` is a
full `TranscriptLayout` re-measure.

### Offline everyday replay

`perf-sim capture`, `scenario` and `compare` run the prepared offline journey that
[`docs/performance-replay.md`](../docs/performance-replay.md) defines; that
document owns the design decisions, measurement contract and Apple sources.
The app side (`PerformanceReplayRun`, Core `PerformanceReplay*`) compiles only
under `RC_PERF_HARNESS` and the Core package tests. It feeds captured history to
the unchanged `GatewayClient` through an on-device loopback fixture; never give
it its own transcript, rendering or transport path, and drive journey actions
through the entry points the UI uses. `-rcPerfOffline` launches use the
benchmark storage scope, in-memory host credentials and the isolated gateway
policy. A request the fixture did not capture must fail the run, never reach a
real gateway, provider or website; extend the fixture or the blocking instead
of relaxing that check. Site icons deliberately produce missing results and
HTML visual documents deliberately fail before download; both are counted as
omissions. A visual that still reaches WebKit invalidates the run.

The fixture server mirrors the gateway's delivery scope
(`host-daemon-rs/src/gateway/subscriptions.rs`): it applies every event to history and
activity, sends thread content only to connections subscribed through `thread/subscribe`
or, for Claude, `conversation/subscriptions/set`, and broadcasts only the gateway's
global methods. Change both together. A run is invalid unless each opened Codex
conversation reaches live observation. `perf-sim calibrate` is the only live-calibration
driver: it forks the given threads, marks them `probe`, runs one cheap Luna turn per
fork, writes the private `replay.json` from the complete per-agent streams, and always
interrupts, archives and uninstalls; its `report.json` decides validity.

Capture classifies the bounded header inventory before selecting explicit stream
targets, ordinary authoritative known-root histories, then remaining root histories. Other child and unresolved headers
do not consume the history budget. History reads use bounded native pages with
authoritative idle checks, repeated full-page validation with item-to-turn coverage, and header-only parent discovery. Version 2 histories are indexed private files;
unmeasured preparation rebases separate files and the loopback server assembles bounded raw pages. Hidden deltas remain shared references until a read needs their partial content.
Unmeasured preparation loads and verifies the sidebar through production list
pagination, reconciles captured user submissions only for authoritative known
roots with no explicit probe/automation purpose, and writes history and checkpoints
through their production owners. All eligible ordinary roots seed; at most three
explicit recorded journey targets may seed as controlled purpose exceptions.
Known-root seeding is an ownership proxy; actual phone ownership remains unknown.
Child and unresolved histories stay remote without local-submission markers. Preserve production budgets. Reports distinguish preparation's
physical sizes from logical checkpoint bytes written per measured state minute.
The measured journey keeps the drawer closed between paired short visits;
comparison requires agent-working context for at least 80% of the full report
duration after mixed/gap exclusions. It repeats recorded arrival offsets with continuous turns;
inferred initial starts are explicit in provenance. Each repeat reserves source, compiler capacity and device in installer order,
including preparation, with a fresh bounded deadline. It uses
`ProcessResourceSampler` with a private buffer for field-equivalent CPU attribution. Inspect traces before changing a failed regression workload.

Fixtures hold real user conversations. Capture is read-only and writes them
under `~/perf-traces/remotecoder/`, outside Git checkouts, mode 0600; never commit them, copy them into a
worktree, build cache or issue, or quote their content. Keep reports and traces
outside the worktree too. Results compare only across reports with the same
fixture SHA-256, device, OS and display, toolchain, configuration, signing mode,
driver hash, compiled harness fingerprint, state aggregation version and
instrumentation; `compare` enforces this, so a recapture or a signing change
starts a new baseline. Keep low-overhead runs as the baseline. Fixture CPU is a
synchronous lower bound; subtracting it leaves unattributed harness work. The
separate fresh-process footprint control measures incremental process footprint,
not exclusive journey allocations. Take Instruments recordings in separate runs
of the same fixture, and compare
the `journey` block of `perf-trace summarize`, not whole-trace totals.

For a live HTML fixture, `launch --lab-config /private/host.json` stages one canonical
`GatewayHostConfiguration` and launches with benchmark defaults/files and in-memory
credentials. It never imports production or iCloud hosts. The file must be private,
and the caller owns the isolated gateway, token and content. This mode uses the
normal app networking and rendering paths; it does not relax the offline replay
fixture’s external-network and HTML omissions.

## mac-bench

`mac-bench` measures Mac transcript scrolling and streaming with `RC_PERF_HARNESS`
in a Release-configuration build.
`build` builds only on the GUI test host and returns the signed app; `install` replaces
`/Applications/RemoteCoder.app`. App runs and tests use the GUI test host; the services
primary host is off-limits for GUI work. Hold the GUI test host app lease, require HID idle of
at least 120 seconds immediately before each launch. `run` queues behind a
bounded drain reservation, then owns both compiler slots through capture copy
and app cleanup; do not acquire those slots separately. Benchmark launches use
their own AppStorageScope for defaults and files, an isolated
GUI test host HostStore and transient credentials; never capture or restore production
preferences around a bench run. Use only throwaway conversations and harness
fixtures. Never change the GUI test host display mode.

`build --lab-config /absolute/book/lab/config.json` opts into a private loopback
gateway configuration already on the GUI test host. The file and its parent directory
must be owned by the invoking user and inaccessible to other users; it must name
127.0.0.1, an explicit port and a gateway token, with no primary host host or provider
credentials. The isolated-gateway probe owner must already be running and have
written its private metadata; port, token fingerprint and retained process
identity must match. The lab must be outside all Git worktrees, source snapshots
and RemoteCoder build caches. The caller checks placement and validates on the
GUI test host before source snapshotting; install-mac revalidates there before building.
It fails closed on invalid input. The signed app
remains in that lab directory and is not copied back to the calling host; pass
its returned path explicitly to `install --app` on the GUI test host. The lab owner
removes it with the rest of the lab after testing. Default bench builds keep
using the canonical development configuration; release configuration is unchanged.

`display` reports the current mode without changing it.
`run` refuses a preexisting running app and leaves it untouched on idle denial.
Use the explicit `quit` command under the GUI lease before a new measurement;
it requires an idle GUI test host. TERM, HUP and INT unwind the run's resource owner,
publish its terminal status and restore the caller's signal handlers.
The default gateway is GUI test host; other gateway identities, including primary host, are
rejected. Runs also require the isolated GUI test host HostStore factory before workspace
bootstrap. A missing bundled GUI test host seed must fail closed; never fall back to a
persisted primary host host.
`run --thread ID --label NAME` saves the plan, report, capture and `summary.json`
under `~/Library/Caches/RemoteCoder-Build/runs/mac-bench-<run-id>/`, outside the
mutable build mirror. Its receipt and summary record that path. Runs hold the
shared run lease and use the build-cache retention policy: 512 total runs,
three-day retention and 48-hour protection; active and unknown runs remain
protected. The app stages captures in its isolated temporary scope; the CLI copies
them into the run before quitting, which discards that scope. Repeated labels
create separate runs; give `profile` the output path
when a label is ambiguous. Use `--pattern standard` for short scrolls,
`--pattern deep` for longer traversal, or `--pattern idle --stream 10` for ten
seconds of streaming without scrolling. `--stream-kind mixed|paragraph|code|table`
selects the current mixed passage (default), one growing paragraph, one open code
fence, or one growing table. All use 60 characters per 30 ms; a ten-second code
run exceeds 1,000 lines. The plan and summary retain the kind. `--stream-scroll`
requires `--stream`, selects standard gestures instead of `--pattern`, and starts
scrolling and streaming together; the run waits for both. `--delivery app`
(default) routes events through NSApplication; `--disable responsiveScrolling` compares AppKit's
responsive scrolling path. Each run requires `--expected-display WIDTHxHEIGHT@HZ/SCALE`
(default `2560x1440@120/1`), checks it before launch and after measurement,
and records the app's screen dimensions/scale/refresh. Read the GUI test host's current
mode and supply it explicitly. Compare only runs from the same host and mode.
Batch analysis and repeated-run spreads reject different
or unknown display modes and mismatched measured cadence. `analyze RUN_DIR...`
recomputes saved summaries.

`--fixture cold-table` prepares one wide settled table followed by 40 short
user/reply pairs through the existing local synthetic-event path, before the
measurement window. It requires scrolling without a concurrent stream or
interaction check, and fails unless the table remains in the logical transcript
with its host evicted before recording. It never sends fixture content to a
gateway. This isolates cold table admission from a real conversation's contents.

`--check-interaction tracking` with `--pattern idle --stream SECONDS` checks
motionless trackpad tracking across content growth and cancellation.
`--check-interaction reading-growth --stream-kind paragraph --stream 10` leaves
following midway through the stream, acknowledges a centered row command, and
requires the same drawn streaming row and reading offset through completion.
`--check-interaction narrow-zoom --size 1000x945 --stream-kind paragraph --stream 8`
settles a tall paragraph, invokes the app's Zoom In and Actual Size menu actions,
and requires a constant column width with a changing row height and preserved
relative reading point through both transitions. Each run also checks the paired append/reflow origin
and rounded/stale-width contracts before opening its conversation.
`--check-interaction table-selection --stream-kind wide-table|wide-table-then-prose --stream 8`
sets a bounded native horizontal offset in the exact synthetic message's
wide table. It requires the same scroller and offset after completion or a
following paragraph restores selection; it does not prove wheel routing.
`--check-interaction cancelled-momentum` with `--pattern idle` checks End during
momentum, subsequent events outside the transcript, and an unrelated fresh
gesture. Both use `--delivery app`, emit a `bench: check` record, and fail on
incorrect follow or cancellation. `--stream-kind conversation` inserts a user
steer and reasoning row between two growing assistant messages in one turn.
The cancellation check includes direction changes on both scroll axes, End and
Page Up, zero initial and terminal hit targets, and fresh gestures in a second
window with prior ownership or draining. It also halts accepted vertical
continuations after an outside start or suspend/resume, and checks that
horizontal continuations retain direction through diagonal finger and momentum
samples. Halt must pass unrelated outside momentum and horizontal momentum.
Page Up must retain the same visible row within one device pixel; bottom-gap
changes are diagnostic.
It rejects `--stream`. Its horizontal classification and hit targets do not
prove displacement in an overflowing code/table control.

`--sample SECONDS` captures main-thread stacks for a finite duration greater than
zero and at most 60 seconds. Every exit path terminates and reaps the task-owned
sampler and quits the benchmark app. `--sample-interval MS` defaults
to 5 ms (1 ms remains available but perturbs frame pacing more). The sample's
reported interval and attribution are saved in `summary.json`. `profile NAME
[--focus REGEX] [--depth N]` reads a saved sample and prints its category tree,
RemoteCoder inclusive frames and matching callers/callees; NAME also accepts a
run directory. Focus is a case-sensitive regex, counted once per stack at its
first root-to-leaf match; depth defaults to 5, with the ten largest branches per
level shown. Profiling does not launch the app or change the saved run.

`mac_sample.py` owns the ordered `CATEGORY_RULES` table: the first matching rule
wins, walking its frames root-to-leaf for phase context or leaf-to-root for work
and app types. Child rules see only that context's subtree. Busy shares exclude
idle run-loop waits; blocking work remains busy. Category leaves partition busy
samples, including `other`; parent shares include children. Main shares include
idle samples in their denominator. Inclusive frame shares overlap. Stack samples
estimate time distribution, not CPU time or the unsampled frame cadence.

## streaming-motion-report

Measures a 60 fps screen recording through a crop that excludes the composer,
status bar and other independently animated UI. A shift pairs with an opposite
return up to 30 frames later, so a 2 pt twitch that snaps back after 150 ms
counts. Review opposite-direction candidates against the recording and exclude
intentional scrolling and keyboard transitions. The regression target is zero
unexplained jump and snap-back pairs; luma-change counts are descriptive, not a
publish-count gate, since deliberate fades and smooth growth change several frames
per published snapshot. Uniform opacity changes are normalized out. App debug logs
use the `streaming-motion` category for publication cadence without recording
message content.

## scroll-cadence-report

Measures vertical scroll motion per recorded frame in a crop of a
variable-frame-rate recording, by FFT cross-correlation of consecutive frames.
The recorder writes a frame only when the screen changes, so an interval of n
vsyncs while moving means n-1 frames went unpresented or uncaptured. Keep the
crop inside the transcript, away from the composer and the sidebar. A shift
larger than `--max-shift` or half the crop height, such as a page jump, is not
detected. `dev-tools/tests/test_scroll_cadence_report.py` covers the shift
detector and the interval accounting.

## realtime-voice-probe

Compiles the production `RemoteCoder/Services/RealtimeVoice/RealtimeWebRTCSession.swift`
(with the Core voice history and wire sources it needs) into a temporary macOS
executable and runs the real signaling path against the local gateway: initialize,
an ephemeral provisional thread, the production WebRTC offer and `oai-events` data
channel, `voice/session/start`, `thread/realtime/sdp`, connected ICE, then stop and
cleanup. `--help` and `README.md` list the modes (`--media`, `--handoff`,
`--claude`, `--resume-context`); `just voice-probe-both` runs the Codex and Claude
release gates in sequence.

- Media probes need macOS Microphone permission for the invoking process and
  reject unauthorized capture before starting a gateway voice session, because
  connected ICE and outbound packets alone can carry silence. They hold one lease
  on the audio route, and a failed input or output restore fails the run.
- A delegated command counts only when it completed with exit code 0, and the
  delegated turn only when it ended `completed`; a failed, interrupted or
  status-less turn fails the probe. `realtime_probe_assertions.swift` holds these
  predicates, and `tests/test_voice_probe_assertions.py` compiles and runs
  `tests/voice_probe_assertions_tests.swift` against them.
- Cleanup (voice stop, thread archive or Claude release, WebRTC close) runs each
  step independently, and a failed step fails an otherwise passing probe. Only a
  `thread/archive` "no rollout found" reply is the benign not-persisted case,
  logged as `thread.provisional.notPersisted`.
- `--silent` requires verified BlackHole input/output under the route lease and
  cached fixtures only. Both providers use the host-default runtime. `--build-only` compiles without any
  audio routing, fixture preparation or live session. New probe threads are
  marked `probe` before voice setup.
- RPC receive timeouts keep the pending socket read so cleanup cannot lose its
  response, and notification traffic cannot extend the media deadline.
- Every phase is JSONL under `~/Library/Logs/remote-coder/voice-probes/`. SDP is
  recorded only as byte count and a short SHA-256 prefix. The media fixture is
  generated only when absent from `~/Library/Caches/RemoteCoder/realtime-voice-probe/`.
