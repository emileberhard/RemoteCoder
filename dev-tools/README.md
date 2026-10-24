# dev tools

Small developer CLIs and scripts that help debug RemoteCoder infrastructure.
Each tool's `--help` is its command reference; [`AGENTS.md`](AGENTS.md) holds the
contracts and probe semantics.

| Tool | Purpose | Runs on |
|---|---|---|
| `rc-gateway` | Query, drive and probe the gateway over JSON-RPC | any host |
| `live-navigation` | Start and follow agent-facing live-location sessions | any host |
| `agent-call` | Operator surface for agent-initiated calls (`../agent-calls/`) | originating host; configured carrier worker |
| `perf-sim` | Repeatable performance windows on a simulator or iPad | configured test host |
| `mac-bench` | Mac transcript scroll pacing, phase spans and window capture | configured GUI host |
| `streaming-motion-report` | Measure streaming jitter from a screen recording | any host |
| `scroll-cadence-report` | Measure scroll frame cadence and judder from a screen recording | any host with ffmpeg and uv |
| `realtime-voice-probe` | End-to-end realtime voice check | GUI host, BlackHole and a microphone-authorized process |

The gateway Python wrappers resolve their own locked environment (`uv run --locked`), so
each works from any directory. Run the tests with `just tools-test`;
`just gateway-check` covers the same Python tests.

```bash
./dev-tools/rc-gateway config                        # resolved config, token redacted
./dev-tools/rc-gateway turn --prompt "hello" --show-deltas
./dev-tools/rc-gateway rpc --method thread/read --params '{"threadId":"...","includeTurns":true}'
./dev-tools/rc-gateway proxy                         # app-server JSON-RPC on stdio, through gateway admission
./dev-tools/realtime-voice-probe --media
```

`rc-gateway` defaults to this machine and reads its gateway environment and TLS
identity directly, without SSH or a hostname selection from the local JSON.
The default dial address is `127.0.0.1`, including when discovery is disabled.
It reads `~/.remote-coder/codex-gateway.env` on the selected host;
`AGENTS.md` lists the full discovery chain. Explicit `--ssh-host`,
`RC_CODEX_GATEWAY_SSH_HOST`, and programmatic SSH targets always use SSH.
Otherwise, `--host` or `RC_CODEX_GATEWAY_HOST` selects a matching
`macMiniHostname` or `macBookHostname` in the configured local JSON. A named
target reads locally only when exactly one
configured entry matches this machine's OS hostname or the local Tailscale
daemon's `Self.DNSName`. Comparison ignores case and one trailing dot. Tailscale
lookup has a two-second timeout and excludes peers. Unknown or ambiguous entries
keep SSH. Gateway and
desktop journals use the same rule, including `journal --follow`. SSH
configuration and DNS lookups do not decide locality.

Discovery reads `lanEndpoint` from that host's loopback `/health` and uses its TLS
port and SPKI pin for every WebSocket and HTTP request. The dial address stays
separate from the canonical TLS server name, including for `127.0.0.1`.
A mismatched pin fails before credentials are sent. WebSocket redirects are
rejected before another endpoint is contacted.
`--no-ssh-env --scheme wss` uses normal certificate verification;
`--spki-sha256` supplies a known base64 pin for an explicit WSS endpoint.
Plain `ws`/HTTP is limited to explicit loopback endpoints, such as local fixtures.

Timeout errors identify the stage, target, and deadline: SSH configuration read,
TLS identity discovery or its owning-host health request, WebSocket opening
handshake, ready notification, initialize response, frame wait, or RPC send/response.
An unattributed timeout names the command and discovery host instead of claiming
that a gateway response was awaited. Diagnostics omit bearer credentials.
Plain `rpc` includes the requested method in configuration, setup, send, and
response timeout diagnostics; a post-send timeout remains an uncertain exit 2.

`rpc` and `e2e-reads` share one `--timeout` budget across connection opening,
ready, cleanup, and retry backoff. Each opening wait is capped at five seconds
and the remaining budget; ready uses the remaining budget. One opening/ready
timeout can retry after 0.1 seconds only when at least another 0.1 seconds remains
for the second attempt. A ready stall that exhausts the budget is not retried.
The first failure and second-attempt recovery are JSON records on stderr with the
method, target, and elapsed time; the failure also names its stage and deadline.
Authentication, pin, and initialize failures are not retried. Application sending
and response waits stay outside the retry scope. Failed setup connections are
aborted without waiting for a closing handshake. Exit codes are preserved.

### Mac benchmark spans

`mac-bench run` and `analyze` write `summary.json` with `spans` sorted by
`totalMs`. Each row has `name`, `count`, `totalMs`, `p50Ms`, `p95Ms`, `maxMs`,
`mainThreadMs` and `mainThreadShare` (0–1). Durations are inclusive wall time
for retained, completed spans clipped to `report.json`'s
`measureStart`–`measureEnd` window. Nested spans overlap; their totals are not
exclusive CPU time. Percentiles use nearest rank.

`report.json`'s `marks[].spans` and `summary.json`'s `slowPasses[].spans` contain
up to five spans, ranked by time overlapping that frame's actual run-loop busy
intervals. Each has `name`, `durationMs` (within the measurement window),
`overlapMs` (within that frame's busy intervals) and `mainThread`. Slow-pass
spans match the exact frame timestamp; adjacent frames' spans are not merged.

`spanRecording` reports `capacity`, `retained`, `overwritten`,
`busyIntervalCapacity`, `busyIntervalsDropped` and `truncated`. The recorder
keeps the newest 65,536 completed spans; the busy-interval index keeps the
first 65,536 intervals. Truncated runs have partial attribution. Older reports
without spans produce `null`, not an empty measurement. JSON headlines stay
on stdout; the compact top-12 phase table and truncation notice go to stderr.

Instrument synchronous work with `let span = PerfBuild.span("phase"); defer
{ span.end() }`, ending each span once before any suspension. It is callable
from any isolation; the thread flag identifies the starting thread. Harness
builds also emit matching `OSSignposter` intervals under the app's bundle ID
and Points of Interest category. Other builds use empty inlinable span bodies.

`PerfBuild.count("name")` is also callable from any isolation. Its mutex owns
all counter mutations; `PerfBuild.counters` returns a snapshot. Frame marks
diff and retain the same single snapshot per tick, for every counter name.

`--pattern idle --idle-seconds 10` measures without gestures for ten seconds
per repeat. Plans with no gestures report `analysisScope: "window"`; their
run-loop statistics, slow passes and capture statistics use the full measured
window. Gesture runs use `analysisScope: "motion"`. `analyzedSeconds` names
the denominator; `movingSeconds` and `motionWindows` still describe observed
motion. `presented.fpsInAnalysisWindow` is the scoped capture rate used by the
headline, while `fpsWhileMoving` remains motion-only. Static-window capture
gaps do not establish scrolling hitches.

### Silent voice acceptance

`realtime-voice-probe --silent --handoff`
uses the host-default Codex runtime for signaling and delegation. Rejoining an
existing live session is a separate acceptance case; two successful independent
probe calls do not prove reconnect.
Both providers use the host default. Created threads are immediately marked `probe`.

Run on the GUI test host. `--silent` leases both audio routes and requires verified
BlackHole 2ch input/output before session setup or playback. Media modes require
an existing cached fixture; silent mode never generates one. Missing support or
route readback fails before a session starts. Both routes are restored and
verified, and cleanup failures make the probe fail. It starts no agent call or
phone call. `--build-only` compiles the full probe without changing routes,
preparing media, reading gateway credentials or starting a live session.

### Native compaction acceptance

`rc-gateway e2e-compact-live --cwd <harmless-host-directory> --receipt <json>`
creates probe-marked conversations for both providers, seeds harmless context and
requires the exact native compaction item to start and complete, followed by its
completed turn. A second real turn runs `sleep 30`; compacting that active turn
must be refused while its exact turn remains active. The probe deliberately stops
that busy turn and records its interrupted completion. It leaves hidden probe
conversations in history and writes only identities and verdicts to the receipt.
Use `--provider codex|claude` to select a provider; normal connection
flags precede the command.
Run after the new gateway is deployed; this proves provider lifecycle and safety,
not composer rendering.

`just gateway-e2e-device-tools-live` runs live Claude and Codex photo calls
through a fake installation on the already running gateway. The fixture has a
red rectangle on the left and a blue circle on the right. Success checks the
model description, one dispatch, journal redaction and the saved original digest.
The probe issues and revokes its temporary installation using the owning host's
credential CLI. Set `--ssh-host` to that host; connection flags go before the
`e2e-device-tools-live` command when invoking `rc-gateway` directly.

## Mac streaming bench

`mac-bench` uses an installed `RC_PERF_HARNESS` Mac build on the GUI test host. Hold the
configured GUI lease and follow the idle/container protocol in
`AGENTS.md`. Use a throwaway conversation on that host and supply the current
display mode when measuring a deterministic Markdown reply:

```sh
dev-tools/mac-bench quit --gui-host <gui-test-host>
dev-tools/mac-bench run --gui-host <gui-test-host> --host <gateway-uuid> --thread <thread-id> --expected-display <WIDTHxHEIGHT@HZ/SCALE> --pattern idle --stream 12 --label stream-follow
dev-tools/mac-bench run --gui-host <gui-test-host> --host <gateway-uuid> --thread <thread-id> --expected-display <WIDTHxHEIGHT@HZ/SCALE> --pattern standard --stream 12 --label stream-history
```

The terminal receipt and summary record the output directory under
`~/Library/Caches/RemoteCoder-Build/runs/mac-bench-<run-id>/`. Source snapshots do
not own these logs. The shared build-cache run policy bounds retention while
protecting active, recent and unknown runs. Repeated labels preserve separate
directories; use the recorded path for analysis or an ambiguous profile label.
Run admission leaves a running installed app untouched and refuses the run.
Quitting it is an explicit operation under the GUI lease; an idle-denied run
never stops or launches the app. The CLI drains existing compiler work before
holding both slots; new builds queue behind it. Do not also hold compiler slots
externally. Its `measurement-<run-id>/receipt.json` records queue and hold times.
Queue admission and command hold each have a 1800-second limit; reduce `--runs`
or `--timeout` if the requested batch exceeds the hold budget. TERM, HUP, INT,
client disconnect and timeout unwind the owned command and retain a failed
terminal receipt. Existing workers must finish before adopting the gate protocol.

`--stream` adds `stream: {kind, seconds, charsPerTick: 60, tickMs: 30}` to the plan.
`--stream-kind mixed|paragraph|code|table` defaults to `mixed`; `--stream-scroll`
selects standard scroll gestures while streaming. The report and summary retain
the stream parameters.
Omitting `--stream` preserves the ordinary scroll bench. `idle` emits no gestures and
measures for the stream duration plus the normal 0.6-second tail, or ten seconds
without a stream; it rejects `--warmup`. Other patterns run alongside the stream,
and measurement waits for both before the tail. Custom plans accept 0–120 seconds
(exclusive of zero), 1–4096 characters per tick and 10–1000 ms ticks, with at most
1 MiB of generated text. The mixed corpus contains paragraphs, a list and fenced
Swift.

`--stream-kind table-appearance` prepares a narrow user table and narrow,
wide and near-fit assistant tables in the isolated session. Use `--tail 120`
for a bounded settled acceptance window, `--appearance light|dark` for an
app-only appearance, and `--scrollbars Automatic|Always` for this launch's
argument-domain preference. The harness still quits at the end. Check actual
appearance and scrollbar style in the report; these runs prove no input behavior
until selection, copy, wheel and zoom actions are exercised.

`--fixture horizontal-overflow --check-interaction horizontal-displacement --pattern idle`
prepares one settled message with a long code line and a wide table. It requires
app event delivery, a window at least 500 points high, and no stream or warmup.
The check requires both controls to overflow, dispatches horizontal wheel events
inside each, and fails unless each offset advances at least 20 points while the
vertical transcript offset stays within one point. Each control's before/after
offsets appear in a `bench: check` record.

`BenchStream` sends decoded turn/item lifecycle events and assistant deltas
directly to `ConversationSession.ingest`. This exercises session projection and
80 ms publication pacing, `ChatScreenModel.publish`, Markdown rendering, row
growth and normal follow/reading behavior. It bypasses gateway transport,
notification decoding and model lifecycle side effects. No turn is sent to a
gateway. The selected session disables checkpoint writes before injection and
stays in memory until the bench process exits; a session handoff excludes the
synthetic turn. Existing history reads still use the gateway and its page cache.

Reports include stream configuration and expected tick/character counts.
`streamTicks`, `streamDeltas`, `sessionPublish`, `publish` and `renderPublish`
counters also appear in the per-frame marks. Tick deadlines are fixed relative
to measurement start; delayed ticks catch up without dropping content. These are
synthetic-input measurements, not evidence of real gateway or trackpad timing.

`mac-bench` takes `--gui-host` and `--host` (gateway UUID), or the optional
maintainer roles `macGUIHost` and `macBenchmarkGatewayId`. Voice probes accept
`--cwd`; otherwise they use the selected gateway's reported home directory.
