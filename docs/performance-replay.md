# Offline everyday performance replay

## Outcome and ownership

The canonical offline journey prepares realistic persisted state, then measures
five minutes dominated by visible agent work. Capture freezes idle conversation
histories, the sidebar inventory and recorded notification arrival offsets.
Three conversations stream concurrently; occasional switches, drawer use and
short scrolls use the normal UI entry points. Repeated recordings retain their
arrival gaps and tool activity with fresh item identities and continuous turns.
This repeats a captured workload; it does not simulate a provider's decisions.

The unchanged production `GatewayClient`, history service, sessions, stores,
rendering and UI consume an on-device loopback WebSocket fixture. The fixture
reads requested history pages from indexed files instead of retaining the whole
library. All replay code is guarded by `RC_PERF_HARNESS`; shipping behavior and
production storage budgets remain unchanged. No inference or installed gateway
is used by `scenario`, and uncaptured HTTP/RPC or external visual loads fail it.

The existing `perf-sim` runner owns source/artifact and device leases. A scenario
reserves both compiler slots separately for each complete repeat, including
preparation. Source, compiler and device locks follow the installer's order;
retaining prepared device state while later waiting for compiler slots can
deadlock an installer. Each repeat has a fresh 1,800-second execution budget,
with preparation reserving its measurement and cleanup time. Use the
explicit cabled test iPad; the runner refuses phones. Check fleet load before
building and keep unrelated device work out of the measurement window.

## Preparation and state scale

A fresh isolated install is only the starting boundary. Before measurement, the
app loads every captured sidebar header through bounded production pagination,
verifies retained root identities and reports omitted child headers, then prepares
histories oldest first. Capture classifies the bounded header inventory before selecting histories:
explicit stream targets come first, then ordinary authoritative `knownRoots`,
then remaining root histories. Other child
and unresolved conversations retain sidebar headers without consuming the history
budget. Local-submission preparation includes every eligible ordinary known root,
excluding explicit `probe` and `automation` purposes. At most three explicit
recorded journey targets may retain markers as controlled purpose exceptions.
Child, unresolved, probe and automation histories remain available remotely.
This is an ownership proxy: actual phone ownership is unknown even for roots.
For each marked history, page through the captured history, submit its captured text-only user message,
persist its submission receipt, accept its captured turn identity, reopen the
tail and reconcile the matching canonical history, flush and evict idle sessions
normally. If the user item is outside the tail page, page back only until its
authoritative delivery evidence reconciles.
The fixture rewrites that canonical user item's client identity consistently.
Preparation fails if the submission does not reconcile; it never leaves invented
pending sends behind. This retains the locally originated message semantics that
make checkpoints survive history shedding.

Large remote histories alone are insufficient: disposable checkpoints are
simply evicted at the normal cache limit. The 3.68.2 exhausted-history fix avoids
repeated inspection of preserved checkpoints after their history is gone.
Preparation reports conversation/page counts, preserved checkpoint counts,
physical checkpoint/cache bytes, the owner's protected-record and
record/cache/primary/eviction accounting and
persistence phase counters when that version provides them. Physical file sizes include SQLite/WAL residue;
they are distinct from logical write bytes and the owner's cache accounting.

Freeze eligible ordinary roots and the explicit journey exceptions before CPU
comparisons. When actual phone ownership is unknown, report the proxy's state
size and its difference from the independent field byte range. Do not substitute
purpose-tagged tasks solely to reach that range. Keep remaining captured
histories available for ordinary reads. Reports retain owner inventories before
and after the measured window so a transient preparation peak is visible.

Choose scale from uploaded field telemetry and app logs, looking only at counts,
sizes and timings. Sidebar count, page size, retained state and live arrival rate
are separate dimensions. Telemetry write counters do not establish retained disk
occupancy. Preserve unknown values and document inferred targets in the private
workload report. Do not shrink production budgets or inflate text to force an
expected speedup.

## Capture and repeat

Fixtures, uploaded logs, checkpoints and reports can contain private data. Keep
them outside Git and worktrees under `~/perf-traces/remotecoder/`, with files at
mode 0600. Never put them in build caches, issues, commits or reports containing
quoted conversation text. Contract tests use small synthetic records.

```sh
dev-tools/perf-sim capture \
  --thread <idle-visible-thread> --thread <idle-background-thread> \
  --thread <other-idle-thread> \
  --recording "$HOME/perf-traces/remotecoder/calibration/replay.json" \
  --sidebar-limit 1024 --history-count 700 --duration 300 \
  --out "$HOME/perf-traces/remotecoder/workload/scenario.json"
dev-tools/perf-sim --device <test-ipad-udid> build
dev-tools/perf-sim --device <test-ipad-udid> scenario \
  --fixture "$HOME/perf-traces/remotecoder/workload/scenario.json" \
  --label before --runs 1 \
  --log "$HOME/perf-traces/remotecoder/before.jsonl"
```

Capture is read-only and requires authoritative idle coverage before and after
reading a history. It uses native paginated item/turn reads, never an unbounded
`thread/read includeTurns=true`. Active, oversized and unavailable candidates
are skipped and counted; explicit selected histories fail instead of silently
changing. Related parents add headers only. Classification and question reads
respect their gateway batch limits.

Version 2 has a manifest and content-addressed indexed JSONL history files.
Limits are 1,024 conversations, 20,000 records per indexed file, 8 MiB per record,
24 MiB per history file, 16 MiB per manifest and 512 MiB per complete fixture.
The server reads at most 100 records per page and shortens large pages to fit its
WebSocket envelope. File hashes, sizes, offsets and paths are checked before use.
Real histories are copied directly into the isolated device container; they are
never bundled into the app. The server has no whole-history cache.

Timing input accepts a calibration `replay.json` or `record-start` JSONL.
Missing initial turn starts are inferred from first observed activity and marked
in provenance; their original start is unknown. Recorded completions are omitted
while repeating the continuous measured turn. Monotonic arrival gaps are
preserved. Known absolute timestamps are shifted on load so relative ages stay
stable. The event schedule is bounded to 20,000 events and the measured window
to 900 seconds. A short cheap calibration establishes arrival timing, not proof
that it represents every long coding turn.

Each repeat prepares its own state, settles, measures, verifies completed
assistant content and stops its models, sockets and diagnostics pump. It removes
benchmark storage and uninstalls the dedicated app on completion or failure.
Failed reports retain their identities and diagnostics beside the requested log.
Captured numeric telemetry exports are retained privately beside the report,
including the final pending export; no production sampler data is consumed.

## Measurement and acceptance

Reports preserve fixture identity including every referenced file digest,
source/build identity, device/OS/display/locale, toolchain, signing mode, driver
hash, instrumentation, preparation evidence, actual action/delivery lateness,
process/main-thread CPU, sampled footprint, frame intervals and counters.
`ReplayJourney` and `ReplayAction` signposts delimit corresponding operations.
The driver waits for xctrace's recording-start notification before measurement,
with synchronous notification registration, a bounded startup deadline and
owned registration cleanup.
A private buffer uses the unchanged production `ProcessResourceSampler`, including
its cadence, transition spacing and mixed-interval semantics. Samples use scene, surface,
visible-running-turn and voice-call breakdown. Counter deltas belong to the
starting context; mixed or long-gap intervals are excluded. Checkpoint volume is
logical bytes written per matching state minute, not filesystem amplification.

`compare` requires version 2 workload and preparation-contract evidence,
authoritative idle-capture evidence, verified preserved checkpoints, actual sidebar
counts and owner accounting above its eviction allowance, valid windows and
matching fixture, device, OS/display, locale, toolchain, signing, driver,
feature switches, energy states and instrumentation. Actual preparation sizes
and timing are results and may differ between builds. Legacy reports remain
diagnostic evidence. Agent-working CPU, main-thread CPU, checkpoint bytes/minute
and sampled footprint are reported as medians and ranges.

```sh
dev-tools/perf-sim compare --before /private/before.jsonl --after /private/after.jsonl
```

For a regression check, overlay identical harness-only changes onto the two
production versions, alternate at least three runs per version on the same iPad,
and keep the fixture fixed. The 3.68.1 to 3.68.2 acceptance target is at least a
halving of agent-working CPU with checkpoint bytes moving in the same direction.
If it fails, inspect corresponding trace stacks and preparation structure before
changing the workload. A changed fixture starts a new comparison.

Then check 3.70.1 to 3.71.0. Keep the production diagnostics pump enabled and
record process age, export count, scanned records and whole-process CPU during
exports. Preparation contributes genuine process uptime and logging; do not add
synthetic log spam. Export CPU includes concurrent work. A bounded run that
cannot reproduce the field uptime effect must report that result and its scale.

Low-overhead runs establish CPU spreads. Use separate matching Instruments runs
for call-tree attribution and actual presentation hitches. Display-link callback
gaps are cadence evidence, not Apple's hitch count or presented FPS. Missing
GPU, main-thread field measurements, retained bytes or export evidence remain
unknown. No measured battery-life or joule estimate is produced.

## Rich diagnostic recordings

Keep the low-overhead runs above as the comparison baseline. Add profiling in
separate runs of the exact same fixture; instrument overhead changes the result.
Physical CPU, GPU, SwiftUI and Swift concurrency recordings are system-wide.
On the tested Xcode 27.1 / iPadOS 27.0.1 pair, app attachment could not resolve
the verified running app by name or PID, with either distribution or development
signing. Allocations remains an app-attached, unverified lane. The recording
scope is report metadata. Large SwiftUI exports can exceed the summarizer's
120-second or memory limit; retain the raw trace for scoped analysis in Instruments.

```sh
dev-tools/perf-sim --device <test-device-udid> scenario \
  --fixture /absolute/scenario.json --label cpu --runs 1 --log /absolute/cpu.jsonl \
  --trace-template 'Time Profiler' --instrument Hitches --instrument 'Points of Interest' \
  --instrument SwiftUI --instrument 'Swift Executors' --instrument 'Swift Tasks' \
  --trace-seconds 315 --trace-dir /absolute/traces
```

For allocation sites and object lifetimes, first build with `build --signing
development`, then repeat with `--trace-template Allocations`. This keeps the
Release configuration and optimizer, uses the existing development profiles
and development APNs entitlement file, and permits Instruments attachment.
The distribution build has `get-task-allow=false` and rejects allocation
profiling. Signing mode is recorded and must match comparisons. Allocations
includes Points of Interest and VM Tracker. On the current iPadOS 27.0.1 /
Xcode 27.1 pair, development attachment produced no allocation tables and
stopped command responses; a separate launch probe reported overlapping dyld
images and timed out saving. Allocation capture is therefore unverified on
this pair. Do not interpret these failed traces as memory-owner evidence;
sampled process footprint remains available. Recorder output is saved alongside
each trace for diagnosis. For GPU
work, use a separate Time Profiler run with `--instrument GPU --instrument
'Points of Interest'`. Retain the raw `.trace`, matching `.app`/dSYM, JSONL and
fixture: summaries are entry points, not replacements for the underlying stacks.
Use `xcrun xctrace record --show-recording-options --template <template> --device
<test-device-udid>` to inspect the selected toolchain's capture defaults.

```sh
scripts/perf-trace --symbols /absolute/RemoteCoder.app --frames 30 \
  --callers 'AG::|Layout|malloc|write' summarize /absolute/traces/cpu-1.trace > /absolute/cpu-summary.json
xcrun xctrace export --input /absolute/traces/cpu-1.trace --toc > /absolute/cpu-tables.xml
```

The summary's `journey` block scopes CPU, thread weights, app/system inclusive
frames, leaf binary self time and nearest app callers to `ReplayJourney`.
`motion` separately scopes transcript movement to `TranscriptScroll`. The
whole-recording totals include setup/teardown and must not be compared as the
journey. In Instruments select the corresponding interval, then inspect:

- Time Profiler's call tree/callers and self time to map costly stacks to app functions.
- SwiftUI's update causes, body/layout work and cache-miss reasons.
- Swift Executors/Tasks for Main Actor versus cooperative-pool execution, task relationships and suspension.
- Allocations' live bytes, transient allocation counts and captured allocation backtraces; use retaining graphs when ownership is the question.
- GPU/render-server tracks and Hitches for rendering/presentation costs separate from CPU.

JSONL keeps every delivery/action deadline and completion, periodic and context-transition CPU,
footprint/thermal/power samples, applied input frames and actual notification
recipient counts, raw display-link intervals, and render/layout
counters. Render/layout counters cover the measured window. `rpcRequests`
subtracts preparation and excludes post-window content verification, which has
its own `verificationRPCRequests`; `httpRequests` includes preparation and
verification. Use the action/signpost intervals and CPU
stacks, rather than those broader request counts, to attribute window cost. Main-thread CPU is a thread measurement; it does not by itself prove
Main Actor isolation. Display-link callbacks measure callback cadence, not
presented FPS or Apple's hitch rate. Peak sampled footprint can miss shorter
spikes; allocation/VM traces provide the deeper view. CPU and thermal state are
energy evidence, not a measured battery-life or joule estimate.

Mac harness builds support the same app-side replay with `-rcPerfOffline
-rcPerfScenario /absolute/scenario.json -rcPerfOutput /absolute/report.json`.
This path is build-verified only; no Mac replay measurement has been accepted.
Keep the existing Mac benchmark app/window lease and idle-host rules; the
physical iPad remains the default measured target.

## Live calibration

`perf-sim calibrate` starts real cheap Luna turns in read-only probe-marked
forks, drives the same action executor and metrics recorder against the selected
real host, saves per-agent event logs, then interrupts remaining test turns,
archives the exact forks and uninstalls the dedicated app. It holds the source
and device leases. Its `--out` directory must be new and outside Git.

```sh
dev-tools/perf-sim --device <test-device-udid> calibrate \
  --fixture /private/everyday/scenario.json \
  --thread <codex-source-a> --thread <codex-source-b> --thread <codex-source-c> \
  --model gpt-6-luna --cwd /Users/developer/RemoteCoder \
  --app-host-name mac-mini --prompt-file /private/read-only-workload.txt \
  --out /private/everyday/live-1
```

Choose a bounded read-only prompt that produces tool activity and a substantial
formatted reply. The driver verifies model availability, observed model,
completion and cleanup. A valid report requires every real turn to start and
stream assistant deltas inside the measured window, with overlap between all
turns. The app alone reports only window validity; the driver supplies live
activity evidence before marking the calibration valid. No real agent is
started by the offline `scenario` command.

Reports identify `liveCalibration` versus `offlineReplay`; strict `compare`
accepts only offline replays. Live calibration is a representativeness check, not a
controlled before/after code comparison: real inference pace, hosts, sidebar
inventory, caches and network work can differ. Record incoming frames with
`record-start`/`record-stop` to compare item counts, delta sizes, bursts and
completion times as well as CPU, main-thread fraction, footprint and call-tree
shape. The driver saves each complete agent stream and a private `replay.json`
with the initial fork histories, supplied action schedule and recorded host
arrival offsets, ready for `scenario`. The fixture server applies all events to
history and activity, including hidden threads, and sends content only to
subscribed connections. Late opens hydrate the current replay state through
normal history RPCs. Transport latency and the real host's wider sidebar
inventory still differ. Live event offsets use the Mac and iPad wall clocks;
clock skew is unmeasured and represented as unknown in calibration metadata.
Similar total CPU alone does not establish that the
same code is hot.

## Apple guidance checked

- [CPU profiles and run comparison](https://developer.apple.com/documentation/xcode/analyzing-cpu-profiles-with-call-tree-views): compare corresponding operation intervals and inspect call trees/callers.
- [SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance): use update causes and layout evidence before changing views.
- [Memory analysis](https://developer.apple.com/documentation/xcode/gathering-information-about-memory-use): allocations identify sites; memory graphs identify retaining owners.
- [Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes): Swift Executors, layout cache reasons, allocation backtrace export and bounded time-range exports.
- [Xcode 27.1 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27_1-release-notes): installed Xcode 27.1, Swift 6.4.
- [Swift Testing](https://developer.apple.com/documentation/testing) and [performance tests](https://developer.apple.com/documentation/xctest/performance-tests): functional tests use Swift Testing; profiling remains an Instruments workload.
- [Network WebSocket options](https://developer.apple.com/documentation/network/nwprotocolwebsocket/options) and [NWListener](https://developer.apple.com/documentation/network/nwlistener): system WebSocket framing and loopback binding, not a handwritten protocol.

The replay metrics recorder currently coexists with the older open/stream and
Mac benchmark recorders. Consolidate those legacy lanes into the replay recorder
when changing them; keep their existing metric contracts while doing so.
