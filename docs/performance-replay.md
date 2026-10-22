# Offline everyday performance replay

## Outcome and design

Run a fixed, approximately one-minute journey with three captured conversations,
overlapping streamed turns, conversation switching, drawer presentation and short
scrolls. No provider inference or connection to an installed gateway occurs.
The workload and ordering are deterministic; OS scheduling, frame delivery and
timings remain measurements, not deterministic outputs.

The existing `perf-sim` runner owns device/build leases and Instruments. Its
in-app harness owns the journey. An on-device loopback WebSocket fixture serves
captured history and protocol notifications, scoped to each connection’s
subscriptions, to the unchanged production
`GatewayClient`. Normal decoding, subscriptions, history pagination, sessions,
rendering, layout and persistence remain in use. The fixture server adds a
small measurable cost in the app process; this is a repeatable app workload,
not a prediction of production CPU to the last percent.

This boundary avoids a second transcript implementation and a test-only
production transport. Direct notification injection would omit history and
socket decoding. A fixture server on another Mac would introduce network and
host availability as uncontrolled inputs. The loopback server is bound only
to 127.0.0.1, has bounded connections and messages, and ends with its run.

Replay launches use the existing benchmark storage scope and in-memory host
credentials. They never enroll with real services or read the user's host
directory. Real conversation fixtures remain private, outside Git; the
repository carries only the schema, capture tool and small contract fixtures.

## Measurement contract

Reports retain fixture SHA-256, source/build identity, device/OS/display and
energy state, action schedule and actual execution/delivery lateness, process
and main-thread CPU, memory samples, frame intervals and counters. Named
Points of Interest delimit the journey and actions. Reject missing actions,
incorrect final content, failed Codex observation or transcript loading, inactive/conserved-energy
windows or incomplete traces. After the measured window, verification opens each
replayed conversation and checks completed assistant items through the normal
Codex observation checkpoint or Claude history path. Claude opens require a
loaded transcript; they do not use the Codex observation coordinator.
Slow actions are recorded rather than silently skipped to keep a schedule.

Use separate identical journeys for low-overhead CPU/hitch measurement and
richer SwiftUI/Swift Executors, allocations/VM and GPU recordings. Instrument
overhead is part of the measurement configuration and must match comparisons.
CPU function weight includes callees unless explicitly reported as self time;
overlapping inclusive functions cannot form a pie chart. Memory allocation
sites and retained bytes are distinct. GPU absence is unknown, not zero.

Swift Testing validates fixture, protocol, ordering and cleanup contracts.
The measured journey runs without XCTest automation; Instruments supplies
profiling rather than an XCTest performance wrapper around the app.

## Capture and repeat

Run on the primary service host with the test iPad cabled, unlocked and awake. Check fleet load
before building; keep builds and other device automation out of trace windows.
The build is optimized Release with `RC_PERF_HARNESS`; ordinary shipping builds
exclude the replay implementation. No phone or provider inference is involved.

```sh
dev-tools/perf-sim capture \
  --thread <codex-thread-id> --thread <claude-thread-id> --thread <other-thread-id> \
  --out "$HOME/perf-traces/remotecoder/everyday/scenario.json"
dev-tools/perf-sim --device <test-device-udid> build
dev-tools/perf-sim --device <test-device-udid> scenario \
  --fixture "$HOME/perf-traces/remotecoder/everyday/scenario.json" \
  --label before --runs 3 --log "$HOME/perf-traces/remotecoder/everyday/before.jsonl"
```

Capture is read-only. It freezes up to 20 completed turns per conversation,
account/model responses, selected conversation metadata/marks, question and
agent inventories, related parent headers, project identities and host/account
HTTP responses. It does not preserve unrelated pins or enrollments. The fixture
limit is 16 MiB; each conversation has at most 1,000 history items. Capture two
to six histories, including referenced parent conversations; the standard
journey switches among the first three selected conversations.
Keep the same fixture for all comparisons, rather than recapturing live state.
Capture records its wall-clock time. Loading shifts known absolute timestamps
by whole seconds so relative ages, settlement and usage windows stay stable;
monotonic event offsets and durations remain unchanged.

The stream repeats a complete captured turn with fresh item/turn IDs, including
user messages, reasoning, tool starts/completions and assistant replies. Text
arrives in eight-character chunks in bursts at intervals of at most 30 ms,
with gaps between items when the turn leaves time for them. When its text
fills the window, pacing becomes uniform. Each turn spans 37 seconds and starts
four seconds after the previous stream. Activity inventories and fixed synthetic token
counters exercise their normal update paths. Token counters are workload data,
not measured provider usage. Pacing is synthetic; a saved real multi-agent
recording had a median 13-character delta and batched arrivals, so this lane
exercises publication coalescing without claiming to reproduce provider timing. Actions use monotonic deadlines;
late actions still execute and their lateness/overrun remain in the report.
Conversation switches use the UI navigation entry point. Sidebar actions run
the real window toggle command and record its published view state before/after.
Two toggles close/reopen a persistent sidebar and open/close a compact drawer. Scrolls
use the production animated row-navigation path, rather than simulated finger
physics. Voice, image/HTML assets, network latency, TLS and server CPU
are outside this text/code workload. Choose conversations without visible
external assets. Site icons deliberately return a missing result without
networking; reports count these omissions. HTML WebKit surfaces are blocked
and invalidate the run. Other uncaptured HTTP/RPC requests fail the run.

Each run fresh-installs, launches with benchmark-only storage and in-memory
credentials, prepares history, settles, then measures the journey. Successful
teardown retires models, joins fixture sockets and removes benchmark storage.
Uncaptured RPCs, missing/blocked HTTP, fixture errors, cleanup failures, missing
frames or incorrect final text invalidate the report. Failed reports, including invalid energy or incomplete-trace windows, are saved
with build/run identities beside the requested JSONL log for diagnosis. The
runner uninstalls the dedicated app after each run, removing its private fixture.

Rebuild the candidate and repeat with the identical fixture and device. Save
reports outside the worktree so each branch's build can be removed afterwards.

```sh
dev-tools/perf-sim compare --before /absolute/before.jsonl --after /absolute/after.jsonl
```

Comparison prints medians and ranges for CPU and sampled footprint. It rejects
different fixtures, devices, OS/display settings, locale, feature switches,
toolchains, build configurations, driver hashes, sampled thermal/power states or instrumentation. Missing comparison metadata is rejected;
legacy reports remain diagnostic evidence. Source
fingerprints and app executable hashes travel with each report. The runner
holds the source/artifact lease before its device lease so another build cannot
replace the app between repeats. Three runs provide a first
repeatability check, not a statistical confidence interval; alternate baseline
and candidate installs for decisions near the observed variation.

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
  --trace-seconds 75 --trace-dir /absolute/traces
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

JSONL keeps every delivery/action deadline and completion, one-second CPU,
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
