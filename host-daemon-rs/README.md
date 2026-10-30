# RemoteCoder Codex Gateway (Rust)

Rust implementation of the RemoteCoder host gateway. Each host has one Codex
runtime, optionally shared with Desktop, and one Claude profile. Native CLI
logins provide basic chat; an explicitly configured llm-router can own provider
accounts instead. See [Provider accounts](../docs/provider-accounts.md) for quota ownership,
retired-profile adoption and verification.

Agent-initiated native/telephone calls use the same voice core; see the
[calling runbook](../agent-calls/README.md) for installation, ownership and
diagnostics. The gateway persists call IDs and never replays an uncertain dial.

It:
- ships the tracked cold-start/recovery owner for one official managed `codex app-server` on the canonical user-private Unix socket
- exposes an authenticated HTTP/WS gateway
- proxies each authenticated client over its own Codex connection, preserving client identity and subscriptions
- adds gateway-only methods: `daemon/activeTurns`, `daemon/replayNotifications`, and `conversation/settings/update`
- serves Claude threads through the same app-server v2 methods, including `thread/items/list`, `thread/turns/list` and the `thread/tokenUsage/updated` replay after `thread/resume`
- sends completion and Live Activity push requests through a configured push broker (best-effort)

## Config

Follow the [public runtime bootstrap](../docs/codex/runtime.md) to build and
approve the exact matched Codex package, including its code-mode-host sibling.
Copying a bare Codex executable is unsupported. Authenticate the CLI with your
own provider account before using chat.

Create a private configuration with a new random token:

```bash
python3 host-daemon-rs/scripts/setup.py \
  --codex "$HOME/.local/share/remotecoder/codex-package/bin/codex"
```

The script creates `~/.remote-coder/codex-gateway.env` mode 0600 and refuses to
replace an existing file. It binds to loopback and leaves optional services off.
The token grants host-user execution: copy it only into your own client's host
settings or private credential file. Do not publish it or put it in a URL.

After building, validate configuration without starting service or printing
credentials:

```bash
remote-coder-codex-gateway --env-file ~/.remote-coder/codex-gateway.env check-config
```

Start a foreground development gateway with the recipe below. Loopback is the
safe local default. For a remote client, configure your own private-network
interface or TLS endpoint and the corresponding client transport; see
[credentials and transport](../docs/owned-operations.md#credentials-and-transport).
Never expose an unprotected command-execution listener.

### Native provider logins

With no router configuration, Codex uses its native login in the managed home,
and Claude uses your own unmodified Claude Code CLI login. Claude defaults to
`~/.claude` and retains the host's existing settings/MCP configuration. You can
select an explicit CLI/home through `RC_CLAUDE_PATH`/`RC_CLAUDE_HOME`.
Router-only account management, title inference and speech relay are unavailable
unless a router is configured. Unknown usage stays unknown.

### Optional llm-router

To enable the operator integration, configure all four values together:

- `RC_CODEX_GATEWAY_ROUTER_URL`: inference origin.
- `RC_CODEX_GATEWAY_ROUTER_ACCOUNTS_URL`: account-management origin.
- `RC_CODEX_GATEWAY_ROUTER_KEY_FILE`: absolute path to a private host key file.
- `RC_CODEX_GATEWAY_ROUTER_CODEX_ACCOUNT`: exact router Codex account ID.

A partial configuration fails validation. Non-loopback origins must be explicitly
listed in `RC_CODEX_GATEWAY_ROUTER_ALLOWED_ORIGINS` (comma-separated, at most
32 origins / 8,192 bytes). This is an exact operator allowlist; no personal DNS
suffix is implicitly trusted. `scripts/install-router-key.zsh` takes inference
and accounts origins as arguments and the key on stdin. Never place it in argv.

The host key needs the router scopes used by enabled features (`inference`,
`accounts:read`, `accounts:prefer`, `accounts:redeem`, `codex:token`). The gateway
reads a private regular key file again for each command/request. Router mode
owns Codex external-token installation/renewal and Claude account failover;
there is no silent switch to native login during a router outage. See
[provider accounts](../docs/provider-accounts.md).

### Optional external model providers

`RC_CODEX_GATEWAY_EXTERNAL_PROVIDERS_FILE` names a private JSON file (at most
64 KiB) of OpenAI-compatible Responses endpoints that Codex conversations can
run on besides ChatGPT:

```json
{"providers": [{"id": "relay", "name": "Relay", "baseUrl": "http://127.0.0.1:8080/v1",
  "keyFile": "/absolute/path/relay.key", "models": ["vendor/model-a"]}]}
```

Each id is lowercase and neither `openai` nor `claude`; a model id belongs to one
provider. The gateway reads `GET {baseUrl}/models` with the key as a bearer and
offers each listed model whose entry names the `/v1/responses` endpoint, a
positive `capabilities.prompt_tokens` and true `streaming` and `tool_calls`. It derives the model metadata Codex needs
from that listing alone and keeps the last good catalog in its state directory.
A conversation stays on the provider it started on; choosing a model of another
provider needs a new conversation. Hosted web search is withheld from these
providers. ChatGPT Desktop has no definition for them and cannot resume such
conversations.

### Optional host services

- User identity: `RC_CODEX_GATEWAY_USER_NAME` personalizes voice prompts and
  named goodbyes. If set, it must be nonempty, at most 128 UTF-8 bytes and
  contain no control characters. Leave it unset for neutral wording. Outgoing telephone calls
  to other people require it so the assistant identifies whose behalf it acts on.
- Push: configure a broker authorized for your app's bundle IDs. Broker settings
  belong to the gateway process environment; `--env-file` does not load them into
  that process. Explicitly disable with
  `RC_CODEX_GATEWAY_PUSH_BROKER_ENABLED=false` when not used.
- Speech: a configured router relays the fixed provider operation allowlist.
  `RC_CODEX_GATEWAY_SPEECH_CLIENTS` can restrict usage to installation IDs; this
  controls spend, not execution authority.
- Automations, Desktop policy and Full Disk Access requirements come from the
  optional private `~/.remote-coder/host-profiles.json`. Tracked defaults contain
  no maintainer host identities. `check-config` reports the resolved capabilities.
- Logging: `RC_CODEX_GATEWAY_LOG` sets the gateway's filter without changing
  child configuration. Do not log credentials.
- LAN and relay routes are optional; their contracts follow below.

### LAN TLS listener

Set `RC_CODEX_GATEWAY_LAN_PORT` (for example `8789`) to serve every gateway route
over TLS on `[::]:<port>`, which also accepts IPv4, so the app can connect directly on the home
network instead of over the tailnet. It is off when unset or empty; a
non-numeric value, `0`, or the plaintext port fails startup. The plaintext
listener is unchanged.

- Identity: an ECDSA P-256 key in `~/.remote-coder/lan-tls-key.der` (PKCS#8
  DER, mode 0600). The first start generates it and publishes it create-only,
  so concurrent starters converge on one key. A present key that is a symlink,
  grants group or other access, or is not a P-256 PKCS#8 key is refused, never
  replaced. Deleting the file and restarting rotates the key.
- Certificate: self-signed and re-derived from that key at every start, with
  SANs `<LocalHostName>.local` (from `scutil --get LocalHostName`) and
  `localhost`. The listener speaks TLS 1.3 only with ALPN `http/1.1` and no
  client certificates; WebSocket upgrades work as on the plaintext listener.
- Pin: `spkiSha256` is the standard base64 SHA-256 of the certificate's DER
  SubjectPublicKeyInfo. It changes only with the key, not with the host name
  or certificate. Clients learn it over the tailnet from the authorized
  `/health`, whose `lanEndpoint` is `{"host","port","spkiSha256"}` while the
  listener serves and `null` otherwise.
- Failure: if the key, host name, or bind fails at startup, the gateway logs an
  error, keeps serving the plaintext listener, and reports `lanEndpoint: null`.
  Each TLS handshake is bounded to 10 seconds, and each request head to 30
  seconds, including the wait for a connection's first or next request, so a
  silent LAN client cannot hold a connection or the shutdown open. When the
  shutdown drain ends, both listeners stop accepting and open LAN connections
  close gracefully.
- The installer also claims `0.0.0.0:<port>` for `remote-coder-gateway` in the
  host port registry when the key is set.

### Speech providers

The `/speech` relay forwards each admitted operation to llm-router's vendor
passthrough, `/vendors/<vendor>/<path>` on `RC_CODEX_GATEWAY_ROUTER_URL`, with the
host's router key in the provider's own auth header. The router replaces that key
with its provider credential. The vendors are `openai`, `elevenlabs`, `google`
(SpeechKit's `gemini`), `assemblyai`, `assemblyai-streaming` and `azure-speech`,
whose resource endpoint the router owns. Provider keys and their rotation belong
to llm-router; an unreadable router key is refused as `credentialsUnavailable`.
The router rewrites Gemini's resumable-upload URL to its own origin; the relay
returns it under Google's origin, which SpeechKit requires before it relays the
upload back through `/speech/gemini`.
A missing router credential or a refused key reaches the client as the router's
HTTP response, or as `upstreamRejected` on a WebSocket connect.

### Automatic conversation titles and done suggestions

The gateway reviews completed turns for both Codex and Claude. Titles apply only
to user turns with a native name or preview and a readable latest user request. Done
suggestions also apply to agent-initiated turns. Pins, purpose rows and delegated
agents are excluded from both questions; threads must be idle and non-ephemeral. A
text snapshot reads the entire conversation in chronological native item pages.
It keeps user and assistant text in full and reduces tools to their type and a
short name; tool arguments, output, patches and attachments are excluded.
When the dialogue exceeds a 96 KiB JSON budget (roughly 24k prose tokens), it
omits whole middle messages and preserves the beginning and end. An individual
oversized first or last message has only its own middle trimmed. The state
explicitly marks omitted context. Intermediate batches compact at 512 KiB,
and history reads are capped at 400 pages; incomplete reads leave titles and suggestions
unchanged. Direct Jev has a 32k-token context window. A provider context-limit
error retries once with a conservative 24 KiB budget, using the same bookends;
other errors do not retry. `typesafe/jev-1.13` judges whether the current native
name (or preview) is misleading, generic, or unsuitable as a concise, clean
conversation-list title through OpenRouter's Decisions API, reached through
llm-router's `openrouter` vendor passthrough. Copied opening
messages, rambling requests, cut-off prose and raw Markdown are unsuitable.
The gateway measures the full title's length in code: more than 80 characters
also triggers a rename after a valid decision response. Any probability reaching
0.60 asks the conversation itself for a new title through a side question, on
its own model and effort, so the answer reuses the thread's warm prompt cache:

- Claude: the thread's warm runtime gets the CLI's `side_question` control
  request, the one `/btw` uses, also while a turn runs. It reuses the runtime's
  last request, keeps the session and its router account, denies tools and
  writes nothing to the transcript. An answer that misses the control deadline
  is cancelled with `control_cancel_request`. A thread without a warm runtime
  gets a one-shot `claude -p --resume <session> --fork-session
  --no-session-persistence --tools ""` in its working directory, on its model
  with Fast off, with 60 seconds and 1 MiB of output to answer. Its `system/init`
  passes the same billing guard as a runtime, and its process group is owned and
  killed like a runtime's. Nothing is written to the session or a new one. It
  re-reads the transcript without the warm runtime's prompt cache.
- Codex: an ephemeral `thread/fork` with the parent's model, a read-only sandbox
  and no approvals, then one `turn/start` at the parent's effort. The fork keeps
  the parent's prompt cache key. Its events go only to the waiting side
  question and never reach clients, history, pushes or the activity inventory.
  A tool item, a server request or 60 seconds without an answer interrupts it;
  the gateway then unsubscribes and Codex unloads the fork. The fork keeps the
  parent's tools, because removing them would change the cached prefix, so an
  MCP tool the parent auto-approves can run once before the interrupt.

The same request carries a `done` question when a completion timestamp is known.
It asks whether the latest request is fulfilled with no required step on either
side. Questions, decisions, approvals, reviews, physical steps, failures,
blockers, partial results, running work and promised continuation are not done.
Optional offers of additional work do not keep a fulfilled request open.
Insufficient evidence is false. The calibrated cutoff is 0.90; see
private operator calibration records.

The gateway records the done verdict before asking the slower title side question.
At the cutoff it writes `doneThrough`; below it clears that field, only when the
value changes. It uses the same timestamp as the drawer: Codex's native turn
`completedAt`, or Claude's transcript header `lastTurnCompletedAt` for that turn.
The marks transaction excludes pins and purposes and rejects a positive verdict
when explicit Unsettle covers the judged activity. Read marks and unrelated
account activity do not discard it. Done writes use no conversation admission
or second history read. Suggestions never change pins, read state or settlement.
The marks delta uses the existing `conversation/marks/changed` broadcast.

The writer receives the frozen latest user request from the native item history,
prioritizing the current task over an inherited opening topic. That request is
bounded to 8 KiB with an explicit middle-omission marker; it is retained before
the judge's whole-conversation view is trimmed. Missing text leaves the title
unchanged with `latestUserGoalUnavailable`.
If the judge requests a rename and the writer echoes the rejected title, the
same writer gets one repair question with the same frozen user request. A second
echo keeps the title with `writerEchoedRejectedTitleAfterRepair` in the journal.
There is no further retry or guessed replacement. Native snapshot revalidation
still fences a repaired rename. Fork title copying stays unchanged.

Early titles do not wait for the first turn to finish. Fifteen seconds after a
conversation's first `turn/started`, the gateway asks the same writer for a
title while the turn runs, so the answer sees the agent's early exploration. No
judge is involved. It applies only to an unnamed, non-ephemeral thread whose only
turn is that one, still in progress, with a user message; pins, purpose rows and
delegated agents are excluded. A turn that already finished belongs to the
completed-turn review, which also judges an early title like any other. Each
`turn/started` first checks the name and turn count, so only a plausible first
turn holds one of the 32 early-title slots per gateway account context through
the delay; a full set skips with `earlyTitleSkipped`. The rename goes through
the same owner as reviewed renames, so a manual rename in the meantime wins.

`conversation/title/regenerate` with `{"threadId": ...}` asks the writer for a
new title on demand, without a judge, and returns `{"name": ...}`. The question
names the current title to replace; an echo gets one repair question and a
second echo fails the request. Because the user asked, pins, purposes, delegated
agents and an existing manual name do not exclude the thread. It is new work
for either provider: a draining gateway refuses it, and it holds account and
conversation admission while the writer runs.

The question asks for at most 30 characters, which fits one Mac sidebar row
at the default column width. Neither path uses structured output, which would
change the cached prefix; code validates the plain-text answer (one line, at
most 80 characters).
`just gateway-e2e-titles-live` proves both paths end to end on the build host's
deployed gateway. The title threshold
is an initial operating choice, not a calibrated accuracy claim.

The Jev request uses the host's llm-router key, read on each check, so a key
rotation applies on the next completed turn. An unreadable key fails the check.
Both providers share their host's key and one request slot.

Checks are best effort: busy slots drop work until a later turn, and a failed
consumer leaves its own state unchanged. Pinned names, probes, automations, ephemeral threads
and delegated agents are excluded. New activity in that thread or a native
rename invalidates pending title work, and the native title, latest completed turn, text and marks are
checked again before renaming through the existing provider naming path.
Shutdown cancels owned tasks. Every new completion gets a correlated `review`
journal trace, including skipped, kept, renamed, failed and abandoned checks.
Each consumer parses and applies its answer independently. A malformed answer
or done-write failure is traced without aborting the other consumer. The finished
record includes each consumer's outcome and reason.
It records host/account/provider/thread/turn identity, gateway build identity,
policy version and limits, the frozen model request including prompts and
context, HTTP response body, returned usage/cost when available, timings,
probabilities and triggers, context-limit retries, the side question and its
answer, the proposed title, native
revalidation, rename request/response and title readback. Each model/native
request has its own request ID within the run's `traceId`. Authentication
headers are excluded and the run's provider credential is redacted even if it
appears in a prompt or provider error. No persistent fork is added.

Review records preserve payloads through the existing bounded journal writer,
with a 512 KiB record ceiling, private mode-0600 daily files and 30-day retention.
An oversized or incomplete response explicitly has `payloadComplete: false`;
queue loss remains visible as `journal_drop`, and gaps in per-trace `sequence`
or a missing `finished` record must be treated as incomplete evidence. Terminal
`abandoned` means the task ended without a confirmed outcome, including shutdown
cancellation. Diagnostic markers use `conversationTitleUpdated` for renames and
`conversationReviewSkipped` for failed checks.

```sh
just gateway-journal --kind review --since 7d
just gateway-journal --trace <traceId> --since 30d --json
just gateway-journal --kind review --since 7d --json > review-traces.jsonl
```

These traces support later human review and comparisons by model/policy version;
probabilities and rename counts alone do not establish title or done quality. Exact
past decisions from before this instrumentation cannot be recovered.

## Run

### Conversation settings

`conversation/settings/update` requires `threadId` and `model`, with `effort`,
`serviceTier`, and `summary`. An absent/null effort selects the model default;
an absent/null service tier clears an override. The iOS client loads an older
Codex thread before an explicit settings change only when live metadata reports
it is unloaded. A fresh loaded thread has no rollout to resume yet. Ordinary history browsing
does not load it. The RPC is serialized with voice startup and may wait for two
bounded Claude controls; the client allows 90 seconds.

Codex queues future defaults, checks live activity, and updates the exact active
turn when one exists. Idle threads need no turn-history read, which is unavailable
before the first user message. Enable
`features.step_model_switching` in the owning shared Codex configuration before
the normal gateway handoff: existing sessions acquire this session-static gate
when recovery recreates them. No fork change is required. The upstream path is
experimental and affects subsequent request captures, not an in-flight model
response. A failed control remains a visible error.
Once future defaults are accepted, a failed active-turn update returns
`nextTurn` with a `warning`; the client preserves the accepted selection while
displaying the partial failure. Live active-turn identities avoid requesting
history during the first turn's rollout materialization window.

Claude applies model/effort flags to its existing process and reads back only
the CLI's `applied` settings. Responses distinguish `applied` from `nextTurn`
and include `currentTurnId` when the running CLI query still owns the previous
selection. Codex may report `targetUnavailable` if the exact turn ended during
the change; its future defaults are still updated. Voice startup returns the
current model and effort, and a voice toggle never changes agent lifetime.

The ignored Rust test
`live_settings_switch_preserves_the_process_and_completes_real_input_once`
uses Sonnet at high/medium effort to verify unchanged process identity, actual
next-query model, exactly one completion per real input, automatic effort reset,
and idle settings changes without phantom turns. Run it with `cargo test
--locked live_settings_switch_preserves_the_process_and_completes_real_input_once
-- --ignored --nocapture` from `host-daemon-rs`.

### Manual conversation compaction

`thread/compact/start` accepts `{threadId}` on the conversation's exact account
connection and returns `{}` when the provider accepts the operation. Open a
stored Codex conversation with `thread/resume` first. Acknowledgment is not
completion: both providers emit the normal `turn/started`, `item/started` and
`item/completed` with a `contextCompaction` item, then `turn/completed`.

Codex uses the pinned app-server's native compaction operation. Claude uses its
native noninteractive `/compact` command in the exact recorded session, cwd and
model, preserving a warm runtime's acknowledged selection. Claude item completion
requires a native compaction boundary; an otherwise successful result without
that boundary fails visibly. Compaction items retain their completion identity
in Claude history. Empty compaction completions do not send answer-complete pushes.

The existing admission owner reserves at most 1,024 conversation scopes. A
compaction admission excludes another gateway command on the same conversation
through acknowledgment; its durable pending-turn record excludes new input
until the canonical turn starts. `daemon/activeTurns` represents that pre-turn
scope as per-thread unknown external activity without inventing a turn id;
provider coverage for unrelated conversations remains intact. A real external
owner and stronger busy evidence remain unchanged. Codex checks covered activity, pending starts,
and a fresh native thread status; unavailable activity and already active work
are refused. After native submission, a control transport timeout or disconnect reports
`error.data.kind = compactionDeliveryUncertain` with the exact `threadId` and
`retryable: false`. It retains pending ownership and unknown activity; a native
negative RPC response is a definitive rejection and clears its pending record.
Refresh activity to reconcile delivery before any retry. Accepted Codex operations retain exact client ownership and use
the existing disconnect/restart completion observers. Manual Claude compaction
is interrupted by a planned restart and is never replayed as an ordinary model
prompt or silently retried. Independent background work still follows recovery.

The pinned Codex operation has no conditional-idle parameter and can replace a
running turn. Another client connected directly to app-server can start work
between the gateway's last idle check and native submission. Gateway admissions
cannot make that external-client race atomic; closing it requires an upstream
conditional-compaction contract.

### Queued messages

`thread/queue/add`, `thread/queue/list`, `thread/queue/start` and
`thread/queue/delete` expose the pinned Codex app-server's durable queue on Codex
threads; `AGENTS.md` (*Gateway RPCs*) owns the contract. The gateway's lease of
the messages it queued lives in `active-codex-turns.json` as
`queued_submissions`, and pending starts gain `client_user_message_id`. Both are
written only while present, and a gateway built before them rejects a turn state
that contains them, so roll back only once no leased message or pending start
with a client id remains. `just gateway-e2e-queue-live` is the live acceptance
probe.

### Development process

```bash
cd host-daemon-rs
cargo run --release -- --env-file ~/.remote-coder/codex-gateway.env
```

## LaunchAgent (macOS)

`install-launchagent.zsh` is the low-level worker that stages a prebuilt
signed `RemoteCoderGateway.app` bundle and hands the cutover to the gateway's own
`runtime install-gateway` transaction, which registers the LaunchAgent under
`~/localbin/remote-coder-gateway`. It never builds: without a gateway path it
exits 2. Invoke it directly only for an initial installation with no managed
app-server running; a live replacement must use the detached recipes below,
because the worker rejects a synchronous live cutover before it can fence new
work.

```bash
host-daemon-rs/scripts/install-launchagent.zsh /path/to/RemoteCoderGateway.app
```

For a gateway-only deployment, build once and pass the candidate to the safe
recipe. It submits the launchd-owned one-shot installer, waits for its recorded
job, and verifies Desktop plus gateway health before returning:

```bash
just gateway-candidate
just gateway-install-prebuilt /path/to/RemoteCoderGateway.app
```

The candidate recipe builds on `scripts/build-host` (the configured build host) or the host
`RC_GATEWAY_BUILD_HOST` names, and uses worktree-scoped leases and caches. Its
JSON receipt returns a unique candidate path under
`host-daemon-rs/target/deploy/BUILD_ID/` and the candidate SHA-256; it never
compiles elsewhere when the selected builder is unavailable
([operation ownership](../docs/owned-operations.md)).

The paired runtime and gateway cutover runs as the same kind of one-shot job,
which survives the suspension of the turn that submitted it. Re-running it with
the exact installed package skips the runtime replacement and updates only the
gateway and Desktop integration. `just shared-codex-deploy` copies the
installer's tracked inputs from the current checkout and both prebuilt
artifacts to a temporary stage on the host, submits the installer and finishes
with Desktop, gateway and exact `/version` checks. It skips the install when
the host already runs a gateway with the same SHA-256:

```bash
just shared-codex-install /path/to/codex-package /path/to/RemoteCoderGateway.app
just shared-codex-install-status
just shared-codex-deploy <deployment-host> /path/to/codex-package /path/to/RemoteCoderGateway.app
just shared-codex-status <deployment-host>
```

The runtime installer writes a read-only approval record beside each package:
`releases/approvals/<package-manifest-sha256>.json`. The router selects that immutable
record from the installed package manifest. Approval and rollback never depend
on a Git checkout, and the record does not change the package's content identity.
For an existing approved installation, bootstrap the record with
`scripts/codex-runtime-approval install-record --package <installed-package> --repo-root <approved-repo>`.

Install gates, in order:

- The candidate must be `RemoteCoderGateway.app`, signed as an app bundle with
  the identifier `com.remote-coder.codex-gateway`. The tracked
  `RemoteCoderGateway.template/Contents/Info.plist` owns the identifier and executable
  name; `gateway-candidate` signs once, using ad hoc signing for a public local
  build or the configured Developer ID for a maintainer build. The installer rejects
  flat binaries, verifies the whole bundle, never re-signs, and smoke-tests the
  main executable's `--version` before the health checks.
- Each `versions/<hash>/` contains the bundle and a relative
  `remote-coder-codex-gateway` symlink to its main executable in `Contents/MacOS`.
  The stable alias points through `current`, and `pair.json.gatewayHash` remains
  the main executable's SHA-256. Immutable reuse checks every bundle file. Flat
  legacy versions remain valid as `current` or `previous`, including rollback;
  their original privacy attribution remains path-based.
- The LaunchAgent declares `AssociatedBundleIdentifiers`. Before executing
  the selected bundle, the cold-start launcher unregisters other executable
  copies of that bundle identifier from LaunchServices, then registers the
  selected copy. Source templates use `.template` rather than `.app` to avoid
  incomplete applications in LaunchServices. This preserves retained rollback
  bytes while giving macOS one registered executable copy. Apple does not
  support an MDM Local Network grant; verify a gateway-owned LAN read after a
  new gateway version, because that permission is separate from TCC and macOS
  has known multiple-copy identity bugs.
- Before launching Desktop it requires three successful Codex lifecycle probes
  at five-second cadence (three-minute ceiling), so ChatGPT's shorter built-in
  probe does not mistake a still-settling daemon for a failure.
- The app-server enforces a soft `RLIMIT_NOFILE` floor of 8192. Candidate
  acceptance reads the authenticated `GET /diagnostics` witness and requires
  its process id to match the managed app-server and a soft limit of at least
  8192 or unlimited. `GET /health` stays the generic readiness check and never
  issues the diagnostics RPC.
- A failed initial health or Desktop attachment gate restores the paired
  gateway and runtime transaction. A Desktop launch failure afterwards is
  reported and retried independently; it never tears down healthy Codex service.
- Upgrading a pre-transaction runtime that cannot speak the current restart
  protocol first stops Desktop, disables the old relay and requires an empty
  bounded active-task inventory; it refuses when any task is active.

Managed Desktop launches set `CODEX_ELECTRON_DISABLE_QUIT_CONFIRMATION=1` so a
normal quit finishes unattended and cleans up the app's own children. The flag
is removed when Desktop integration is rolled back or uninstalled, and its
absence is not a configuration-mismatch restart reason. Bundled stdio helpers
may belong to Computer Use or other callers; their presence never authorizes a
Desktop restart.

Every gateway startup, install and recovery also publishes
`CODEX_SPARKLE_ENABLED=false`, which removes ChatGPT's Sparkle updater from any
app launched afterwards, including manual launches on hosts with Desktop
management disabled. The managed `in_app_updates = false` requirement alone
fails open: ChatGPT waits five minutes for its app-server to deliver the policy
and then allows updates for that launch, and an update replaces the bundled
Codex the shared runtime is paired with. A running ChatGPT without the variable
is therefore an environment mismatch that reconciliation relaunches and
`runtime desktop check` rejects. The variable stays set through rollback and
uninstall until the user logs out, so no rollback or isolated probe re-arms the
updater.

### Hosts without ChatGPT Desktop

The private `~/.remote-coder/host-profiles.json` can list hosts that run without
automatic ChatGPT Desktop management. Tracked defaults are empty, and
`runtime desktop mode` prints `shared` or `disabled` for the current host.
On a disabled host:

- Install, restart, reconcile and recovery never open ChatGPT; the desktop
  journal records the `disabled` decision. A transaction still stops a running
  ChatGPT before it replaces the app-server.
- Gateway startup still publishes `CODEX_APP_SERVER_WS_URL` in the Aqua
  launchd session; the operator owns inherited CA policy. Launching ChatGPT
  manually attaches to the same managed app-server without the periodic helper.
- The installer removes the periodic Desktop helper and skips the Desktop
  attachment gate. The gateway health, scheduling, file-descriptor and Codex
  lifecycle gates and the ChatGPT build check are unchanged, because agents
  still load the app bundle's bundled plugins.
- `just shared-codex-status <host>` reports Desktop as disabled, and
  `runtime desktop check` fails.

To restore automatic Desktop management, remove the host from the private list and restart the
gateway there; the installer then reinstalls the helper and requires attachment.

ChatGPT Desktop belongs only to the gateway whose Codex home is the user's own
`~/.codex` from the account database, whatever `HOME` says. A gateway on any
other Codex home, such as an isolated probe, reports `isolated`: it never
observes, stops, opens or configures ChatGPT, never publishes its socket in the
Aqua launchd session, journals the `isolated` decision instead, and refuses
`runtime install-gateway` and `runtime uninstall`.

The restart and recovery contract (every SIGTERM interrupts and resumes exact
work, `just codex-daemon-restart`, `prepare-shutdown`, `prepare-handoff`) lives
in [`AGENTS.md`](AGENTS.md), *Install, restart and recovery*.

The launch agent starts through `zsh -lc`, optionally sources the env file
named by `RC_CODEX_GATEWAY_SHARED_ENV_FILE`, then runs `launch-codex-gateway`.
That wrapper only resolves the installed binary and execs it; the Rust binary
performs bootstrap and pending recovery before it opens the listener.

Uninstall:

```bash
host-daemon-rs/scripts/uninstall-launchagent.zsh
```

Uninstall fails closed while ChatGPT, a Codex proxy client, or a gateway-owned
turn is active. Once idle, it stops the desktop helper and gateway before the
managed daemon, verifies the canonical socket disappeared, and only then removes
the desktop opt-in.

Logs (`~/Library/Logs/remote-coder/`): `codex-gateway.out.log`,
`codex-gateway.err.log`, `chatgpt-shared-codex.log` and
`chatgpt-shared-codex.error.log`.

## API

- `GET /health` (requires `Authorization: Bearer <token>`); includes
  `lanEndpoint` (see [LAN TLS listener](#lan-tls-listener))
- `GET /relay` (requires `Authorization: Bearer <token>`; `Cache-Control:
  no-store`); `{"proxyHost","proxyPort","proxySpkiSha256","targetHost",
  "targetPort","username","password"}` for the relay route to the LAN listener,
  404 when this gateway has none, or 503 when its relay file is unreadable
- `GET /version` (requires `Authorization: Bearer <token>`); the build's
  `{"version","commit","modified"}`, also printed by `--version`. Release
  builds report `X.Y.Z`, the full commit and `false`; other builds report
  `"dev"`, with `null` for anything the build did not record
- `GET /diagnostics` (requires `Authorization: Bearer <token>`; candidate
  acceptance witness for the live app-server process and `RLIMIT_NOFILE`)
- `GET /ws` WebSocket (requires `Authorization: Bearer <token>`)
- `POST /files/download` (requires `Authorization: Bearer <token>`).
  Streams an existing regular host file independently of either agent provider;
  see [File downloads](#file-downloads).
- `PUT|GET|DELETE /uploads/<uuid>` (requires `Authorization: Bearer <token>`).
  A resumable upload of one file the agents can read by path. `PUT ?name=`
  appends a raw body at `X-RemoteCoder-Upload-Offset` and declares the whole
  file's `X-RemoteCoder-Upload-Length` and `X-RemoteCoder-SHA256` (64 hex
  digits); `201` returns `{"path","bytes","sha256"}` with the absolute
  canonical path once both are verified. `GET` returns the `offset` to continue
  from, and `DELETE` discards an unfinished upload. A full volume is `507`.
  The protocol, limits and storage rules are in [`AGENTS.md`](AGENTS.md),
  *File uploads*; `rc-gateway upload <file>` is the CLI client.
- `/speech/<provider>/<upstream path>` HTTP and WebSocket (requires
  `Authorization: Bearer <token>`). Relays SpeechKit's allowlisted operations
  for `openai`, `elevenlabs`, `gemini`, `assemblyai` and `azure` through
  llm-router's vendor passthrough (*Speech providers*). Rejection markers and limits are in
  [`AGENTS.md`](AGENTS.md), *Speech relay*.

### File downloads

`src/files/mod.rs` owns `POST /files/download`. Send `Content-Type: application/json`
with `{"path":"/absolute/host/path","knownRevision":"optional opaque revision"}`.
Omit `knownRevision` for the first download. File requests may also carry
`containingDirectory`, an absolute directory restricting the resolved file to
that directory and its descendants, including contained symlinks. Containment
is checked before conditional responses and descriptor-relative opening.

Inline visual requests instead carry `{"visualDigest":"<64 lowercase hex>","knownRevision":"optional opaque revision"}`.
They cannot carry `path` or `containingDirectory`. The gateway resolves the
digest inside its owned visual store, rejects symlinks in the file or directory
chain, and enforces 2 MiB before sending bytes or an unchanged response. Ordinary
file requests retain the 1 GiB limit. There is no caller-selected byte limit.

The path is carried in the body,
never in a public file URL, and uses the gateway's existing bearer authorization.
It must be absolute UTF-8, at most 4096 bytes and contain no NUL; lexical `.` and
`..` normalization cannot traverse above the filesystem root. Symlinks may
resolve to regular files; validation uses the opened descriptor.

Success is `200 application/octet-stream` with exact `Content-Length`, or
bodyless `204` when `knownRevision` matches. Both return `Cache-Control: no-store`
and `X-RemoteCoder-File-Metadata`, standard base64 of UTF-8 JSON:

```json
{"path":"/absolute/host/path","name":"path","bytes":123,"modifiedAt":1790000000.25,"revision":"opaque"}
```

`path` is the normalized requested file path, or the server-resolved visual path.
Visual clients identify content by host and digest and do not construct that
private storage path. `name` preserves the filename,
`modifiedAt` is fractional Unix seconds, and `revision` is descriptor metadata
used as a change indicator, not a content digest or transactional snapshot.

Before a response starts, file errors return JSON `{"kind","message"}`:

| HTTP | Kind |
| --- | --- |
| 400 | `invalidPath`, `notFile` |
| 403 | `accessDenied` (host filesystem permission) |
| 404 | `missing` |
| 409 | `changed` |
| 413 | `tooLarge` |
| 429 | `busy` |
| 503 | `draining` |
| 500 | `io` |

Authorization failures keep the gateway's existing response shape. A failure
after headers terminates the body; clients must reject incomplete downloads
instead of expecting a replacement JSON response.

Limits are 1 GiB per file, two simultaneous downloads and a 30-second stall
timeout, with no total duration cap. Empty regular files are valid. Opening is
nonblocking before descriptor validation, so FIFOs and other special files do
not wait for a producer. Reads use bounded 64 KiB chunks and check descriptor
revision before publishing the final bytes. Truncation or detected changes fail
the transfer. Disconnect, cancellation and gateway drain release the transfer's
resources; no provider process is started to read a file.

The app's cache, reference routing and preview/export contract is in
[Remote files](../docs/remote-files.md). `just gateway-e2e-files-live` exercises
transport and provider link generation; [dev-tools](../dev-tools/AGENTS.md)
describes its side effects and receipt.
