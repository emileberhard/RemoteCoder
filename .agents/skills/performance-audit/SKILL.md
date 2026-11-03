---
name: performance-audit
description: Audit RemoteCoder performance per build from uploaded field telemetry, MetricKit and device traces, and keep a per-build record over time. Use for how a release performs, CPU, hang, memory, disk or battery regressions, or a perf audit.
---

# Performance audit

Field data says how each build performs on real devices; lab traces attribute
or confirm what the field shows. The contracts behind every number are in
`docs/host-observability.md` (*Field telemetry*, *iOS 27 performance reports*,
*Device traces*), `docs/performance-replay.md` and the root `AGENTS.md`
(*Engineering invariants*, *Measuring*). Read the section a step relies on.

Maintainers: the private operations entrypoint names the devices to audit, the
test devices for traces and the audit-record directory. Contributors audit their
own gateway and device and keep records outside this repository. Never commit
field data, device identifiers or traces here.

## Audit

1. **Pick the device.** `just app-telemetry stores` lists device directories
   (`iPhone-…`, `iPad-…`, Mac host names) and which stores were read. A store
   that could not be read weakens every absence and trend claim; say so.
2. **Read the record first.** Load the device's earlier per-build records so the
   audit reports a trend since the last one, not a snapshot.
3. **Read the per-build table.** Save
   `just app-telemetry releases --device <dir> > <file>` (14 days by default)
   and extract the columns you need from the file; the full output is large.
   Each build's groups carry the minutes they cover.
4. **Compare like for like.** Rank only builds with `lowData` false. Check
   `workload` before blaming code for CPU, and use `chat.lowWorkload`, which
   keeps intervals at a comparable number of running turns. For a pair of
   builds, `just app-telemetry compare --device <dir> --before <a> --after <b>`
   splits the change by app state.
5. **Attribute.** `timeline` and `activity` show state stretches, `persistence`
   disk writes per owner, `export-cost` the telemetry's own cost, and
   `metrickit`, `states` and `diagnostics` Apple's daily reports and sampled
   hang, CPU and memory diagnostics. `just gateway-journal` covers host-side
   causes such as reconnects and slow RPCs.
6. **Confirm in the lab** only when the field shows a change you cannot
   attribute, or to measure a fix: one journey on one test device in one energy
   state, before and after, with `just perf-trace` or `dev-tools/perf-sim`.
7. **Record, then report.** Pipe the saved table into
   `python3 .agents/skills/performance-audit/scripts/record_builds.py --into <records>/<device>`
   and commit the records where they live. Lead the report with a verdict per
   build that has enough data (better, worse, unchanged or unknown against the
   previous comparable build, naming the metric and its minutes), then the
   table. Keep field evidence, lab evidence and inference apart.

## Reading field data

- Stores keep about 7 days per host, so a build that aged out exists only in
  the records. Audit soon after a release has 30 active minutes.
- `null` means not measured: the build predates the field or no interval
  qualified. It is never zero.
- Development installs report version `0.0.0`; tell them apart by
  `build.sourceCommit`.
- Only measured, active intervals count. Work that began in one state lands in
  the next, so every per-state number is an association.
- Low Power Mode and serious thermal states switch rendering and prefetch
  paths (`AppEnergyPolicy`). Compare within one energy state
  (`compare --by lowPower --by thermal`).
- MetricKit reports arrive about a day late, cover mixed builds (the reader
  attributes them through run headers) and sample diagnostics; an empty stream
  proves nothing.
- `mainThread.blockedPercent` is busy time the main thread spent waiting, not
  computing: look for locks, I/O or scheduling, not hot code.

## Lab traces

- Compare traces only from the same device and energy state. Close XCTest-based
  drivers before recording; `perf-trace` rejects a trace whose automation
  share exceeds 1%.
- Keep the `.trace` and rerun `just perf-trace summarize <trace>` with other
  options instead of recording again.
- `--frames N` lists only the N heaviest frames; a function's absence bounds it
  below the last entry. Use a large N to find a small cost.
- `--callers` on `__CFRUNLOOP_IS_CALLING_OUT_TO_AN_OBSERVER` matches every
  run-loop observer, including Core Animation's commit and SwiftUI's update.
  Match your own symbols instead.
- Time Profiler samples each millisecond; a few samples are noise, so report
  them as an upper bound.
- `perf-sim` replays on an iPad only, and its magnitudes are not
  field-calibrated; read `docs/performance-replay.md` before relying on them.
