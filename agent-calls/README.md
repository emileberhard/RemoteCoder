# Agent-initiated calls

One originating gateway owns each call and its existing Codex or Claude agent.
`self` rings RemoteCoder through PushKit/LiveCommunicationKit. An E.164 number
uses the configured carrier host's 46elks carrier worker. Both use the existing subscription-backed
GPT Live V3 WebRTC path (`gpt-live-1-codex`), with normal two-way handoffs and
automatic agent progress/results. No extra backend agent or API-key fallback.

## Owners

- `host-daemon-rs/src/gateway/calls.rs`: durable IDs, brief, agent/host/device
  binding, admission, deadlines, native push, and a per-call SSH worker lease.
- Existing gateway voice code: subscription signaling, Codex native handoffs,
  Claude warm-runtime/shadow-thread handoffs, steering and transcript tail.
- `RemoteCoder/Platform/iOS/RealtimeVoice/` and `RemoteCoder/Services/RealtimeVoice/`:
  app-lifetime incoming-call handling (`IncomingCallCoordinator`) and native
  WebRTC media. Microphone permission is required before enrollment.
- `agent_calls/`: headless programmatic PCM ↔ WebRTC on the configured carrier host, carrier
  submission receipts, bounded playback and cleanup. It never opens the host's
  microphone or speakers and never starts another coding agent.
- AgenTTY backend: RemoteCoder-authorized `.voip` APNs transport only.
- Operator configuration: CLI exposure, credentials, service inventory and optional calling skill.

The originating gateway starts the carrier worker through noninteractive SSH,
passes a pinned WSS connection in private stdin, and keeps stdin open
as the worker lease. The handoff takes the SPKI pin and canonical TLS name from
the active gateway listener; it never stores a separate pin or discovers one
during call setup. The worker refuses plaintext and missing identity, connects
to that exact originating gateway and checks its persisted host UUID. SSH loss, gateway loss or explicit stop ends the
worker. There is no separate carrier daemon or replicated coordinator.

Gateway installation stages the embedded, hash-bound worker and frozen locks
on the configured carrier host before handoff. Each gateway's private call configuration selects
the immutable worker matching its `workerHash`. The binary and configuration
share one immutable generation, activated or restored by a single `current`
symlink swap. The carrier-worker registry protects pending and rollback references until
the originating installer acknowledges the selected generation. The carrier worker
retains current and previous artifacts and the originating host's selection, so an
originating host that has not yet taken a release keeps its gateway version usable. A live worker
holds a lease that prevents pruning its files. No live call resolves packages
or loads its worker from the checkout.

## Install

Use the normal gateway, broker and iPhone installers in their owning repos.
Install both gateway versions before the iPhone app. Calls require a ChatGPT
subscription login in the existing managed runtime; `OPENAI_API_KEY` is not used
by this worker. Configured alternative realtime endpoints/backend prompts fail
preflight rather than silently changing the route.

Configure an HTTPS/WSS media origin and ingress to the carrier worker's loopback
listener before carrier setup. Do not expose the gateway control listener as the
media endpoint. Operator-specific port claims, tunnel ownership and both-host
installation live in the private
[RemoteCoder-deploy operations entrypoint](https://github.com/emileberhard/RemoteCoder-deploy/blob/main/AGENTS.md).

Set `RC_CODEX_GATEWAY_USER_NAME` on each originating gateway before requesting
an outgoing telephone call to another person. The assistant uses that configured
name to identify whose behalf it acts on. Native self-calls and Voice Mode use
neutral wording when no name is configured.

Provision in your private operator environment:

- `PHONE_CALL_AGENT_46ELKS_USERNAME`
- `PHONE_CALL_AGENT_46ELKS_PASSWORD`
- `AGENT_CALL_MEDIA_SECRET`: at least 32 cryptographically random URL-safe
  characters, separate from gateway authority and rotatable independently.

Use number IDs from your own authorized carrier account. Carrier provisioning
and real calls require the account owner's authorization.

```bash
# Run provisioning on the configured carrier host with your own number IDs.
scripts/install-agent-calls --origin-host <carrier-host> \
  --worker-host <carrier-host> --worker-config /absolute/carrier.json \
  --voice-number-id VOICE_NUMBER_ID --websocket-number-id WEBSOCKET_NUMBER_ID \
  --public-base-url wss://calls.example.com --credential-source /absolute/operator.env

# Install another originating gateway against the same carrier worker.
scripts/install-agent-calls --origin-host <originating-host> \
  --worker-host <carrier-host> --worker-config /absolute/carrier.json

dev-tools/agent-call carrier-check --config /absolute/carrier.json
```

`carrier-configure` writes only `websocket_url` on the WebSocket number and
verifies it by readback. It never dials. The voice number is the outbound human
leg with `voice_start: {"connect": "<websocket number>"}`. Do not set
`voice_start` on the WebSocket-only number.

The installer updates private `call-delivery.json` through the installed
gateway's pair owner; its receipt names the immutable generation. The carrier worker also
gets `~/.remote-coder/agent-call-carrier.json`. The old fixed delivery file is
only a migration input and remains available for rollback to a legacy gateway.
It derives the advertised gateway address from the current Tailscale node's
full DNS name and the gateway's active TLS port;
bare SSH aliases are not network addresses on every host. Existing delivery
configuration supplies the dial host, while the active listener supplies the
port and identity at delivery time. The CLI resolves explicit host aliases
through SSH configuration. It warms the locked uv environment but starts no
service. The gateway loads delivery configuration at startup. After installing
the updated iPhone app, launch it and grant microphone access; it registers its
device, VoIP token included, with `devices/register` on each configured host.
Token rotation, invalidation and host edits refresh the registration.

## Use

Prefer injected `request_call`, `call_status`, `steer_call`, and `end_call` tools.
Their originating identity comes from the provider runtime, never model input.
The authenticated operator CLI accepts an explicit managed thread:

```bash
dev-tools/agent-call --host <carrier-host> check
dev-tools/agent-call --host <carrier-host> request --thread EXACT_THREAD \
  --to self --brief /absolute/path/brief.json --request-id STABLE_ATTEMPT_KEY
dev-tools/agent-call --host <carrier-host> status CALL_ID
dev-tools/agent-call --host <carrier-host> trace CALL_ID
dev-tools/agent-call --host <carrier-host> steer CALL_ID 'Ask one brief follow-up.'
dev-tools/agent-call --host <carrier-host> end CALL_ID
```

The brief JSON contains `purpose`, `language`, `context`, `scope`,
`stopConditions`, and nullable `opening`. It is immutable for the attempt;
short extra guidance uses `steer`. Keep the returned call ID and idempotency key.
A repeated identical key returns its existing call. Changed parameters under
the same key fail. No app-to-phone fallback or automatic redial exists.

Requested/delivering/ringing/connecting precede connected. Native end becomes
ended; telephone end stays ending until carrier terminal readback, or unresolved
if it cannot be confirmed. Ring/setup has a 60-second deadline and connected
calls have a 30-minute ceiling. A gateway restart preserves the record as
unresolved and never replays delivery. Media ending leaves the agent task alive.

46elks does not document an immediate pre-answer cancel operation. The worker
retains the carrier slot through the remaining ring deadline and up to eight
seconds of reconciliation; a late authenticated answer receives `bye`. A lost
POST acknowledgment is never replayed, and the slot stays reserved through that
same bound. Do not report cancellation as instantaneous.

Carrier media requires both the private URL credential and a `hello` matching
the submitted provider call ID and allocated WebSocket destination. Inputs are
continuous 24 kHz mono PCM, including silence; both queues are bounded to one
second. Playback follows an absolute sample clock, so timer overshoot cannot
accumulate into growing latency. A queue overrun drops stale audio, records the
discontinuity and continues at live time; malformed payloads remain diagnosed
protocol failures. Interruption clears playback and sends a fresh `sending`
before more audio. `sync`, `bye`, and carrier API completion are separate facts.

24 kHz is the highest documented uncompressed PCM option in the
[46elks format list](https://46elks.com/docs/realtime-voice-audio-formats).
Ogg/Opus is also supported, but the carrier does not expose the negotiated
telephone-leg codec in its hello message. Do not claim that switching formats
will improve fidelity without an authorized end-to-end comparison.

## Evidence and diagnostics

`trace CALL_ID` combines the call record, correlated gateway events, uploaded
iPhone diagnostics and the local carrier receipt into one JSON timeline with
source-file/line references. Repeated unchanged status reads are collapsed.
It reports missing, unreadable and truncated evidence explicitly. iPhone logs
upload through the existing app-log exporter to the currently selected host;
check that host's `app-logs` if the originating host has no app records. Carrier
receipts belong to the carrier host even for a originating host-originated call.

The iPhone persists call-specific breadcrumbs directly into the bounded app-log
queue as well as OSLog: push receipt and completion, validation, system call
reporting, answer/actions, connected-audio acknowledgment and teardown. Records
include the call/host IDs, wall-clock time, monotonic uptime, process ID, and
the failure domain/code plus a readable classification. For example,
`com.apple.CallKit.error.incomingcall:3` is `filteredByDoNotDisturb`, not a push
transport failure. Focus remains under the user's control; never bypass it.

- Originating gateway: private `agent-calls.json` beside its turn-state store.
  Status exposes a redacted recipient, reason, timestamps, delivery receipt and
  `voiceLogPath`. General RPC diagnostics redact call briefs and VoIP tokens.
- Voice transcript/delegations: the existing per-session voice JSONL log, with
  transcript-tail delivery through the normal originating agent.
- Carrier host: `~/.local/state/agent-calls/CALL_ID/receipt.json`, mode 0600. Includes
  submission/answer/terminal facts, drain/bye observations, frame/interruption
  counts, buffer high-water marks, overruns/dropped bytes, send lag, typed failure
  frames, subscription usage when available, and carrier duration/cost. Media
  statistics are checkpointed during a call as well as at teardown.
- Worker stdout contains only bounded event/status diagnostics; no media URL,
  bearer, full telephone number or carrier response body.

Call status does not certify task completion: `taskOutcome` stays unknown.
Report what the recipient actually confirmed using transcript evidence. APNs
acceptance, SDP, nonzero RTP and carrier success each prove different boundaries;
none alone proves the recipient heard the response or performed the task.

```bash
cd agent-calls
uv run ruff check agent_calls tests
uv run ty check
uv run pytest -q
```

`just gateway-check` and `just verify` run the pytest suite; ruff and ty stay
manual. Run gateway and iOS tests through the root recipes, and broker tests in
AgenTTY.
Real dialing requires explicit recipient/attempt authorization. Use synthetic
audio and fake carrier sockets for routine regression tests.
