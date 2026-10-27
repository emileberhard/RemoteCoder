# Performance verification

- Measure before and after on the cabled test iPhone, not in the simulator; the
  test iPad is the second device for its layout and for parallel traces.
  Compare traces only from the same device.
  `just perf-trace record <label> --device <UDID>` records Instruments on
  the primary service host the test devices are cabled to and summarizes CPU time by thread, Core
  Animation commits, GPU time and hitches; its `motion` block limits them to the
  transcript's `TranscriptScroll` signposts and gives Apple's hitch rate.
  `--frames` ranks the main thread's top functions by self time and `--callers`
  attributes system work to app frames. Drive the journey with
  `dev-tools/perf-sim` or by hand: XCTest-based drivers (agent-device, XCUITest,
  Xcode device interaction) snapshot the app on its main thread. The
  `perf-sim` replay's magnitudes are not yet field-calibrated; read
  [`docs/performance-replay.md`](docs/performance-replay.md) before relying on them.
  The detector also includes accessibility user-testing snapshot and MIG frames
  outside `/Developer/Library`. `perf-trace` reports main-thread CPU with and
  without automation and their CPU share and rejects a trace when automation exceeds
  1% of app CPU or main-thread CPU, or when an observed automation share is unknown.
  `dev-tools/streaming-motion-report` measures streaming jitter from a screen
  recording.
- `perf-trace record --template` selects `Time Profiler` (default),
  `Processor Trace`, `Swift Concurrency`, `System Trace`, `File Activity`, or
  `Allocations`; repeat `--instrument` to add Apple instruments. Processor
  Trace defaults to 5 seconds and requires A18+/M4+ hardware plus the device's
  Developer → Processor Trace setting. Both cabled test devices are older and
  cannot record it. Single-process attachment requires a debuggable install
  signed with `get-task-allow`; distribution builds are excluded from attach
  discovery. Mac recording also needs Developer Tools profiling access.
  Other templates retain Time Profiler for the XCTest-driver rejection.
  File Activity reports logical bytes and operations by exported path (an
  unavailable path stays unknown), System Trace reports blocked thread time,
  Swift Concurrency reports task states and actor queues, and Processor Trace
  reports observed function-call intervals and self cycles. Processor Trace
  backtraces resolve by UUID through the same dSYMs; its elapsed self duration
  can include off-CPU waits, so use self cycles to rank CPU work. Unsupported export
  tables, including allocation events on current Xcode, stay unavailable. Each
  measurement that hits a guard reports `exceeds export limit` in `exportFailures`;
  other measurements remain available. Recording, its post-processing and exports
  share the quarter-memory bound for xctrace and Python combined, using the larger
  of resident memory and physical footprint per process. A recording has its
  requested duration plus 120 seconds to finish; each export has 120 seconds.
  Each xctrace process owns a private TMPDIR removed after it is reaped, including
  on failure. The XML parser detaches consumed rows, interns frames, and checks its
  own budget while reducing the table. Sampled-frame and journey analysis share
  the measurement boundary; unavailable frame details preserve app CPU totals.
  `--frames` includes UUID/address/source and inline-frame details alongside
  the existing frame aggregates. Device builds mirror their matching dSYMs to
  the configured tracing host under leased `RemoteCoder-Build/runs` retention;
  published release symbols remain in the deployment owner's symbol retention.
  A trace without app CPU samples fails with a diagnostic. On a device that
  records only the kernel, verify the app is foreground and unlocked, then
  repair its profiling services before collecting another measurement.
- Low Power Mode and serious or critical thermal states set
  `AppEnergyPolicy.conservesEnergy`, which switches rendering and prefetch
  paths. A hot phone therefore runs different code, not just slower code.
  Compare traces only within the same energy state. `AppEnergyMonitor` logs
  that state at launch and on every change (category `Energy`), so uploaded
  app logs show which state a period ran in.
- Known dead end: on iOS, `OSLogStore` ignores `position(date:)` and reverse
  enumeration (Apple DTS r.87416514, r.87622922), and predicates do not shorten
  its scan, so every read enumerates the whole process lifetime. App logs reach
  the host through `AppLogger` at the call instead; never read them back.
