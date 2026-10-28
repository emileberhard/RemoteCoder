# Gateway Agent Context

Maintainers: configured hosts, devices and private operational prerequisites live
in the [private operations entrypoint](https://github.com/emileberhard/RemoteCoder-deploy/blob/main/AGENTS.md).

Rules for the Rust gateway, its managed Codex runtime, the Claude provider,
agent tools and the gateway side of voice. The root `AGENTS.md` also applies.
`README.md` here covers configuration, installation and local operation.
This file owns the topology, restart and recovery contracts (*Process model*,
*Codex runtime and Desktop*, *Install, restart and recovery*), and
`docs/system-architecture.md` holds the end-to-end contracts.
Compare app-server protocol changes between exact fork revisions with
`git -C <codex-source-checkout> diff <old> <new> -- codex-rs/app-server-protocol/`;
`CODEX_BIN=<candidate>/bin/codex just codex-schema` generates the candidate
schema under ignored `build/codex-schema/<version>/`.

- `JobStore` owns exact-job message admission grants. Execution transitions and
  successor admission wait for native custody admission, including after caller
  cancellation; the owned message task retains the per-ID claim and shutdown
  read guard. Stop persists and signals independently. Never hold this grant
  through a model turn or release it by canceling an in-flight provider RPC.
  New Codex messages steer a known running turn with the stable message ID and
  expected turn ID; the runtime job binding must match. A steer refusal never
  falls through to a queued turn, and accepted historical input is never resent.

## Verify

The root file decides which checks a change needs; gateway changes count as
larger ones. These live probes each make a real agent or client exercise one
surface:

| Surface | Probe |
|---|---|
| History reads, native pages, `daemon/activeTurns` (read-only) | `just gateway-e2e-reads`, optionally `e2e_thread=<id>` |
| Owned read burst, exact query cancellation and ready capability (isolated gateway) | `just gateway-e2e-query-admission-isolated /absolute/gateway/binary` |
| Delegated jobs: Codex and Claude children spawned from a parent's tool process, results, parent callbacks, Stop, restart recovery and same-ID retry (isolated gateway, deterministic Codex model, host router for Claude) | `just gateway-e2e-delegated-jobs-isolated /absolute/gateway/binary /absolute/runtime/package` |
| First-party-first new conversation admission and last-resort effort clamping (isolated gateway, host router; logged-out Codex xhigh runs on Opus, then unavailable Claude forces Argon high, including a resumed Fast request) | `just gateway-e2e-provider-fallback-isolated /absolute/gateway/binary` |
| `thread/fork(lastTurnId:)` boundaries (creates threads) | `just gateway-e2e-fork-live`, `just gateway-e2e-claude-fork-live` |
| Claude steering folds into one completion (router-backed Sonnet; one completion plus an empty active-turn snapshot) | `just gateway-e2e-claude-steer-live` |
| Claude agent-initiated turns | `just gateway-e2e-claude-wake-live` |
| Thread naming on a live and an idle runtime (one `thread/name/updated` per rename, `-32602` before a Claude thread's first turn) | `just gateway-e2e-thread-name-live` |
| Automatic titles and done: Jev, marks, side question, cached input, rename (creates one Codex and one Claude conversation, hidden as probes afterwards) | `just gateway-e2e-titles-live` |
| Agent tools on both providers | `just gateway-e2e-agent-tools-live` |
| iPhone tool transport, image inference and saved originals | `just gateway-e2e-device-tools-live` |
| Codex queued messages (FIFO successor turns with their canonical `clientId`, none in the running turn, idle afterwards, held after Stop, Send Now; creates a thread) | `just gateway-e2e-queue-live` |
| File upload handoff on both providers | `just gateway-e2e-upload-live` |
| Voice resume context | `just voice-probe-resume-context` |

`dev-tools/AGENTS.md` documents `./dev-tools/rc-gateway` and the other debug
CLIs.

Unit tests run on the build host as the invoking user, so a test that reaches a
real home writes into live state. `ClaudeSettings` deliberately has no
`Default`: build test settings with `ClaudeSettings::isolated_for_test()` and
keep the returned owner alive for the test's scope. Only the ignored live
router probes may name the live Claude home, and they do so explicitly.
Use `test_support::TestGateway` for gateway fixtures; its clones retain that
owner until the last fixture is dropped.

## Delegated jobs

`agents::jobs::JobOwner` owns external work through the existing gateway,
provider supervisors and restart owners. `docs/delegated-jobs.md` owns the
Agent/Job/execution model, exact process attribution, durable Stop, result and
delivery invariants. The installed binary's `agent` subcommand is the client;
no launcher process, second ancestry registry or runtime legacy reader exists.
Native terminal Claude holders own only their process-lifetime inbox route.
Scoped caller coordination belongs to the gateway lifetime, namespaced by its
job-store root; it proves the actual provider process and resolves the current
job from the conversation. Finishing a job must not remove that shared route.
Native caller proof validates the peer before provider lookup and verifies ancestry
only through the daemon's exact tool root; unrelated launcher ancestors above
that owner are outside the proof.

Manual message receipts share `JobStore` and its cap. Their frozen sender,
requested target, envelope, resolved conversation and target job survive retries;
never resolve a retry against a newer invocation. Message-driven Continue uses
the atomic previous-job and Stop fence. `agent/messages/read` is the read owner;
scoped receipt reads require the exact sender conversation.

## Process model

- One version-matched default `codex app-server` per host listens on the
  user-private `~/.codex/app-server-control/app-server-control.sock`. ChatGPT
  Desktop, RemoteCoder and external Codex agents share that process and native
  home, but never a protocol connection. Native provider logins work without a
  router; an explicitly configured llm-router can own provider identities;
  RemoteCoder serves only `default-codex` and `default-claude` contexts.
- The Rust binary owns cold-start and planned-recovery transactions. In
  ordinary operation its gateway path only observes and proxies; it changes
  lifecycle only while bootstrapping or completing an explicit persisted
  recovery. Launch wrappers stay thin callers. The health loop observes a
  canonical WebSocket handshake and official daemon identity, logs sustained
  degradation and leaves recovery to the tracked runtime transaction, which
  fences new work, snapshots active task trees, stops the verified owner and
  starts the replacement through the official daemon commands.
- API: `GET /health`, `GET /version` and `GET /ws`, authenticated by `Authorization: Bearer`
  with the operator token or a revocable installation credential.
  `POST /credentials/enroll` is operator-only (`docs/owned-operations.md`).
  Token values never appear in logs or source.
- With `RC_CODEX_GATEWAY_LAN_PORT` set, every route is also served over pinned
  TLS 1.3 on `0.0.0.0` and published as `lanEndpoint` in the authorized
  `/health`. The app's `GatewayRoutes` tries it first on Wi-Fi or Ethernet
  (`docs/system-architecture.md`, *LAN route*). With
  `~/.remote-coder/relay/relay.json` present, the authorized, uncached
  `GET /relay` publishes the route through the relay to that listener
  (`docs/relay-route.md`); `/health` never carries its credential.
- Every authenticated remote WebSocket starts with a `daemon/ready` frame sent
  before the client speaks. The app's route handshake waits for that first
  frame, so a `/ws` path that sends nothing first never connects. Its
  `capabilities.cancelRequest: true` advertises connection-scoped query
  cancellation, and its `providers` carries the gateway-owned provider health
  ([Provider health](../docs/provider-health.md)).
- Only draining refuses a client. While Codex control is not ready (including
  a pending recovery journal) or a connection's own app-server connect fails,
  the client is served without Codex: gateway-owned requests run, `initialize`
  is answered locally and native requests fail with `providerUnavailable`.
  Codex becoming ready closes those connections with 4012; a connection whose
  own connect failed while control was ready retries it (5 s doubling to 30 s)
  and closes with 4012 on success. New Codex work on any connection waits for
  ready control, which follows restart recovery.
- Every authenticated remote WebSocket gets its own Unix WebSocket. The
  client's own `initialize`/`initialized`, request ids, capabilities,
  subscriptions, notifications and server requests pass through that exact
  connection unchanged, with no global fan-out. The one deliberate annotation is
  a top-level `rcSequence` on stored notifications, naming their
  notification-history sequence without touching `params`.
- Every connection subscribed to a thread (clients, the control connection, a
  disconnect observer) receives the same notification, and the Claude
  translator is one more origin. History pairs a connection's copy with the
  first identical entry recorded after both that connection opened and its
  previous copy on the thread. A second connection never duplicates a replay,
  repeated identical states stay distinct, and a reconnect never inherits an
  earlier occurrence. App-server notifications carry no event identity, so
  streaming deltas (`*/delta`, `*Delta`) are live-only: they are neither stored
  nor stamped, and the app never applies a replayed delta. Every stored
  notification carries its item or turn identity or is idempotent state. A
  connection that newly subscribes to a thread can still pair its first state
  notification (`thread/status/changed`) with an identical one recorded in the
  previous five seconds; the app takes busy state from activity, not replayed
  status.
- Claude content observation is connection-owned. `conversation/subscriptions/set`
  atomically replaces up to 64 distinct Claude thread IDs (at most 512 bytes each).
  Invalid input or typed capacity leaves the previous mode/set intact. A successful
  first set enables filtering, including an empty set; connections that never set
  retain legacy full Claude fanout until every shipped client opts in
  (`docs/compatibility-register.md`). Lifecycle/activity/name/marks/questions,
  favorites and preferences remain global. Item deltas, plans, diffs, usage, scoped errors and stderr go only to
  subscribed clients. Unknown methods and content without thread identity are
  journalled and fail closed for every client. Ingest still records replay,
  push, Live Activity and voice once before routing. Subscription replacement and
  content queue admission share the connection state lock; a removed subscription
  cannot admit content after replacement. Claude fanout uses nonblocking admission
  to each client's independent bounded writer; a full queue disconnects only that
  client. The 32-command queue and 60-second socket-write budget remain unchanged.
- Each direction has an independent bounded queue. Closing either side cancels
  both pumps and releases only that client's app-server subscriptions.
- `initialize` + `initialized` is per connection. Remote clients perform their
  own handshake unchanged, and gateway control and observer connections perform
  only their own.
- Gateway-owned voice and control work uses a separate initialized connection.
  A phone disconnect during an active turn creates one temporary observer
  connection that records completion and push state and then calls
  `thread/unsubscribe`; idle clients and permanent observers keep no thread
  loaded.
- Codex pending and accepted turn ownership is persisted before the client
  acknowledgement. A gateway restart therefore reconciles an already completed
  turn or resumes the same bounded observer path without replaying work. A
  tracked turn whose completion no client observed finishes when the control
  connection reports its thread inactive and `thread/turns/list` confirms that
  exact turn ended. Claude turns stay in their provider-owned runtime and never
  enter the Codex recovery ledger; *Install, restart and recovery* covers both.
- Startup sweeps abandoned atomic-write temporaries for the host-default
  active-turn ledger before loading it, even when the ledger is absent. The
  private-state owner recognizes only that ledger's current PID/counter names
  and former `.new.<pid>` names. It removes regular files only when the PID
  probe confirms no process exists; live/reused/unknown PIDs, malformed names,
  symlinks, directories and other state files are preserved. Replacement failures
  already remove the successfully created temporary on write/sync/rename failure.
- Health means process, socket and WebSocket-handshake health. Slow application
  RPCs and socket-probe failures are telemetry, never restart authority.
- The gateway runs inside the Developer-ID-signed `RemoteCoderGateway.app`.
  `RemoteCoderGateway.template/Contents/Info.plist` owns
  `com.remote-coder.codex-gateway`. The source template is not an `.app`, so
  checkouts cannot register incomplete gateway applications. The LaunchAgent
  associates that bundle identifier; each cold start unregisters other
  executable copies from LaunchServices and registers the selected bundle.
  Developer ID signing keeps TCC grants stable across versioned paths. Local
  Network is a separate macOS permission with no MDM grant; multiple installed
  copies can confuse its identity tracking, so new-version acceptance must
  include a gateway-owned LAN read without another consent dialog.
  At startup it probes Full Disk Access by
  opening the system TCC database (that service never prompts; macOS 27 has
  no per-user one) and reports
  `fullDiskAccess {required, state, detail?}` in `/health`. `required` comes from
  the private `~/.remote-coder/host-profiles.json` `fullDiskAccessHosts`; `scripts/shared-codex-host`
  fails a deploy check on a host that requires it unless `state` is `granted`.
  The check runs after the install commits and never rolls back: the grant is
  host configuration that no earlier binary could satisfy either.
  The grant itself is the operator-managed automation PPPC profile.
- `ConnectionQueries` owns each socket's FIFO and running gateway-owned reads.
  Socket reading never waits for query permits. One gateway owns the host
  request budgets. [Owned operations](../docs/owned-operations.md#gateway-and-claude-concurrency)
  owns admission limits, overload semantics and deadlines.
  Transport records `request_capacity` and `query_cancelled` include client,
  method, thread when known, resource and queue depth without input content.
- Query deadlines include FIFO, host admission and handler time.
  Expiry drops the future, frees
  its request permits, answers typed `requestTimedOut` and journals
  `transport query_timed_out`. Disconnect drops queued and running reads.
  `/health`, `daemon/activeTurns` and the activity snapshot read only short
  critical sections; the gateway's Claude supervisor slot is a synchronous
  clone-out accessor, so no caller can hold it across an `.await`. Clippy's
  `significant_drop_in_scrutinee` is denied for the same reason: a lock guard
  in an `if let`/`match` scrutinee lives through the whole block, including
  its awaits.
- the operator environment file owns `SSL_CERT_FILE`; the gateway, runtime and
  Desktop inherit it without projecting, clearing or replacing host CA policy.
  Upstream builds each app-server WebSocket's Rustls roots through
  `rustls-native-certs`, which then reads only that bundle, so macOS
  trust-settings latency cannot stall app-server I/O.
- String JSON-RPC IDs are limited to 512 UTF-8 bytes; signed integer IDs retain
  their normal range. The inbound parser rejects oversized IDs before request
  admission with typed capacity and `id: null`; invalid ID types are rejected.
  The transport encoder serializes each authored frame once, retains at most
  32 MiB, and counts discarded overflow bytes without allocating them. Queues
  contain only bounded text or metadata-only rejection commands; serialized
  input is checked before recipient copies. Sequence stamping stays within the
  same cap, and the single client writer retains a final guard before any
  large-frame announcement. `wire/json.rs` owns the capped encoder, shared with
  nested MCP image compaction. Nested encoding overflow rejects the whole frame
  through the same page-error or connection-close path; no partial nested text
  is forwarded. Capacity metadata identifies `nested tool JSON bytes` when its
  byte count describes that intermediate, and the complete frame size remains
  unknown. Counting mode measures pending-tool, projection-cache and question
  budgets without retaining serialized output; unmeasurable values are refused
  admission or cache retention. Conversation review counts only up to its current
  byte budget and prepares UTF-8 bookends directly within that budget. In-budget
  dialogue is preserved; oversized dialogue retains both ends with the existing
  omission marker, and latest-user-goal preparation borrows the original text. An oversized response becomes a typed request-local
  capacity error for that ID; the connection and subsequent requests stay usable. An
  oversized notification or server request closes with 1009 so live content is
  never silently discarded while a connection remains active. Reconnect restores
  subscriptions and reads canonical history; deltas are live-only, and the
  existing 16 MiB history/8 MiB replay bounds exclude oversized frames from replay.
  Unretained records advance the history watermark and eviction state without
  copying their payload; accepted notification side effects still run once.
  History's lower 24 MiB page policy and `historyPageTooLarge` remain independent:
  smaller pages recover readable items, while an individually oversized item
  remains unavailable. `outboundFrameCapacity` records method, thread, client
  and byte counts once, with no frame content. A response capacity error describes
  delivery; it neither cancels admitted work nor authorizes retrying a mutation.
- Frames and assembled messages are limited to 32 MiB on both legs. Native page
  responses over 24 MiB return a request-local `-32003`; larger upstream frames
  get a typed capacity error before a bounded close.

## Retired account adoption

- `accounts::codex_migration` owns idempotent, receipt-backed adoption of every
  legacy Codex profile into the host-default home. It copies rollout files and
  per-thread assets and preserves native rows in `state_5.sqlite`,
  `thread_history_1.sqlite`, `queue_1.sqlite`, `goals_1.sqlite` and
  `memories_1.sqlite`. Its isolated adapter verifies the exact pinned schemas
  and migration versions before writing; incompatible schemas or unresolved
  conflicts fail closed. Snapshot stopped database/WAL families with the existing
  APFS clone owner under the native adoption lock. Keep source homes as cold copies: never move or delete
  their history, attachments or companion gateway state.
- `runtime::accounts` captures surviving legacy daemons' exact task trees through
  the existing recovery transaction, suspends leaves before parents, and stops
  each verified daemon through official lifecycle commands before adoption.
  It transfers the recorded work into the default recovery journal. Starting
  transferred work uses the tracked default restart and its generation-bound
  grant when required; this path never independently restarts the default daemon.
  The installer leaves stopped handoffs stopped until adoption has transferred
  every target. A recovery grant is loaded only while starting a stopped daemon;
  an idempotent start of an existing daemon cannot install authorization.
- The installer snapshots migration destinations until the adoption commit.
  The final commit requires the durable default recovery journal before removing
  the retired registry entries. Adoption is then forward-only: a previous-binary
  rollback retains adopted history, gateway state and the default recovery
  journal. Old app enrollment windows may fail against that rolled-back binary.
  Do not restore pre-adoption state after this boundary.
- `GET /accounts` contains only `default-codex` and `default-claude`, plus
  `retiredCodexAccountIds` and `retiredClaudeAccountIds`. The gateway redirects
  either retired UUID to its host-default context regardless of the supplied
  generation. Enrollment creation, provisioning, login, toggles, updates and
  removal are unsupported. The registry is read-only migration input; no loaded
  account slots or separate account gateways remain. `daemon/activeTurns` covers
  the single Codex runtime by construction, without cross-runtime aggregation.
  [Provider accounts](../docs/provider-accounts.md) owns the complete migration
  and rollback contract; the compatibility register owns redirect removal.

## Account reset routes

- `GET /accounts` includes Codex `resets` mapped from the existing quota read;
  `GET /claude/accounts` maps the router inventory's reset observations. Both
  translate the router's normalized object through `accounts::resets`; malformed
  resets affect only that account's resets, and resets expire with usage windows.
  `docs/provider-accounts.md` owns the nullable counts, details and wire shape.
- `POST /accounts/default-codex/resets/redeem` takes `{resetId, idempotencyKey,
  generation}` with the fixed default generation `1`; other Codex context IDs
  are rejected before submission.
  `POST /claude/accounts/resets/redeem` takes `{accountId, resetId, idempotencyKey}`.
  Both require
  gateway auth and proxy one exact attempt through the shared router transport,
  with `accounts:redeem`, a canonical lowercase UUID key and a 35-second request
  deadline. Never retry a redeem automatically;
  `redeem_unconfirmed` requires the caller's same key, account and reset. Router
  4xx and 503 are definite refusals even with unreadable bodies; 504 and other
  unexpected statuses, post-send failures and invalid 2xx responses are
  unconfirmed. Reads keep neutral transport errors. Missing account management
  uses 503 `account_management_unavailable`; temporary router observation/store
  failures use 503 `router_retry_later`.
- Tracked host work owns redemption and its follow-up refresh even when the
  client disconnects. A refresh failure cannot replace a confirmed outcome.
  Codex refreshes use canonical account keys and dirty generations so a later
  redemption cannot lose its refresh. Both routes use the gateway's reset task
  owner. Claude runs `claude/accounts/refresh` after replying.

## Gateway RPCs

- External model providers (`src/providers/codex/external.rs`, wired in
  `src/gateway/external_providers.rs`) come only from the operator file in
  `RC_CODEX_GATEWAY_EXTERNAL_PROVIDERS_FILE`; public sources carry no ids, URLs
  or model names. The owner projects each provider's `/models` listing into a
  Codex catalog file under `<state>/external-models/` (removed with the
  configuration) and never tunes prompts, tools or behaviour per model: every
  row gets the same generic harness defaults. Admission runs on every Codex
  request path that reaches the app-server, native passthrough, control calls,
  pending/observer resumes and restart recovery, so non-UI callers get the same
  rules:
  - Projection offers only models whose listing reports `/v1/responses`, a
    positive `prompt_tokens`, `streaming` and `tool_calls`.
  - `thread/start` takes `modelProvider`, or the provider that lists the model;
    the gateway injects `model_providers.<id>` and `provider_model_catalog_json`
    into its `config`.
  - `thread/resume` and `thread/fork` read the source thread's provider and keep
    it; another `modelProvider`, or a model of another provider, fails. A
    resume of an external thread always carries its `modelProvider`: a resume
    that overrides the model makes Codex skip the persisted provider and store
    the config default (`openai`) instead. A prediction-mode fork inherits
    without config, which Codex rejects there.
  - `turn/start`, `thread/settings/update` and `turn/settings/update` with a model
    (`model` or `collaborationMode.settings.model`) or service tier
    (`serviceTier` or `serviceTierForTurn`) are checked against the thread's
    provider; external providers have no service tiers.
  - A `config` override that names the model, its provider or catalog, a
    service tier or a profile fails; only the request's own fields select them.
  - `thread/list` without `modelProviders` lists ChatGPT and every external
    provider. `thread/restart/recover` is admitted like `thread/resume`: an
    external thread's recovery carries its provider definition and catalog,
    which the fenced daemon applies only when it loads the thread from storage.
  - `model/list` is gateway-owned: the native list plus one row per external
    model, with `modelProvider` and `modelProviderName`, on the last page.
  - The first configured provider is the Codex fallback. A failed router token
    issue holds Codex readiness for at most 2 minutes while the recovery
    journal has pending tasks; while no valid subscription token is installed, client
    `thread/start` on the native provider moves to the fallback's matching or
    first model, and threads never change provider afterwards. On fallback
    threads, every thread-scoped request (`thread/resume`, `thread/fork`,
    `turn/start`, settings updates) maps a native model to the matching
    fallback model or drops it, and drops service tiers, through
    `ExternalProviders::map_onto_fallback`
    ([Provider health](../docs/provider-health.md)).

- `src/rpc/dispatch.rs` owns request lifetime classification.
  `conversation/subscriptions/set` executes on its connection in socket order,
  outside read admission. `daemon/activeTurns`, `daemon/liveActivity` and
  `host/info` use separate host-wide status admission and never wait behind the
  read FIFO or consume the urgent reserve for interrupt, stop and teardown.

- `$/cancelRequest` is a gateway-owned notification with `params.id` equal to
  the exact JSON-RPC id of an earlier gateway-owned Query-lifetime request on
  that connection. It removes queued work or drops a running future and answers
  once with `-32800`, `Request cancelled`, and
  `data: {kind: "requestCancelled", retryable: false}`. A terminal response
  claims its request only when it enters the outbound queue, so cancellation
  cannot race an already committed response into a second answer. Unknown,
  finished, non-query and native-passthrough ids are ignored. This notification
  never reaches Codex. Sending it with a top-level request id returns
  `InvalidRequest` without cancelling its target. Clients send it only after
  the ready capability above.

- `turn/inspect` reads exact execution evidence without admitting work. The
  gateway owns provider activity, recorded terminal errors and explicit Claude
  restart links; the automation service owns ordering and workflow decisions.
  [Execution recovery](../docs/automations.md#execution-recovery) owns the
  response, bounds, unknown evidence and rollout contract. Claude adds these
  facts to existing `TurnIdentity` records; the restart journal owns pending work.

- Codex `turn/interrupt` is gateway-owned (`CodexStop`,
  `src/gateway/agent_gateway/stop.rs`); the agent card's Stop on a native Codex
  child runs the same path, so it stops that child's subtree too. It first reads the thread's
  latest turn (`thread/turns/list`, 3 s) and interrupts nothing unless that
  turn is running with the exact `turnId`: a missing id is `-32602`, a
  different or ended turn is `-32600` with `data.kind` `turnNotRunning`, and a
  state it cannot read is `-32603`. On a match it interrupts the turn and, concurrently,
  every running native descendant: `thread/list` by `ancestorThreadId` with
  fresh latest turns (at most 256), interrupted four at a time with 5 s each
  and 10 s overall. After each interrupt it ends that thread's background
  terminals (experimental `thread/backgroundTerminals/clean`), because a
  Codex interrupt leaves the turn's shell commands running; this also ends
  long-lived shells an earlier turn started. A descendant whose turn already
  ended, or a thread that is not loaded, counts as stopped. One that could
  not be listed, has no known running turn, did not answer or whose commands
  could not be ended makes the reply `-32603` naming it, after the rest was
  still stopped.
  A turn that ends between the check and the interrupt still has its running
  descendants interrupted, and the pinned app-server can leave that late
  parent interrupt unanswered until the 30 s control timeout (`-32603`).
- Queued messages are Codex's native durable queue (`src/gateway/queue.rs`),
  the only queue and scheduler. Codex starts the oldest message as its own turn
  after the running one completes or fails and pauses the queue after an
  interrupt.
  - `thread/queue/add` (`{threadId, input, clientUserMessageId}`),
    `thread/queue/start` (`{threadId, queuedSubmissionId?}`) and
    `thread/queue/delete` (`{threadId, queuedSubmissionId}`) are governed
    native mutations: conversation admission, identity, the client-owner takeover
    check, the compaction guard (`-32009`) and the per-thread native-mutation
    marker apply, so a second change is refused while one is unverified.
    `thread/queue/list` passes through; update and reorder are not served.
  - Any `thread/queue/*` on a `claude_` thread is refused before routing with
    `-32601`, `data.kind` `queueUnsupported` and `retryable: false`.
  - The gateway leases the messages it queues: `queued_submissions` in the turn
    state, written before Codex sees the add, at most 100 per thread and 256
    threads (`-32001`, `capacity`). A native refusal removes the entry. An
    uncertain add keeps it and is never resent, because native add is not
    idempotent by client id. An add, start or delete whose outcome is
    unverified fails with `data.kind` `queueChangeUncertain` (`threadId`); the
    client rereads the queue instead of retrying.
  - The lease only attributes. A queue-started turn takes the owner, preview
    and cwd of the leased message whose `clientUserMessageId` its user
    message's `clientId` carries. While a thread holds a lease or a pending
    `turn/start` with a `clientUserMessageId`, `turn/started` never binds a
    pending start by position, and such a pending start binds only to a turn
    carrying its client id, so a queued turn never takes another client's
    `turn/start` context. A turn awaiting attribution records that in its
    persisted turn context and is matched from its user-message item or the
    observer's resume snapshot; a matched lease's owner replaces the provisional
    owner a `thread/queue/start` from another client set. Writers on other
    connections, such as launcher parent callbacks, are not leased.
  - A disconnect observer whose turn ends with an unheld lease stays subscribed
    up to 30 s for the next `turn/started`, adopts it and reports it like a
    gateway-started turn (journal, APNs, Live Activity). If nothing starts it
    lists the native queue: listed messages hold the lease, none clears it.
    Settlement keeps every lease of a thread while an add on it is in flight,
    including before its native-mutation marker exists. A reconnecting observer
    finishes its turn when the resume snapshot shows it ended or shows another
    turn running, and adopts that running turn. An interrupt other than a
    planned restart holds the queue, a duplicate completion never
    holds it again, and a `turn/started` or `thread/queue/start` releases it.
    After a restart the persisted scan starts the same observer for every
    unheld lease, which adopts the running turn from `thread/resume`.
  - `thread/queue/changed` (`{threadId}`) reaches every subscribed connection
    and is stored with `rcSequence`; clients reread `thread/queue/list` after
    it, on reconnect and after relaunch.
- `daemon/activeTurns` returns the union of gateway-observed turns and the
  app-server's passive exact-turn inventory (`threadId`, `turnId`, timestamps,
  prompt preview, cwd, source, and for a gateway-owned turn `startedAtSequence`,
  the `rcSequence` of its stored `turn/started`), plus `coverage {codex,
  claude}`. Only a covered provider's empty list proves that none of its turns
  runs. Each control connection resolves every loaded Codex thread; a thread
  without turn history counts as idle only on its live idle status. A thread it
  cannot resolve stays unresolved, keeping `coverage.codex` false, and the pass
  retries from 1 s doubling to 60 s until every thread resolves.
  `appServerInventoryAvailable` mirrors `coverage.codex` until its
  removal. It is telemetry and never owns lifecycle or restart decisions.
- Clients branch on `error.data.kind`, never on a message: `turnNotRunning`
  (`threadId`, `turnId`), `historyCursorInvalid`, `historyPageTooLarge`
  (`actualBytes`, `limitBytes`), `conversationBusy` (`retryAfterMs`; a
  compaction or other exclusive command holds the conversation), `queueUnsupported`,
  `queueChangeUncertain` (`threadId`), `providerUnresponsive` and
  `inputDeliveryUncertain` (both `-32003`; Claude stopped reading its stdin or
  answering controls, see *One warm runtime per active thread*),
  `providerUnavailable` (`-32003`, `provider`, `reason`; Codex is not ready or
  this connection has no Codex upstream; retryable except while restart
  recovery waits for sign-in) and
  `requestTimedOut` (`-32003`, `limitMs`, retryable), each with
  `retryable`; the JSON-RPC code is unchanged. Upstream Codex texts are matched only where the response is
  correlated to its request (`src/rpc/upstream_errors.rs`), pinned by a test to
  the fork commit in `docs/codex/compatibility.json`.
- `host/info` returns the gateway process's `homeDirectory`, physical `hostname`,
  `automationsAuthority` and `speechAvailable` capabilities. These are the
  authoritative inputs for client feature availability and physical-host routing.
  Missing capabilities stay unknown/unavailable, never guessed from a display
  name. It is the only way a client learns the home directory; `command/exec` serves
  user-typed shell commands alone.
- One owner (`src/gateway/activity.rs`) computes that snapshot and gives each
  distinct content a `revision`. It is seeded from wall-clock milliseconds at the
  gateway process's first publish and increases by one for each distinct content,
  so it is not a bare counter from 1. The payload's `epoch` is the notification history's epoch, so a
  client compares revisions only within one epoch. Every change is broadcast once as
  `daemon/activeTurns/changed` with the same payload the read returns. Committed
  turn state and app-server inventory changes wake it at once; a tick catches
  external activity and any other path. Discovery, publication and coverage
  run for the gateway's lifetime and never depend on which or whether clients
  are connected: a one-shot reader such as `rc-gateway rpc` or the automations
  service gets the same truthful snapshot as a long-lived app. Client presence
  may gate delivery, never discovery. Work moved off a request path keeps its
  freshness guarantee in the loop that now owns it. Reads assemble gateway and
  app-server turns from current short critical sections, including a read after a Stop acknowledgement. They never
  wait for external discovery, ancestry or restart-journal I/O. The publisher
  owns a separate bounded discovery task outside its publication lock, cancelled
  with the publisher. It refreshes every 2 s while working and every 8 s idle;
  changes can wake it, at most once per 2 s. External discovery has a 5 s bound,
  ancestry 2 s and restart coverage 1 s. Until verified, or after 30 s without
  refresh, optional coverage stays unknown. Gateway turn changes publish at once
  even when discovery is blocked. The push and read keep one revision owner.
  `agentOwnersCoverage` is `complete` only after a successful ownership observation
  no older than 30 s that covers all current active/working threads, and
  `unavailable` at startup, after failure/timeout, expiry or an unobserved thread.
  `agentOwners` remains a positive owner map; absence proves roothood only while
  coverage is complete. A failed refresh can retain previously known owners
  without refreshing their timestamp. A completed partial observation replaces
  and timestamps the positive map while keeping coverage unavailable, so an
  unresolved thread never hides other verified owner links.
  The push is not stored in replay history, so a client reads once after
  connecting. A client whose outbound queue rejects a broadcast is
  disconnected, so it reconnects and reads again instead of silently missing
  later pushes.
- Its `externalActivity` is a separate inventory of native Claude and
  standalone Codex sessions (`src/activity/external/`: live ownership plus
  transcript boundaries). Those entries never enter the active-turn or recovery
  registry and never get synthetic controllable turn ids. Unavailable coverage
  stays unknown. Codex's `lsof` exit status 1 with empty stdout and stderr means
  no matching processes; partial output, diagnostics and other failures remain
  unavailable. Activity reads use the publisher's latest refreshed observation;
  admission and explicit takeover still verify live ownership independently.
  The `claude agents --json` listing is expensive (a Node CLI
  launch), so it reruns only when `~/.claude/sessions` changes, a listed process
  exits or 30 s pass; transcript states still refresh on every snapshot.
  A `waiting` Claude entry carries `waitingSince`, the Unix-seconds timestamp
  of its transcript's last turn boundary, so clients can tell a fresh request
  from a background job parked for weeks. Metadata records such as a rename's
  `custom-title` do not move it. It is absent when the transcript or that
  timestamp is unreadable, and other states carry none.
- Each entry with a live process carries `owner`: `gateway` for a Claude
  runtime in this gateway's process registry, `client` for any other process
  (an AgenTTY or terminal TUI, or a Codex TUI with an embedded server). A
  session held by a client belongs to it whatever its state, idle included:
  admission refuses `turn/start`, `thread/resume` and `claude/message` on that
  thread with `-32009`, and with `-32003` while that provider's inventory is
  unavailable, so no send, voice start, agent message or automation resumes it
  into a second process (`src/gateway/takeover.rs`).
- `conversation/takeOver` (`{threadId}`) is the explicit way to move such a
  session here. It rereads the inventory, stops every client process holding
  the thread (TERM, then KILL after 5 s each, to the process group when the
  agent leads its own; a recycled pid is never signalled), journals
  `runtime take_over`, and republishes activity. The next send resumes the
  session in the gateway. A Codex TUI that attaches to the shared app-server
  socket is not a client owner and needs no takeover.
- `conversation/agents/list` returns known native headers when execution or
  optional discovery is incomplete; unfinished execution state stays unknown.
  The host-shared Agents owner coalesces exact normalized inventory selections
  in bounded tasks independent of waiting callers. Invalidation separates new
  reads from older work. Inventory, alert classification and mutations have
  separate process and caller budgets. No inventory-cache lock covers I/O.
  [`docs/conversation-agents.md`](../docs/conversation-agents.md) owns their
  deadlines, limits, cache policy and coverage contract.
- Async question state belongs to the durable host projection in
  `src/questions/`, not to active-turn contexts. `conversation/questions/read`,
  `conversation/question/dismiss` and `conversation/questions/changed` expose
  revisioned per-slot state with explicit coverage
  (`docs/async-questions.md`).
- Conversation marks (`src/conversation_marks.rs`) are the host's pins, read
  state, purposes, settlements and done suggestions, in
  `conversation-marks.v3.json` beside the turn state (schema version 3, at most 8 MiB, unknown fields rejected). One
  owner serializes every read-modify-write. `conversation/marks/read` returns
  `{schemaVersion, revision, readBaseline, threads, supportsRetiredScopeRead: true}`, creating the document
  with a read baseline of now; `conversation/marks/update` (`{changes}`, at
  most 500 of `markRead`, `markUnread`, `markAllRead`, `markRetiredScopeRead`, `pin`, `unpin`,
  `setPurpose`, `settle`, `unsettle`) validates every change first
  (`-32602`), then returns `{delta}`, `null` when nothing changed, and
  broadcasts the same delta, which also carries `schemaVersion`, as
  `conversation/marks/changed`. Only a full read carries the retirement support
  flag; clients retain imported pending edits until that read proves adoption
  completed. An older gateway omits it, and a delta never proves coverage.
  `markAllRead` carries `through`, the time the
  user asked, and moves the baseline to it (never past the gateway's clock), so
  a change sent after reconnecting cannot cover turns that finished meanwhile.
  `markRetiredScopeRead` carries `{scopeId, through}`: `default` names the
  immutable pre-Codex-adoption host scope; a canonical retired UUID names its
  source scope. Adoption records complete Codex/Claude and explicit mark-only
  IDs in its receipt before any native import. This op applies per-thread read
  semantics through at most now without moving `readBaseline`. Unknown or
  unavailable evidence fails the whole update without writing or acknowledging
  other changes. Never reconstruct an old scope from current history, and keep
  scope evidence after deleting cold profiles while clients can hold old edits.
  Thread ids are nonempty, trimmed and at most 512 bytes; pin names at most 256.
  Clients apply a delta entry only when its revision is not older than theirs;
  an empty entry is a tombstone that clears the thread and keeps its revision,
  so a late older delta cannot restore it. A `thread/deleted` notification
  clears the thread's marks.
- Settlement: a thread's `settlement` is `{state: "settled" | "active",
  through}`. `settle` (`{threadId, through}`) records `settled`, clears the
  pin and the unread mark and raises `seenThrough` to `through` (the read
  baseline still prunes it); `unsettle` records `active`; every other change
  leaves it. Unsettle also clears `doneThrough`. Clients derive whether a row is settled from it, its activity and
  the automatic threshold (`docs/system-architecture.md`). There is no archive
  mark: the gateway records nothing for Codex `thread/archived` and
  `thread/unarchived`, which stay plain passthrough like `thread/archive` and
  `thread/unarchive`; Claude threads cannot be archived. Claude `thread/list`
  rejects `archived: true` with `-32602`, and its headers carry `recencyAt`,
  the newest root user prompt.
- Done suggestions are gateway-only `doneThrough` marks, never client update ops.
  The turn-review owner writes the judged completion timestamp at probability
  >= 0.90 and clears it below that threshold, only on change. Its transaction
  excludes pins and purposes and rejects a positive verdict when settlement is
  `active(through)` at or after the judged completion. Read marks and unrelated
  account activity do not discard it. The app requires no purpose or
  pin and `latestActivityAt <= doneThrough`; new activity invalidates it without
  a write. Codex uses the native turn completion time; Claude uses the transcript
  header completion time, matching the drawer's sources. Suggestions never
  change settlement, read state or pins.
- Marks migration (`src/conversation_marks/migration.rs`): every marks context,
  the host and each account state directory, imports schema 2
  `conversation-marks.v2.json` on the first load without a v3 file, preserving
  marks and pending native unarchives. With no v2 file it imports schema 1
  `conversation-marks.json` through the existing settlement conversion. Neither
  older file is written, so a rollback still reads it. An `archivedAt` without a purpose
  becomes `settled` through it; one with a purpose is dropped, and so is one on
  a Codex thread that `conversation-handoffs.json` records as a handoff
  snapshot or abandoned continuation, which stays natively archived. Purpose-free
  archived Codex threads (provider by the `claude_` routing) enter the
  document's `pendingNativeUnarchive`, omitted when empty. Each time the Codex
  control connection becomes ready, a control-owned task calls
  `thread/unarchive` for them one at a time. Success or Codex's `no archived
  rollout found` or `invalid session id` reply removes an id; any other failure
  keeps it for the next start and is logged. The drain never delays startup.
- Directory favorites (`src/directory_favorites.rs`) are the host's favorite
  folders, in `directory-favorites.json` beside the turn state (schema version
  1, unknown fields rejected). `storage::private_document` serializes every
  read-modify-write. `directory/favorites/read` returns `{revision, paths}`,
  newest first, and an absent file reads as revision 0 with no paths.
  `directory/favorites/update` (`{changes}`, 1 to 100 of `add` and `remove`,
  each with an absolute `path` of at most 1,024 bytes without control
  characters, else `-32602`) applies them in order: `add` puts a new path
  first, leaves a present one where it is and is skipped once the host has
  100 favorites. It returns the current `{revision, paths}` and, when the
  list changed, advances the revision and broadcasts the same document as
  `directory/favorites/changed`.
- User preferences (`src/user_preferences.rs`) are the settings every device
  of the user shares, in `user-preferences.json` beside the turn state (schema
  version 1, unknown fields rejected), served through
  `storage::private_document`.
  Entries are opaque `{value, updatedAt, device}` keyed by the app's setting
  name, so the gateway knows no setting. `preferences/read` returns
  `{entries}`; an absent file reads empty. `preferences/update` (`{entries}`, 1
  to 64, each key at most 128 bytes and device at most 64 bytes without control
  characters, an `updatedAt` from 1 to 2^53 − 1 and a JSON value of at most
  8 KiB, else `-32602`) keeps per key the entry with the greater
  `(updatedAt, device)`. A `null` value is a reset and is kept like any other.
  New keys past 64 are skipped with a warning. It returns the current `{entries}` and, when an entry changed,
  broadcasts them as `preferences/changed`.
- `conversation/projects/resolve` (`{directories}`, at most 500) returns
  `{projects: [{cwd, kind, key, name, root}]}` (`src/conversation_projects.rs`).
  `kind` is `remote` when the repository has an `origin` remote, keyed by the
  remote normalized to `host/path` without scheme, credentials, port or
  `.git`; `repository` for a checkout without one, keyed by its main worktree
  root; otherwise `directory`. Git runs four at a time with a 5 s limit, and
  results are cached per directory (2,048 entries, 10 minutes). A directory
  whose Git call times out or cannot run is left out of the reply and not
  cached, so the client keeps it unresolved and asks again later.
- History is the app-server v2 `thread/items/list` and `thread/turns/list` on
  both providers; there is no gateway-specific history read. Codex answers
  them itself. For `claude_` threads the gateway serves the same wire shape,
  defaults (items `asc`, turns `desc` with `summary`, 25 per page clamped to
  1–100), opaque cursors (`nextCursor` continues past the last entry,
  `backwardsCursor` reverses from the first one inclusive) and errors (`-32600`
  for malformed params, a cursor that does not parse and a cursor whose anchor
  is gone). Item ids, `startedAtOrdinal` and `startedAtMs` are the ones
  the live translator emitted and the index recorded. A turn the executor is
  running is `inProgress` with no `completedAt`; an indexed turn left
  `inProgress` by a dead process reads as `interrupted`, as Codex normalizes it.
  The executor records a turn's completion in the index while it still holds
  the runtime lock that reports the turn as active, so a page never sees a
  finished turn in between. Claude `thread/read` with `includeTurns` returns
  every turn from the same projection, oldest first with `full` items. Past
  the 24 MiB history budget it fails with a typed `capacity` error (`resource`
  `thread/read turn bytes`) instead of a partial or empty list; page such a
  history with `thread/turns/list`.
- Codex `thread/list` accepts the gateway-only Boolean `boundedPreview`
  (default false). Only native history opts in. The translation layer cuts plain
  outgoing previews longer than 2,048 extended grapheme clusters at a grapheme
  boundary, without an ellipsis. Previews containing any RemoteCoder prompt
  marker (`remotecoder_`) or the attached-files header line pass through whole,
  preserving paste, literal and attachment formats. Reuse the marker constants
  owned by `prompt_summary`; do not add a prompt parser to the list path.
  The parameter is never forwarded to Codex. Provider headers, caches,
  persisted metadata and full reads keep their current previews. Default
  callers preserve their existing response bytes. Native preparation stays in
  `UserMessageText`. There is no truncation flag because the native caller does
  not need that state; length is not a signal.
- `claude/thread/list` returns a page of headers (default 30, clamped to
  1–500) and `nextCursor` whenever more matches remain. Its opaque cursor
  continues strictly after the captured `updatedAt` descending / exact id
  ascending key, even if the anchor moves or is deleted. Optional `searchTerm`
  is at most 4,096 bytes; whitespace terms match the effective title (custom
  name or preview) and cwd case-insensitively. It is metadata search, not full
  transcript search. Cursors are at most 2,048 bytes, tied to the normalized
  query, and malformed, unsupported or mismatched cursors return typed
  `historyCursorInvalid`; they never restart at page one silently. Paging
  reads live state rather than freezing a snapshot, so clients merge by exact
  id and refresh newer coverage separately. Responses share the 24 MiB history
  page budget.
- `src/providers/claude/projection.rs` owns those pages. It scans the session file once
  into a projection of byte spans plus index identity and materializes only the
  page's records with positioned reads, so a page never re-parses the session.
  One process-wide LRU holds projections up to 32 MiB of estimated size, keyed
  by the session file's identity, size, mtime and ctime, the index revision
  and the active turn id; any change rebuilds. A projection over the budget is
  served once and not cached. Concurrent reads of one session share one build.
  Each page journals `claude history page` with entry count, bytes, cache
  outcome and read and send time.
- Token usage is the `thread/tokenUsage/updated` notification. Codex's
  app-server replays it to the resuming connection right after a
  `thread/resume` response that includes turns or resumes a paginated-history
  thread; an `excludeTurns` resume of a legacy thread replays nothing. For
  Claude the gateway sends the same replay right after every successful
  `thread/resume` response. It is computed before that response, so a cold
  projection read delays the response rather than letting the replay land after
  the next turn's live usage. It carries the newest assistant record's
  `message.usage` as both `total` and `last`, attributed to the turn that
  contains that request, with the auto-compact ceiling from Claude settings as
  the window (the session file never records `result.modelUsage`). A session
  with no usage yet sends nothing, and a failed replay is logged, never
  reported as zero.

## Speech relay (`src/voice/speech/`)

- `/speech/<provider>/<upstream path>` relays SpeechKit's HTTP and WebSocket
  protocols for `openai`, `elevenlabs`, `gemini`, `assemblyai` and `azure`, so
  no speech-provider key is ever baked into or sent to the app.
- The caller's gateway bearer authenticates. The gateway forwards to llm-router's
  `/vendors/<vendor>/<path>` with the host's router key in the provider's own
  auth header; the router owns provider keys. `README.md` (*Speech providers*)
  owns the vendor mapping.
- A fixed operation allowlist (`src/voice/speech/routes.rs`) admits only the endpoints SpeechKit
  uses. `RC_CODEX_GATEWAY_SPEECH_CLIENTS` is `all` when unset, or a
  comma-separated list of installation IDs; the operator is always allowed, and
  an explicitly empty value fails config load. It controls usage and spend per
  installation. It is not a key-protection boundary, because an installation
  credential already grants `/ws` and `command/exec`. Revocation and drain end
  active relays.
- Every rejection the relay itself generates carries a provider-independent
  marker. Over HTTP it is an `X-Speech-Relay-Rejection: <kind>` header,
  including on a refused WebSocket upgrade, because admission and the upstream
  connect finish before the client upgrade. After an upgrade it is a
  `4000 + status` close with reason `speech-relay-rejection:<kind>`. Provider
  responses and close frames pass through verbatim, and the response-header
  allowlist keeps providers from spoofing the marker.
- A WebSocket relay pumps both directions under one cancellation token and pings
  the client every 15 s, ending as `clientClosed` after 30 s without a pong. An
  HTTP relay ends as `clientStalled` after 30 s without request-body bytes,
  because a client lost with its tunnel never closes and would hold its slot
  forever.
- Limits are constants, not configuration: 4 concurrent relays, 64 MiB request
  bodies, 32 MiB WebSocket messages, a 10 s connect timeout, the 30 s
  request-body idle timeout and no wall-clock cap.

## File uploads (`src/files/upload.rs`)

- An upload is a resumable session keyed by the client's attachment UUID:
  `~/.remote-coder/uploads/<id>/` holds its `.session` record beside a
  `.partial` file, renamed to `<sanitized name>` once the bytes are complete
  and verified. `PUT /uploads/<id>?name=…` appends the remaining bytes at
  `X-RemoteCoder-Upload-Offset`, declaring `X-RemoteCoder-Upload-Length` and
  `X-RemoteCoder-SHA256` on every append; `201` returns the absolute canonical
  path once length and digest hold, `409` rejects an append at the wrong
  offset, and a body that ends early keeps what arrived for the next append.
  `GET` returns `{offset}`, plus `file` once stored (an unknown id is offset
  0), and `DELETE` discards an unfinished upload. Older apps' single-shot
  `POST /uploads?name=` remains as a thin adapter over the same store (see
  `docs/compatibility-register.md`).
- The partial file is the source of truth. Received chunks are written,
  hashed and counted in batches of blocking work that owns the upload's writer
  lock, as do rehash and publish, so a dropped request never overlaps the next
  append. A newer append supersedes an older writer of the same id.
  On startup, sessions reload from disk, and a full-length partial left by a
  crash is finalized by its next empty append.
- The handoff to the agent is the path alone: the app appends a plain-text
  attached-files block with the absolute paths after the typed message. Codex
  `turn/start` has no document input and Claude's stream-json accepts only image
  and PDF blocks, but both providers can read any host file from a path.
- Limits are constants: 32 GiB per file, a 64 GiB store that evicts uploads
  left unfinished and untouched for an hour, then the oldest stored ones, only
  when that makes room, 2 GiB volume headroom, 32
  unfinished and 8 concurrently written uploads, a 30 s body idle timeout,
  30-day retention for stored files and 7 days for unfinished ones.

## Push notifications

- `Gateway::check_user_alert_ownership` is the single eligibility gate for
  completion/question queue deliveries, `notify_user`, and restart-failure
  alerts. It reuses the Agents owner's `is_agent_thread`
  projection with its two-second bound. Verified children are silent for every
  outcome and question. Missing identity, unavailable ancestry and timeouts
  suppress delivery with fixed journal reasons, never a guessed root or raw
  execution error. The job owner's exact Agent origin is authoritative for
  external workers. Native provider ancestry and typed Claude creation records
  supply other roots; scoped imported uncertainty remains unknown. A delegated
  Claude creation is `SessionOrigin::Job`, never a root-producing bare marker.
  Reads call this in-process owner, not an agent-work CLI or periodic ancestry
  preflight. Display caches, parent routability and message text never establish
  root eligibility. Each lookup journals coverage and duration. This gate changes
  only user alerts; completion evidence and parent callbacks remain intact.
  Native Claude children share the root runtime's MCP
  identity, so a runtime-owned `PreToolUse` hook supplies their provider-generated
  `agent_id` before MCP dispatch. Only `mcp__remotecoder__notify_user` matches.
  The local gateway helper exits 2 for child or unverified callers. Missing or
  failed helpers leave dispatch to reject and journal the missing proof. Root
  calls emit no permission decision: the
  authenticated hook issues an opaque single-use permit through `updatedInput`,
  bound to that runtime and complete JSON arguments. `McpTokens` retains at most
  16 permits per runtime and 256 total for 30 seconds (oldest evicted), removes
  them on retirement, and consumes each before
  Claude `notify_user` dispatch. A missing hook, outer CLI hook timeout, replay
  or changed copy therefore cannot authorize an alert. Missing root issuance
  continues without a proof so dispatch journals the rejection. Proofs are
  removed before app tool-item projection and journal recording. Installed
  Claude 2.1.280 retains updated input in its canonical transcript, including
  after failed MCP transport; that provider history is never rewritten. The
  single-use, runtime binding and 30-second expiry bound this exposure. This
  is a cooperative provider attribution contract, not a security boundary
  against a deliberate same-uid child using Bash to impersonate the hook.
  A child's 300 ms best-effort suppression callback cannot authorize a
  denied call. The additive settings file is private, token-free and removed
  with the runtime's MCP config; it does not replace host hooks or change other
  tools. Claude 2.1.280 child/root behavior and hook merging have a live isolated
  fake-broker acceptance probe.
  The root proof request has a two-second budget; child suppression remains
  local with a 300 ms best-effort journal callback. The additive
  `/health.claude.notificationHook` field reports a bounded helper self-probe,
  including startup failures, without changing top-level health or restart
  authority. Runtime tokens resolve only through the host gateway's token owner;
  retired or unknown tokens receive 401. Helper preflight verifies executable/exit behavior only;
  `checkedAtUnixSeconds` and the separately reported CLI version make its scope
  explicit. It does not certify the provider's hook semantics.
  On Claude, Codex or launcher upgrades, compare the registry's exact MCP matcher,
  the pinned native `SessionSource` enum (including its custom/subAgent shapes)
  and frozen schema-v2 codes, rerun the installed-CLI root/child/timeout/disabled-hook
  probes on both Macs, and verify exact-subject coverage and lookup latency with
  the matching configs checkout. Never convert unsupported coverage to root.
- Task-completion alerts go through the configured push broker on
  `turn/completed`, best effort. A connected originating client, or its
  temporary disconnect observer, supplies the authoritative completion.
- When the control connection's `thread/status/changed` reports a thread
  inactive while the gateway still tracks one of its turns (for example a
  Desktop-started turn the phone stopped observing), the gateway reads that
  exact turn with `thread/turns/list` and finishes it on the same path. It never
  finishes an in-progress or restart-recovering turn, or any turn while draining
  for a restart, because the replacement recovers it. `sent_turn_keys` stops a
  late client `turn/completed` from pushing twice.
- The alert set records an attempt before the best-effort send, so a full,
  closed or missing send queue leaves an `alertDropped` question journal line
  (thread, item, reason) instead of a silent loss.
- Each async question item sends one "Codex has a question" alert with collapse
  id `question:<thread>:<item>`, payload `questionItemID` and no `outcome`.
  Otherwise the payload matches a completion alert, so routing and foreground
  suppression are shared. Both kinds are journalled as `question` lines. A
  collapse id over APNs' 64-byte limit, such as a long Claude thread
  id, is sent as `sha256:<base64url digest>` of the same key, so it still
  collapses consistently. Tapping the alert opens the conversation and reveals the
  card.
- `devices/` owns every push destination. The app registers each installation
  once per host with `devices/register` (`deviceId`, `bundleId`, `apnsEnvironment`,
  `appHostId` and a `tokens` set of `alert`, `liveActivity`, `voip` and
  `location`; the location token carries its navigation start inputs as
  `{token, navigation}`) and removes it with `devices/unregister`. A
  registration replaces that device's whole token set, and a token belongs to
  the device that registered it last. The registry holds at most 32 devices
  (`-32001`; nothing is evicted), lives in `~/.remote-coder/devices.json`
  through `private_state::transaction`, and an unreadable or unknown-version
  file fails visibly and is never overwritten. Tokens never appear in logs or
  journal lines, only their fingerprints. `devices/register` checks `bundleId`
  against `RC_APNS_BUNDLE_ID` and answers `{hostId}`.
- Alerts go to every device with an alert token, each stamped with that
  device's own `appHostId`; Live Activity updates go to every device with an
  activity token; VoIP and location pushes go to the most recently registered
  device holding that token. Sends run at most four at a time with no registry
  lock held. A user alert succeeds when any device accepted it. Completion
  journal records include `hostBinding` (`bound` for a registered device)
  without registration contents or token values.
- While `devices.json` has never been written, the pre-registry sources still
  serve: `apns_device_token`, `active_tasks_live_activity_token`,
  `apns_environment` and `apns_notification_identity.json` beside them,
  `agent-calls.json`'s `device` and `navigation-device.json`. They are read,
  never imported or exported, and stop applying with the first registration
  (even after every device is removed). `calls/device/*` and
  `navigation/device/register` still write those files until the fallback is
  removed.
- `PushService` (`src/push/mod.rs`) sends alerts, agent notifications, Live
  Activity, location and VoIP pushes through one `deliver` path over
  `PushBroker` (`src/push/broker.rs`). Its `DeliveryOutcome` separates an
  unavailable broker, a missing destination, a rejection and an uncertain
  delivery (no answer, or an unreadable success), so a caller can tell a push
  that may have gone out from one that did not.
- `src/gateway/live_activity.rs` authors the aggregate Live Activity, so it
  stays current while the app is suspended. Its content is the count of running
  root conversations and up to three attention rows: root conversations with
  an unread finished turn and no running turn. A pending async question never
  adds a row. It marks an unread row as a question only when its watch is
  ready and it was asked after the thread was last read
  (`docs/async-questions.md`, *Attention*), so lost question coverage drops
  only the marker. Settled conversations have no rows, because settling marks
  them read. The attention count counts every unread row.
  Pending or unreadable Claude restart recovery holds publication; resumed
  starts must reach the turn ledger before coverage returns.
  Superseded async projections are discarded at projection, publication and
  delivery. Supersession during persistence or delivery leaves that scope
  unavailable until a current report replaces it. Rows are ordered newest
  completion first; a title is the pin name, then the native name, then the
  preview. Delegated agent threads fold into their proven root. Unavailable
  ancestry marks the shared projection unavailable and holds publication and
  End, retrying every three seconds until coverage returns. Startup, turn
  events, marks changes, question changes and device registrations refresh
  it, coalesced over 250 ms.
- A finished turn is recorded on `turn/completed`, except planned
  interruptions and compaction-only turns, and dropped when its thread starts
  a turn with another id or is deleted. At most 32 are kept, in
  `live-activity-finished-turns.json` beside the turn state; an unreadable file
  remains untouched and makes the Live Activity projection unavailable until
  the source is repaired and reloaded. Other turn-state commits do not replace it. It is unread when
  marked unread, or when the thread has no purpose, neither the read baseline
  nor `seenThrough` reaches its completion, and `seenThrough` does not pass its
  start. `seenThrough` only holds completion and activity times, so the start
  comparison absorbs Claude's transcript-clock skew.
- `PushService` publishes the host-default context's content as one per-host
  activity, persisted in `live-activity.json` so a restart keeps its rows.
  It publishes the same content through `daemon/liveActivity` and
  `daemon/liveActivity/changed`, with a process epoch and monotonic revision;
  the app uses it as the initial content when requesting an activity. A null
  response or event makes the app projection unavailable and blocks new starts.
  Startup retains only the default scope and waits for fresh authoritative
  projection before republishing saved content. Unavailable durable state or
  pending restoration cannot certify an empty host. It sends current content,
  or End once the host is empty, to each activity token that has not yet accepted
  it, so a token registered late still receives the latest state. It
  sends at APNs priority 10, with a five-minute stale date on updates.
  Relevance is 100 for attention, 25 for running-only work and 0 for empty
  content. Initial app content always uses
  that score. APNs includes `relevance_score` only after the broker's `/healthz`
  confirms `capabilities.live_activity_relevance_score`; an older or unavailable
  broker keeps the original request shape.
- Broker configuration: `RC_PUSH_BROKER_URL` (default
  `http://127.0.0.1:5012`), `RC_PUSH_BROKER_TOKEN` (required) and
  `RC_PUSH_BROKER_ENV` (`production` or `development`, derived from the bundle
  id when unset; it now only sets the environment of the pre-registry sources).
- A token that APNs rejects as permanently invalid is removed only if it is
  still the registered one, so a token rotated meanwhile survives. A
  host with no broker sets `RC_CODEX_GATEWAY_PUSH_BROKER_ENABLED=false`, which
  overrides inherited shell secrets.

## Codex runtime and Desktop

- `docs/codex/compatibility.json` records the exact matched Codex version with
  commit-scoped metadata. After building a matched package, run
  `just codex-runtime-approve <package>` instead of hand-editing the duplicated
  version, source and hash pins; `just gateway-check` fails fast on drift.
- Never copy a bare `codex` executable. Build the canonical package with the
  fork's `scripts/build_codex_package.py` and install it through
  `host-daemon-rs/scripts/install-codex-runtime.zsh <package-directory>`. The
  installer validates both matched binaries and their reviewed source commit,
  and keeps the custom runtime's upstream updater disabled; the pinned runtime
  changes only through a reviewed package install. It suppresses every external
  ingress during cutover, starts the replacement fenced and relay-disabled,
  durably recovers pending work, then enables the relay. It leaves a mode-0600
  typed plist with fixed rollback paths for the gateway/Desktop health gate to
  commit.
- The package follows Codex's standalone layout:

  ```text
  ~/.codex/packages/standalone/
  ├── releases/<version>-aarch64-apple-darwin/
  └── current -> releases/<version>-aarch64-apple-darwin
  ```

  `current/codex` is the daemon-managed executable, and the package's
  `bin/codex-code-mode-host` must match it. The builder derives the manifest
  source commit from a clean Git checkout. Activation is atomic and requires
  that commit, both manifest digests and the actual binaries to match the
  pinned approved artifact hashes; it then validates both executables, the CLI
  version, the official daemon lifecycle response, the daemon's managed version
  and its live app-server version. A version change uses the validated source package for capture and the
  approved target for activation and recovery; the persisted generation binds
  both identities. Recovery-only startup may use that exact bound package,
  while ordinary gateway startup stays pinned. Before deployment, prove
  source → candidate → source stored-history compatibility in an isolated home.
- For a paired deployment, do not run the synchronous runtime command from a
  turn it will suspend. `just shared-codex-install <package-directory>
  <gateway-binary>` submits a one-shot, launchd-owned stack installer
  (`KeepAlive=false`) that runs the runtime and gateway installers in order and
  outlives the submitting turn until both health gates commit;
  `just shared-codex-install-status` reads it. Before closing ordinary ingress
  it verifies the candidate recovery gateway and env file whenever exact
  recovery is in scope, and a direct install without that
  owner fails before stopping service.
- Package installation captures the host-default Codex task tree and persists
  exact recovery before changing the shared package. A pending typed rollback
  transaction remains until the gateway installer proves the new gateway
  healthy. A failed health gate restores the previous gateway and runtime
  together while ingress stays suppressed, then recovers recorded default
  work through the candidate recovery owner. Retired-profile adoption has the
  forward-only commit boundary described above; binary rollback must retain
  adopted state after that commit.
- A fenced cutover is recovered through the candidate gateway binary named in
  the deployment receipt with the gateway env file, not the installed gateway's
  `just codex-runtime-rollback` recipe. Ingress stays fenced while default
  recovery is unfinished; the candidate owner can retry
  `--env-file ~/.remote-coder/codex-gateway.env runtime reconcile` against the
  same package. Keep that binary until the transaction completes.
- The official ChatGPT app stays byte-for-byte untouched (never patched or
  re-signed). It receives the managed socket as
  `CODEX_APP_SERVER_WS_URL=ws+unix://localhost/<absolute-socket>:/rpc` in the
  Aqua launchd session and on the exact Launch Services request, ahead of
  Desktop's private CLI/plugin path and per-process app-tool overrides. The
  `localhost` authority keeps Desktop from routing a hostless Unix URL through
  its remote-host SOCKS proxy; the socket stays the absolute URL pathname. The
  Desktop helper LaunchAgent (`com.remote-coder.chatgpt-shared-codex`, a
  periodic `Standard` job) runs the gateway binary itself as
  `runtime desktop launch`: it waits for the exact managed daemon, closes a
  prematurely started private ChatGPT and reopens ChatGPT once with that URL.
  An operator can disable automatic Desktop management through private host
  profiles; startup still publishes the environment for manual launches.
  That environment includes `CODEX_SPARKLE_ENABLED=false`, which removes
  Desktop's Sparkle updater: the managed `in_app_updates = false` requirement
  fails open once Desktop has waited five minutes without reading it from an
  app-server, and an update replaces the bundled Codex paired with the shared
  runtime. A running Desktop without it is an environment mismatch. Rollback
  and uninstall leave it set, so neither they nor an isolated probe re-arm the
  updater.
  Verify the managed daemon and environment programmatically. The daemon's
  `processStartTime` record keeps upstream's `ps -o lstart=` encoding, so a
  bundled lifecycle check does not delete a live record as stale.
- External Codex agents get their own connection too: the operator agent
  launcher uses `codex app-server proxy --sock ...` instead of a private
  app-server. Parent callbacks open a fresh control connection and use
  `turn/steer` for an active parent or `thread/queue/add` for an idle one.
- Upstream references:
  [app-server](https://github.com/openai/codex/tree/main/codex-rs/app-server),
  [app-server daemon](https://github.com/openai/codex/tree/main/codex-rs/app-server-daemon).

## Install, restart and recovery

- The cluster upgrade makes the delegated-job store one-way once parent tags,
  cluster fields or new execution states are written. Gateways at `aa96ebb` and
  earlier reject those records and ignore remote intents, fences and membership.
  Recover by rolling forward to a fixed next patch. Never restore a pre-upgrade
  snapshot that would discard accepted jobs. `docs/delegated-jobs.md` lists each
  store's compatibility boundary. Never-tagged records omit absent new fields.

- A planned daemon or runtime restart is one Rust-owned transaction in the
  gateway binary:
  1. Hold the host lease and fence new work.
  2. Capture and suspend every exact active root or child turn, leaf first.
  3. Persist queued steering and inter-agent mail.
  4. Start the replacement with a generation- and target-bound recovery grant.
  5. Let the persistent control connection recover each original turn id
     directly.

  Shell and launchd entries are thin callers that own no recovery state or
  rollback order. Runtime rollback uses the same transaction, and the nightly
  reboot ledger suppresses duplicate AgenTTY Codex recovery prompts.
- `runtime retry-failed --generation-id <id>` explicitly retries the failed tasks
  in that exact completed default generation. It verifies the bound package and
  each latest native turn, refusing changed IDs or an actual completion, captures
  current live work, and runs the same suspension and recovery transaction with
  a renewed bounded attempt budget. Run it through a detached owner because it
  suspends the submitting turn too. Journal edits and fresh replacement turns are
  never repair paths.
- `host-daemon-rs/scripts/install-launchagent.zsh`:
  - It never builds: it needs a prebuilt signed gateway app bundle (exit 2
    without one), verifies it, and runs the Rust `runtime install-gateway`
    transaction
    (`src/runtime/install/transaction.rs`). That backs up and atomically
    activates the versioned bundle and executable alias, the
    `launch-codex-gateway` cold-start launcher, the
    gateway plist and the Desktop helper plist under
    `~/localbin/remote-coder-gateway`, boots out the Desktop helper and the
    gateway, and waits for stable authenticated health, the Codex lifecycle
    and the scheduling and fd policies before it attaches Desktop. Its commit
    removes the legacy Desktop launcher script
    `launch-chatgpt-with-shared-codex`; the helper now runs the gateway binary.
  - It verifies authenticated health, commits or rolls back the paired Codex
    runtime, and starts ChatGPT last with its managed `ws+unix` URL.
  - The private `~/.remote-coder/host-profiles.json` owns per-host Desktop settings;
    loaded from operator state. `runtime desktop mode` reports it, and the
    installer and `shared-codex-status` follow that answer. On a listed host
    the gateway never opens ChatGPT, and the installer removes the Desktop
    helper and skips only the attachment gate; every gateway and runtime
    health gate still runs. It still publishes the managed socket
    in Aqua launchd for manual ChatGPT launches; the operator owns CA policy.
    Runtime transactions stop a running ChatGPT before a cutover.
  - It is the low-level detached worker, not an agent entry point. For a
    gateway-only cutover, use `just gateway-install` or
    `just gateway-install-prebuilt <gateway>`; both submit the launchd-owned
    installer and wait for its recorded job. A synchronous invocation is
    rejected while the managed app-server runs, because that process may belong
    to the turn the handoff must suspend.
  - Before replacing a running gateway, it runs the Rust
    `runtime prepare-handoff` transaction to fence, suspend and stop exact
    active turns without writing a reboot marker. The replacement recovers them
    before ingress opens, so the predecessor's SIGTERM path never suspends them
    a second time.
  - `platform/macos/scheduling.rs` owns gateway thread QoS, child scheduling
    and the Darwin-background guard. Keep elevation best-effort and agent
    commands at normal host priority; never use realtime. Follow the
    [scheduling contract](../docs/owned-operations.md#gateway-scheduling).
  - On maintainer-managed hosts it validates the `remote-coder-gateway` listener claim
    against the private service inventory before replacing the
    service. Port 8787 is RemoteCoder's; wildcard and loopback binds on the
    same port collide.
  - Healthy means RemoteCoder's authenticated JSON contract with a numeric
    `codexPid`. An unrelated service returning HTTP 200 is not evidence.
    App-server liveness is the Unix-socket WebSocket handshake, and RPC latency
    never marks it dead or triggers a restart.
- Clients learn of a planned restart from close code 4012 ("gateway
  restarting"), never from 1012 or 1013, which URLSession hides from the app.
  `Gateway::restart_in_progress` (draining, or an unfinished recovery journal
  without an error) picks 4012 for every connection a restart ends. Only
  draining refuses a new connection, with 4012, including a retired-ID
  WebSocket arriving while the gateway is stopping; a pending journal admits
  clients without Codex. The planned close of those connections once Codex is
  ready is also 4012; other ends stay 1013. The journal's `error` means failure only, so recovery
  progress belongs in the log, never in `error`.
- Every SIGTERM interrupts active work at once, and the replacement resumes it;
  nothing waits for a turn to finish. That covers a deploy, an installer
  handoff, `just gateway-restart <local|ssh alias>` and any other launchd stop.
  The host gateway (`src/gateway/lifecycle.rs`) rejects new work, closes the
  realtime transport, and then handles both providers
  concurrently:
  - **Claude:**
    - First, persist a 0600 `claude-restart-recovery.json` beside the turn state
      for every active turn and every idle runtime with live background tasks
      or a live scheduled-wake hold.
      Then end each process group with SIGTERM, and SIGKILL after 5 s
      (`ClaudeSupervisor::suspend`). Never send the CLI's `interrupt` here: it marks
      background agents stopped by the user, and no message can resume them
      afterwards.
    - Once the replacement's listener is up, it resumes each thread with
      `--resume` in the host-default profile, using the recorded cwd, model,
      effort and Fast.
    - The resume notice is a short hidden plain-text input whose uuid is the
      recovery id. It stays marked as non-user input but must explain itself:
      it says it is an automated RemoteCoder notice, names the restart cause,
      the interrupted turn, each
      paused agent to continue with SendMessage (telling it that if it was
      running a command, the planned stop killed it with exit 137 or 143, so it
      checks what the command already did and reruns it only if still needed)
      and the shells and monitors to rerun, asks the model to call
      `ScheduleWakeup` again for an ended `/loop`, lists the crons `--resume`
      restores, and says launcher agents keep running.
    - Stdin inputs the CLI has not yet taken (`--replay-user-messages`) die
      with the process, so the capture saves them in the item and the resume
      writes them after the notice. An input leaves that list when the CLI
      has taken it (the same evidence that closes a dispatched turn, below)
      or when its write fails. Before every dispatch the session JSONL is checked
      for the notice and each carried input by id, and only the missing ones
      are written, so a crash mid-recovery neither duplicates nor drops one. A
      failed write or a vanished process fails the attempt.
    - A notice still unread when the thread is captured again is not carried
      as a separate input: its item's events, paused agents and wakes fold into
      the new item, whose notice lists every event in time order.
    - Capture records the thread's stop generation. A Stop recorded after it settles the item
      as `stopped` without a resume turn or carried inputs.
    - The suspended turn is the capture item's `interruptedTurnId`, read
      from the pending host-default restart-journal item. An exact Stop naming it records the Stop with no process to interrupt, and the
      resume never runs; an item captured without its stop generation cannot
      be cancelled, so that Stop fails with `-32603`. The turn a resume starts
      or steers remembers the turn it continues and answers a Stop naming
      either.
    - A dispatch that conversation admission refuses (`ConversationBusy`) waits
      and retries without counting an attempt; it never fails for that reason.
    - Dispatch is bounded at three attempts. A failure is recorded as `failed`,
      journals `restart_failed`, and sends one push naming the thread and
      cause. The host-default gateway resumes its pending journal.
  - **Codex:** unless `prepare-handoff` already left a stopped recovery journal,
    run the same stopped transaction in-process whenever Codex work may be
    active, bounded at 35 s. The replacement's bootstrap recovers the exact
    turns in the host-default runtime before ingress opens. Retired-daemon
    adoption first transfers exact captured work into that same default journal;
    no enrollment daemon remains to reattach.
  - Launchd's 60 s stop deadline is the outer ceiling.
  - While shutting down, the gateway sends no completion push for an
    `interrupted` turn, because the replacement resumes it. A dynamic-tool or
    approval request issued during the gap has no client to answer it.
  - The Claude capture record holds the host-default target, thread,
    session, cwd, model, effort, interrupted turn, paused background tasks,
    cause and recovery id (`src/providers/claude/restart.rs`,
    `restart_driver.rs`, `supervisor/restart_capture.rs`). Migration rewrites
    retired Claude account journals to that target; the gateway removes the
    journal once every item is settled. Resuming waits for the listener, since
    each runtime's MCP config points at `/mcp`.
  - The launchd plist permits an immediate replacement start. Its tracked
    launcher enforces the 60 s rapid-crash backoff from a private last-start
    record; only a marker matching the current stopped recovery generation
    bypasses it once.
- Planned entry points for the same fence, snapshot and leaf-first suspension:
  - `just codex-daemon-restart` restarts the shared daemon with a
    generation-bound grant for those exact thread and turn ids. The control
    connection recovers parents before children and sends child sessions
    through Core's agent rehydration path, including registry and
    completion-watcher state. Each task has a persisted five-attempt retry
    budget; exhausting it records a terminal failure and reopens unrelated work
    instead of holding the host fence forever. Runtime installation and
    rollback use the same transaction; restarting ChatGPT alone touches
    nothing.
  - `runtime prepare-shutdown` writes the durable journal and deliberately
    leaves the daemon stopped. The primary service host's nightly reboot calls it right
    before shutdown and writes a private marker naming that generation; the
    next bootstrap resumes the journal, and AgenTTY waits boundedly for that
    generation before launching Codex shells. An older completed journal cannot
    suppress a later recovery prompt.
  - `runtime prepare-handoff` is the same stopped transaction without a reboot
    marker (see the installer above).
- Cold startup accepts a leftover Unix socket only when no managed process is
  starting or running, a raw connection is refused and the path itself is a
  socket; the transport rechecks and removes it under its startup lock.
  Protocol timeouts, listeners, regular files and symlinks block startup, stop
  and restart preparation require the socket absent, and no gateway watchdog
  removes socket paths. A live PID whose identity cannot be verified is
  preserved and fails closed; only an absent or zombie process authorizes
  removing the daemon's PID record. Timed-out lifecycle probes are killed so a
  stale binary cannot mutate the next generation's record.
- The configs-owned five-minute ensure job may load an absent service. It may
  also restart a process that is positively present but has outlived the
  three-minute startup/recovery grace without owning its configured listener.
  An authenticated `codex unavailable` response, or an unresponsive health
  request while the exact process and listener exist, is degraded telemetry,
  never restart authority. Foreign listeners, responsive or not, fail closed.

## Environment files

- The LaunchAgent shell can source an operator env file, so Codex and MCP auth
  match interactive shells.
- `--env-file` forwards entries except gateway-owned configuration to the
  `codex app-server` child. `RC_CODEX_GATEWAY_*` keys stay daemon-only and
  override inherited login-shell values; `RC_CLAUDE_*` settings are also
  gateway-owned and take env-file precedence. Command-line flags beat both. This
  stops stale shell exports from replacing host configuration.
- The daemon reads the `RC_PUSH_BROKER_*` keys from its inherited process
  environment (`std::env::var`). In `--env-file` they only reach the Codex
  child, so a debug gateway given a redirected `RC_PUSH_BROKER_URL` there still
  pushes to the real broker and device. Set
  `RC_CODEX_GATEWAY_PUSH_BROKER_ENABLED=false` instead, or export the override in
  the shell that launches it.

## Claude provider

The daemon runs turns through the `claude` CLI, so a chat can pick Codex or
Claude. The `RC_CLAUDE_*` settings are in
`config/codex-gateway.env.example`.

- **Routing.** Claude thread ids start with `claude_`, and the gateway routes by
  thread id. A new thread carries `params.provider = "claude"` on
  `thread/start`. `command/exec`, `fs/readDirectory`, `daemon/*` and
  `initialize` stay Codex-only whatever the params say.
- **One warm runtime per active thread.** Each active Claude thread owns one
  bidirectional
  `claude --input-format stream-json --output-format stream-json` process.
  Follow-up turns and `turn/steer` write to its stdin.
  - `InputWriter` admits only frames at most 32 MiB including their newline.
    It counts the borrowed Claude representation before allocating a frame or
    changing turn state, covering image-envelope expansion and JSON escaping.
    A refusal returns typed `capacity` for `input frame bytes`; the existing
    runtime and writer remain usable. The 16-entry queue contains admitted frames.
    Controls are prepared before pending-control registration or settings mutation;
    only an actual writer failure retires a runtime.
  - A Claude that stops reading stdin (on a headless host, typically a process
    blocked on an unanswered macOS privacy prompt) must never hold gateway
    work. An input that cannot enter the full queue within 10 s, below the
    app's 15 s request timeout, returns typed `providerUnresponsive`: it was
    not admitted. An admitted input whose write does not finish within 10 s
    returns `inputDeliveryUncertain`: it still reaches Claude if it resumes.
    Both journal `runtime input_stalled` and keep the runtime and its process.
    The bound only fires once the 64 KiB stdin pipe is full, so a Claude that
    stops reading behind a short backlog still accepts small writes.
    An input counts as unconsumed for restart capture from the moment it is
    admitted. A turn start or fold reserves its queue slot before the turn
    opens, so a full queue refuses it without opening a turn, and a later stall
    keeps the started turn. `turn/steer` releases the thread's lifecycle lock
    once its frame is queued, so reads and settings never wait on the pipe. A
    `claude/message` whose frame is queued returns its receipt
    (`delivery_confirmed: false`) and records the delivery, so a retry of the
    same `deliveryId` stays a duplicate. Control replies keep their 30 s bound
    and report `providerUnresponsive` too. A settings change that fails during
    a turn refuses the new one as `providerUnresponsive`; an idle runtime is
    replaced instead. Model names in conversation
    settings, Claude start RPCs and voice start are bounded at 512 UTF-8 bytes by
    the wire model validator.
  - A runtime is idle only when it has no turn and no live background task.
    Background tasks are the shells, Monitor watches and subagents in the CLI's
    latest `system/background_tasks_changed` set, which the CLI emits whole on
    every change and never at startup.
  - The 10-minute expiry, the idle cap and explicit releases apply only to
    idle runtimes and never delete the resumable JSONL session; the next
    message resumes the exact session. Headless probes release their test
    runtime as soon as validation finishes. Do not keep one permanent process
    per touched thread.
  - At most two idle runtimes stay warm. When another becomes idle, the least
    recently idle ones beyond two retire at once. Conversations and concurrent
    turns are never limited, and a runtime with a turn or background task is
    never a candidate.
  - A pending scheduled wake holds an idle runtime past both the expiry and
    the cap, because the CLI fires `ScheduleWakeup` and `CronCreate` jobs only
    while its process runs (`src/providers/claude/wake_hold.rs`). The hold is read from
    the session JSONL, the same record `--resume` restores crons from, before
    every idle retirement decision; the stream says nothing when crons are
    restored or fire. Reads continue from the last offset in bounded chunks
    and parse only wake-related lines, so only the first read of a resumed
    runtime scans the whole file.
    - A dynamic loop holds until an hour and five minutes after the session's
      latest transcript activity (an hour is the longest delay the CLI's own
      keepalive re-arms with), until `ScheduleWakeup` returns `stopped`.
      `--resume` does not restore a loop, so loop records written before a
      resumed runtime started are ignored.
    - A cron holds until `CronDelete`, until a one-shot fires (a
      `turnOrigin: "scheduled"` record carrying its prompt), or until the
      CLI's seven-day lifetime from its creation. A one-shot pinned to a date
      (`M H D Mo *`, local time as the CLI reads it) holds only until five
      minutes past that time, so one that fell due while no process ran holds
      nothing. Crons written before a resume are held too, because `--resume`
      restores them.
    - Every hold expires on its own, so a stale record cannot pin a process.
      A missed one-shot in any other cron form still holds until the lifetime
      bound. A restart captures an idle runtime whose hold is
      live and resumes it, so its crons come back with `--resume` and the
      notice asks the model to re-arm its `/loop`.
- **Claude resume identity is independent of cwd.** A resumed conversation resolves
  its exact UUID transcript inside the configured Claude home. A different launch
  directory uses the absolute transcript path with `--resume`, never a fork or a
  fresh session. If a full-access thread's recorded cwd disappeared, its exact
  transcript may supply the latest existing recorded cwd; `cwd_recovered` records
  both paths. Unrecorded missing overrides fail with their path. Read-only scopes
  never recover into another directory. The runtime and saved parent selection
  retain the effective launch cwd.
- **Turns have no wall-clock cap**, in either provider. A turn ends when the
  agent ends it, when the process dies or when the user interrupts. Turns can
  legitimately run for hours, and a long silent tool call looks the same as a
  wedge, so a timer can only kill healthy work. The CLI records such a kill as
  `[Request interrupted by user...]`, which `src/providers/claude/timeline.rs` drops so an
  abort never replays as the user's message.
- **Replay renders only typed user input as user bubbles.** It never renders
  injected records as user bubbles or lets them open turns. Injected records
  are `isMeta` context and skill injections, compaction summaries, and
  envelope-wrapped harness text such as `<task-notification>`,
  `<system-reminder>` and local-command plumbing.
  - A steer sent during a running turn exists in the session file only as a
    `queued_command` attachment; replay renders it as a user message whose id is
    its `source_uuid`, the client id the stream echoed.
  - The CLI's own `<synthetic>` assistant records never render, such as
    "No response requested." answering the resume nudge after a restart.
  - An injected record between turns still opens a header-only turn draft, so
    the assistant and tool output it triggers is captured.
- **Translation.** Claude output becomes the same app-server v2 notifications
  the app already renders (`src/providers/claude/translate.rs`), so timelines, replay,
  APNs and Live Activities need no app-side special cases. A successful `Read`
  whose `toolUseResult` is an image completes as Codex's `imageView` item with
  its absolute path and the tool result's image as `imageUrl`, which tool
  media compaction turns into `rcMedia`, where the Codex fork's `view_image`
  names its saved snapshot as `savedPath`; it starts as the ordinary `Read`
  tool call. A turn that
  fails while its latest assistant stop is a `cyber` refusal
  (`stop_details.category`) carries upstream's `codexErrorInfo: "cyberPolicy"`;
  automations switch to their refusal fallback on that code.
- Claude stdout records are limited to 32 MiB and stderr records to 16 KiB,
  including a newline. A record over its limit fails that runtime with an
  `error` notification carrying `data.kind: capacity`, the resource and limit,
  then a failed turn completion. The async reader refuses overflow before
  awaiting a newline. Per-turn assistant UUIDs and provider-message offsets
  share a 65,536-entry and 8 MiB key-byte budget; they fail on capacity rather
  than evicting identities needed for deduplication. Provider IDs are limited
  to 4 KiB, message blocks to 4,096, pending tools to 256 and their retained
  inputs to 16 MiB of estimated memory. Completed tool results release their
  input budget. The header LRU retains at
  most 4,096 entries and 16 MiB of estimated memory; an oversized header is
  served without caching. Bulk list scans never evict resident headers to
  admit a miss, so repeated listings rebuild only uncached or changed files.
  Header reads and full scans do filesystem work outside the header-owner
  mutex. Concurrent full scans share one blocking worker, with at most 64
  waiting readers. The 32 single-header workers never queue behind that scan;
  their permits stay with blocking work after caller cancellation. Four separate
  pagination workers retain their permits inside blocking work too, so cancelled
  searches cannot accumulate workers holding header snapshots. Scans
  merge under a generation fence and preserve entries changed by concurrent
  reads. At most 4,096 changed paths are retained; beyond that, the scan result
  is served without merging its cache. A scan journals header rebuild counts
  at debug level.
  These are capacity limits, never turn time limits.
- **The stream owns turn boundaries.**
  - Dispatch pre-opens a turn only because the RPC caller needs its id
    synchronously.
  - Output arriving with no dispatched turn opens an *agent-initiated* turn,
    such as a peer message, a background-subagent completion or a scheduled
    wake. It is a first-class turn on the same notification, APNs and Live
    Activity path. Both kinds close on the CLI's `result`.
  - Only turn content opens a turn: `stream_event`, `assistant`, `user`,
    `result` and `system/thinking_tokens`. Ambient lines (`system`
    init/status/`task_*`, `rate_limit_event`, `command_lifecycle`) and
    background-subagent inner traffic (`parent_tool_use_id` set) never do;
    otherwise an idle session would manufacture turns.
  - Synthesized frames carry `agentInitiated: true`, and `turn/started` adds a
    best-effort `wakeReason` (`{kind, name}`, peer wakes only).
  - Dispatching during an agent-initiated turn folds in: the wake turn completes
    at the fold, and the dispatched turn takes over the stream and closes like
    any dispatched turn.
  - A dispatched turn skips only a `result` that positively answers other
    work: an `origin.kind` other than `unclassified` (stdin input) or `human`,
    or a non-empty `user_message_uuids` without the dispatched input. Any
    other `result` closes it, so an early error result cannot leave it open.
    The CLI has taken the input once it echoes the uuid or an `assistant` or
    `result` frame lists it (synthetic inputs are only listed, never echoed),
    or once it takes any input written after it, since stdin is FIFO; a steer
    can therefore close the turn. `consumed_input_ids` and
    `UnconsumedInputs::take` own that evidence for turn boundaries and the
    carried-input queue alike. `--resume` after a Stop or kill emits a
    `result` for background tasks the previous process left unfinished
    (`origin.kind: "task-notification"`, no uuids); closing on it completed
    the next message empty and split its reply into an agent-initiated turn.
  - The billing guard runs on every `system/init`, including per-turn ones that
    arrive outside a turn and therefore reach no translator.
- **Steering folds into one result.** Streaming input folds steering into the
  active query, and the next CLI `result` is authoritative for the whole turn.
  Never expect one result per steered input: the gateway would suppress the real
  completion and leave the UI stuck on `Thinking…`.
- **Parity.** Claude supports live steering and exposes assistant deltas, tool
  actions, plans, reasoning progress, usage and completion through the same UI
  contract as Codex, and `thread/fork` works for both (*A fork copies the
  conversation through a finished turn*).
- **Text between tool calls is narration; other thinking is a reasoning row.**
  - Current Claude models return narration as `thinking` blocks whose signature
    is tagged `narration`. In stream-json mode the CLI sends no thinking display
    when the user's `showThinkingSummaries` is on, so the API omits that text.
    The runtime therefore passes `--thinking-display summarized`, which also
    gives ordinary thinking blocks their summary text.
  - The API returns narration longer than a sentence or two only as a summary;
    the model's own text never reaches the stream. For content the user needs
    exactly as written mid-turn (code, commands, values), the runtime spawns
    the CLI with `CLAUDE_CODE_PEWTER_OWL_TOOL=1`, which offers Claude Code's
    `SendUserMessage` tool in its verbatim mode, and the session context tells
    the model to send such content through it. Live translation and history
    replay render each call as an assistant message with the call's
    `input.message` verbatim and the tool-use id as its item id; its tool
    result is dropped. The variable is undocumented CLI configuration, so a
    `system/init` without the tool logs a warning.
  - `src/providers/claude/translate.rs` classifies a block from its signature, because the
    session file does not keep the stream's `narration_block_indexes`. Live
    translation and history replay both render narration with text as an
    assistant message `<message id>#<block index>`.
  - Thinking deltas are never streamed, because only the final signature says
    which kind a block is. `content_block_start` (or an earlier
    `system/thinking_tokens`) opens an empty reasoning row that renders
    nothing but fixes its position. The block's signed `assistant` record
    completes it, whether it arrives before `content_block_stop` (as captured)
    or after: narration hides the row, and other thinking sets its summary to
    the text, clamped to 4,000 characters because the history index stores
    that snapshot. Empty text falls back to `Thought for ~N tokens` from the
    block's `thinking_tokens` estimate. A thought cut off before its record
    stays hidden.
- **Live observation checkpoints.** `claude/thread/liveCheckpoint {threadId}` is
  a read-only capture of the current running Claude translator; it never starts
  a runtime or changes subscriptions. No live owner returns `status: unknown`
  with `reason: noLiveState`. A capture returns `status: observed`, thread/turn
  identity, `epoch`, `throughSequence`, `activeTurn`, `liveItems` and `unknownItems`.
  Snapshot and watermark are captured under the runtime lock. Translator-produced
  item frames carry independent `rcClaudeLive {epoch, sequence}` metadata, including
  frames waiting for delivery when the snapshot is captured. A caller first
  acknowledges its subscription set and buffers incoming frames, then discards
  covered live starts/deltas through that watermark and accepts later continuation
  in the exact epoch/turn. The active turn has `itemsView: notLoaded`.
  Canonical completions still apply; epochs cannot be
  compared numerically. This read makes no history-availability claim.
  Text and withheld thinking prefix buffers are bounded at 1 MiB per block and
  16 MiB retained allocation across this gateway. Item completion, turn end and
  runtime retirement release them. Overflow marks that block unknown, releases
  its buffer and journals one typed capacity outcome; ordinary streaming continues.
  Unknown prefixes are never presented as complete. Reasoning summaries remain
  empty until the signed assistant record arrives, including at checkpoint reads.
  A checkpoint result exceeding 24 MiB encoded JSON returns typed unknown capacity.
  Delivery uses the normal large-frame announcement and unchanged request/write
  deadlines. App adoption is a separate companion; replay still stores no deltas.
- **Sessions.** Claude sessions are its own JSONL files under
  `~/.claude/projects/<cwd slug>/<session uuid>.jsonl`, listed by the separate
  `claude/thread/list` RPC and merged into the history list. The slug is lossy,
  so it is only ever computed forward from a known cwd. Distinct files with the same session UUID across projects are refused by
  list, header, projection and mutation lookup. Hard-link aliases of one
  device/inode are deduplicated by the same lookup rule.
- **Names use Claude Code's own title record.** `thread/name/set` takes the
  same trimmed, non-empty name as on Codex and announces
  `thread/name/updated`. A live runtime gets the CLI's `rename_session`
  control request, which also keeps a title set before its transcript exists.
  An idle session gets the Agent SDK's appended `custom-title` record, refused
  while the file ends mid-record. A thread with neither is rejected with
  `-32602`, so a new thread is named after its first `turn/start`. Reads return
  the latest custom title as `name`; `preview` stays the AI title or first
  prompt. Gateway-originated manual and automatic renames share the per-thread
  owner in `gateway/renames.rs` (at most 1,024 active entries; weak entries are
  swept on admission). Each thread admits one submitted write and one waiter;
  excess requests fail with typed capacity. Names and automatic comparison
  values are limited to 4,096 bytes. Manual requests advance a generation before
  waiting; automatic writes recheck it and reread the provider name under the
  same serialized owner immediately before submission. Callers wait at most
  30 seconds. After submission, the bounded commit task retains ordering until
  a provider reply or connection/runtime end, even after the caller times out.
  Waiting requests that time out are never submitted. Title evaluation capacity
  is released before committing. Claude releases its general lifecycle lock
  after binding the exact runtime control and before stdin/reply waits, so Stop,
  retirement and planned suspension remain independent.
  Codex and Claude provide no expected-name compare-and-set. A rename made
  directly by an external TUI/Desktop during an in-flight automatic write is
  therefore outside this guarantee; no finite provider-commit bound is claimed.
- **Side questions never open a turn.** `ClaudeSupervisor::side_question`
  sends the CLI's `side_question` control request to a warm runtime, also while
  a turn runs, and returns the text; the CLI denies tools and writes nothing to
  the transcript. An unanswered control is cancelled at its deadline. A synthetic
  answer is an error. Without a warm runtime,
  `ClaudeSupervisor::detached_side_question` runs one `--fork-session
  --no-session-persistence --tools ""` print-mode process that leaves no
  session behind. A Codex side question is an
  ephemeral fork whose notifications `side_question::Forks` routes only to its
  waiter, ahead of every other control and client consumer.
- **A launch never falls through to a fresh session.**
  - `--session-id` is used only for a session uuid this gateway minted in
    `thread/start`, which first writes a 0600 creation record beside the
    thread's identity index (`remotecoder-history/<key>.minted`). The record
    survives restarts and is a separate file because older gateways reject
    unknown index records. `--resume` requires `projects/<slug(cwd)>/<uuid>.jsonl`
    in that runtime's own config dir.
  - Otherwise the turn fails with `-32602`, naming the profile and cwd, and no
    process starts. User turns, restart recovery and `rc-gateway` all go
    through this check. A missing transcript never creates an empty session under
    an existing id.
  - Busy threads are refused per thread; there is no host-wide Claude turn cap.
- **A fork copies the conversation through a finished turn.** `thread/fork` on
  a `claude_…` thread runs in the source's host-default Claude profile
  (`src/gateway/claude_fork.rs`).
  - It mints a new `claude_<uuid>` and writes its transcript beside the
    source: every complete source record through the kept turn's last rendered
    record or tool result (the whole file when that turn is the latest and none
    runs), byte for byte except the top-level `sessionId`, plus the source's
    latest `custom-title` and `ai-title` records when they come later. The
    fork's first turn resumes that file, so it never launches as a fresh
    session.
  - The gateway writes the transcript itself rather than running
    `claude --fork-session`. That CLI copies only the chain after the latest
    compaction, so a fork of a compacted conversation would lose its earlier
    visible history (CLI 2.1.282 kept none of 236 pre-compaction records).
  - The index keeps the kept turns' identities, including reasoning and plan
    rows, through `ClaudeSupervisor::fork_thread_records`. Session metadata copies
    the source's current model, effort and Fast selection at revision 1. Both
    are written before the transcript, which appears atomically last. A
    failure or cancellation before then leaves no visible thread, only records
    under the unused id: its creation record and index copy, which nothing
    reads, and its metadata record, which metadata reads still return. Once
    the transcript exists the fork is complete, even if the response fails.
  - A running turn never moves. Forking at or after one is refused, and a
    whole-thread fork stops before it. The fork point is read under the
    source's lifecycle lock, and the fork is refused if the running turn
    changed meanwhile.
  - `--resume` resurrects non-durable session crons from the `CronCreate`
    records in the transcript (CLI 2.1.282 logs `resume: resurrected N session
    cron task(s)`), so a fork whose copied records still hold one under the
    `src/providers/claude/wake_hold.rs` rules is refused rather than running it twice.
    Subagent transcripts (`<session>/subagents/`), background tasks and the
    `.parent` record (user Stop, parent deliveries) stay with the source. The fork keeps each Agent call and the result it
    returned.
  - The response is the fork's `thread/read` shape plus `forkedFromId`, which
    later reads do not return. Its activity time is its last copied record, so
    the drawer lists it beside its source until its first new turn.
- **User Stop is exact.** `turn/interrupt` requires the running or suspended
  `turnId`: missing is `-32602`, different or ended is `-32600` with
  `data.kind` `turnNotRunning`. A Stop that cannot be saved or checked is
  `-32603`. For a running turn it sends CLI `interrupt` with
  `cancel_queued`, waits up to 3 s, retires the runtime as `interrupted`, then
  ends the process group so its background agents and tasks also stop.
  `cancel_queued` keeps the CLI from running a steer it has not taken yet, so
  every steer is either echoed in the stopped turn or discarded, as in Codex;
  the app sends the discarded ones as the next turn. Stop claims the exact
  running turn as stopping under the runtime registry lock and never waits
  for the lifecycle exchange lock. That claim refuses new turn/steer admission
  and ordinary stream completion, while control replies can still arrive.
  Interrupted input/settings exchanges fail their exact-process fence; a
  captured Stop generation prevents late input acknowledgement from clearing
  a newer parent tombstone. Planned suspension also retires atomically through
  the registry without waiting for the exchange lock.
- **Claude parent delivery has one durable receiver owner.** Gateway-owned
  parents use their supervised message path; terminal parents use a verified
  native holder. The parent record owns selection, route evidence, Stop and
  delivery intent. A prepared payload and deterministic UUID precede submission;
  canonical session evidence reconciles an uncertain write even after receipt
  compaction. An ID with changed payload is rejected. Native socket loss never
  authorizes takeover or a second delivery route. Stop survives restart and
  blocks callbacks until the user's next turn. Accepted/submitted is distinct
  from recorded input and model consumption. `docs/delegated-jobs.md` owns the
  job-level obligation and immutable completion contract.
- **Historical identifier admission.** Session record UUIDs, assistant message
  IDs, queued-prompt source UUIDs and tool-use/result IDs use a 4 KiB limit,
  shared with live assistant and tool-use IDs, before the projection retains
  keys or formats row IDs.
  Identity-index records apply the same bound before map insertion, with 32 bytes
  of additional allowance for a derived item suffix. Invalid historical IDs fail
  the whole read with typed `capacity`; no partial projection or cursor is admitted.
- **A history read never invents a turn id for a running prompt.** Claude keeps
  content in the session file and identity in the notification-fed index
  (`src/providers/claude/conversation_index.rs`). The CLI appends a prompt to its file seconds
  before echoing it on stdout.
  - A history page therefore takes the executor's active turn id and files
    the rows after the last indexed row in the trailing file turn under that
    turn. Those rows carry the record uuid as their `clientId`, exactly as the
    stream will.
  - Any other unindexed row stays with the indexed row before it, so it can
    never pull a running turn ahead of earlier ones.
  - Only a thread with no running turn falls back to the synthesized
    `claude-turn-<ordinal>`. Labelling a live prompt with a synthesized id once
    rendered one submission as two user bubbles.
- **cwd is required.** The CLI runs in the working directory, with no fallback;
  the app rejects an unset cwd before dispatch.
- **Router authentication.** `RouterConfig` (`providers/router.rs`) is the one
  owner of optional llm-router listeners and the host key. Router configuration
  requires the inference URL, accounts URL, absolute private key-file path and
  exact Codex account together. Non-loopback origins need explicit
  `RC_CODEX_GATEWAY_ROUTER_ALLOWED_ORIGINS`; no personal suffix grants trust.
  With no router, the unmodified Claude Code CLI uses its own native login, and
  Codex uses its managed-home login. Router-only account, title and speech
  services stay unavailable. In router mode, canonical command
  construction clears inherited provider environment and injects only
  `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` and
  `CLAUDE_CODE_SKIP_FAST_MODE_ORG_CHECK`, without which a router token reports
  Fast as disabled by the organization. Each command reads the private
  regular key file anew, failing visibly if unavailable; never log its contents.
  The router owns subscriptions and failover. `system/init` must still report
  `apiKeySource: "none"`, Fast off unless the runtime's confirmed selection
  turned it on, and `permissionMode: "bypassPermissions"`; the existing guard
  kills violations. `result.total_cost_usd` remains an
  API-rate estimate and is never forwarded as billing.
- **One host-default profile.** All Claude sessions use `RC_CLAUDE_HOME` or
  `~/.claude`; `REMOTE_CODER_PARENT_CONTEXT` carries no account. Startup merges
  every retired or orphaned `.rca/*/claude` profile and its gateway state before
  ordinary Claude command starts, cloning without moving source profiles or
  companion state. A completed receipt prevents later rescans. Conflicts remain
  in gateway state. The installer snapshots rewritten state and restores it on
  rollback; recovery-only gateways skip Claude migration. Follow
  `docs/provider-accounts.md` for migration and redirect removal. Claude enroll,
  login, logout and account moves are unsupported. Codex also uses only its
  host-default runtime; retired profile adoption is owned above.
- **Health is reported, never restart authority.** `/health.claude` and
  `claude/status` report router configuration, key readability and active turns;
  they never run auth or control-only quota processes. Readiness does not prove
  router reachability or a successful model request. A Claude failure never
  changes top-level `status` or removes `codexPid`. Keep native stream usage
  where reported; subscription quotas without observations remain unknown.
  Router authentication disables claude.ai connectors and Remote Control.
  Set `CLAUDE_CONFIG_DIR` only for explicit `RC_CLAUDE_HOME` so the default
  profile retains `~/.claude.json` and local MCP. Subprocesses inherit the key;
  same-user process environment inspection can expose it. Never put it in argv,
  diagnostics or receipts.
- **Context accounting is per request.**
  - Stream `message_delta.usage` becomes the same typed
    `thread/tokenUsage/updated` DTO as Codex.
  - The terminal update reports the smaller of the model maximum from
    `result.modelUsage` and the effective auto-compact window. That window is
    resolved from Claude Code's user, project, local and managed settings.
  - It uses the latest request's active context rather than summing a tool
    loop's repeated requests.
- **Model, effort and Fast are mutable conversation settings.**
  - Every `turn/start` carries `model`. A `fast` service tier turns Claude Code's
    Fast mode on, `null` turns it off, and an absent tier keeps the parent
    record's choice only for the same model. The launch `--settings` file carries `fastMode`.
    `conversation/settings/update` changes a warm runtime through correlated
    `apply_flag_settings` and `get_settings` controls; Fast reads back from
    `effective.fastMode`. On Codex the gateway itself resumes a `notLoaded` thread first,
    so the client sends one RPC, and upstream failures keep their codes.
  - Read paths clone the runtime owner's latest settings snapshot under its
    short state lock. They never acquire the per-thread lifecycle lock or send
    a control request. While a mutation has invalidated settings and no
    readback has succeeded, model and effort readback are null; transcript
    headers and current turn status remain available. Thread resume, voice start and agent-call
    commands serialize on the lifecycle owner and recover unknown settings with
    `get_settings` before verification.
  - A running CLI query keeps its captured settings, including when a
    dispatched input folds into a wake turn. The response reports `nextTurn`
    until the next query.
  - Voice toggles never retire the agent process. A cwd change needs a new
    runtime, and an idle runtime may be replaced after a failed settings
    control. Unknown readback stays unknown and can be retried.
  - The gateway's default model covers an omitted model. The authoritative record
    of what ran is the stream's `result.modelUsage`, not the requested id.
    Internal `/model` echoes never open turns.

## Agent tools (`src/agents/tools/`)

- Agent-initiated calls use `request_call`, `call_status`, `steer_call` and
  `end_call`, with provider-owned caller identity and exact call IDs. `self`
  rings RemoteCoder, and an E.164 number uses the primary host's leased 46elks worker.
  Both share subscription GPT Live and the normal original-agent handoffs. The
  legacy `end_voice_call` takes no parameters and only ends a user-started
  voice call owned by its caller. Every call mutation is one file-locked read,
  change and write in a blocking worker that publishes only after the commit.
  Receipts are kept for 500 records or 30 days: a live call is never evicted,
  and a request is refused while the history is full. [The calling runbook](../agent-calls/README.md)
  covers private configuration, no-replay recovery, bounded carrier cleanup and
  separate physical-acceptance evidence.
- The registry also exposes `notify_user` (`{title, body}`). One registry and
  one `dispatch` serve both providers, so the two projections cannot drift into
  different tools sharing a name. Every dispatch writes a `tool` journal line. Its `arguments` are an audit
  projection (`ToolCall::audit`, `src/agents/tools/dispatch.rs`): identities and
  sizes only, so call briefs, steering text and notification copy never reach
  the journal, and rejected arguments are recorded as `[arguments rejected]`.
- `publish_visual` has one owner, `storage::visuals::PublishVisual`; its
  contract is [HTML visuals](../docs/html-visuals.md). Outbound `wire::tool_media`
  derives `rcVisual: {digest, title}` from successful canonical publication
  results for both provider item shapes; it never injects assistant messages or
  writes a second publication store. Keep projection idempotent and limited to
  the exact tool, successful terminal status and canonical returned embed.
  Local images are found
  only by `storage::visual_bundle` and prepared only by
  `storage::visual_images`, the sole `sips` caller. Keep its invariants: a
  published visual is at most 2 MiB after embedding, content-addressed and
  never dependent on its host sources, though it may load network resources;
  image preparation is
  bounded (one active, three waiting, per-image and publication deadlines,
  killed children, capped staging) and refuses work rather than queueing it;
  failures store nothing and journal only a redacted category in the
  outcome's `detail`.
- Tool media has one owner, `storage::tool_media::ToolMediaStore`, fed only by
  outbound frame compaction (`wire::tool_media`); its contract is
  [Tool media](../docs/system-architecture.md#tool-media). Keep it
  content-addressed, capped with retention shared with visuals
  (`storage::content_store`) and rebuildable from provider history; never hold
  media bytes elsewhere for clients.
- `take_photo` routes to the installation driving the thread's latest input:
  admitted `turn/start`, `turn/steer`, `claude/message`, `thread/queue/add`, or
  a voice utterance/handoff from the call owner. Internal queue starts and restart
  resumes keep that driver. Operator input and input from an explicitly empty
  device declaration clear it. Drivers are bounded, in memory, and unknown
  after a restart. Unknown and explicitly cleared drivers have distinct model
  messages. An installation that never declared gets the update message.
- `gateway/device_tools.rs` owns connection declarations, drivers and device
  operations. `device/tools/declare` and `device/tool/result` are owned RPCs;
  invoke/cancel are notifications on the newest capable connection of the
  authenticated installation. Results belong to that exact connection. One
  operation per installation and eight per gateway are allowed, with a 60-second
  deadline. Turn end cancels pending work; deadline/disconnect after send reports
  unknown. A matched invalid result fails immediately. Accepted results remain
  authoritative through later deadline, disconnect or turn end.
- Successful device content contains one JPEG per capture, back then front for
  both, with no text. Upload failures use `detail`; the gateway owns model text.
  The model receives JPEGs up to 1,568 pixels on their long edge. `UploadStore`
  verifies each named original's completed path, size and SHA-256, then moves it
  without replacing files into `~/Pictures/RemoteCoder/YYYY-MM-DD/` (host local
  time, numeric suffix on collision). A save failure preserves the inline image
  and explains why the original was not saved. Results for unknown, late or
  differently connected operations cannot move originals.
- **Claude reaches the tools over MCP.**
  - The gateway hosts a tools-only MCP server at `POST /mcp` (`src/agents/mcp/`).
    It speaks protocol revision 2026-07-28 as its single version. That
    revision dropped the `initialize` handshake, the GET stream and
    protocol-level sessions, which matches this stateless request/response
    server.
  - There is deliberately no legacy path: an older client gets `-32022` listing
    the supported versions rather than a half-working session.
  - Each request's `MCP-Protocol-Version`, `Mcp-Method` and `Mcp-Name` headers
    must match the body (`-32020` otherwise), and `GET` is 405.
  - `MCP_PROTOCOL_NEGOTIATION=auto` is pinned in the Claude child environment,
    so a CLI default change cannot move the negotiation.
- **One token per runtime, owned by the runtime.**
  - Spawning a Claude runtime mints a random bearer token, mapped server-side to
    that thread and session. It is written into a 0600 `--mcp-config` file
    whose name is unrelated to both, so the token never appears in `ps`.
  - `McpRuntimeAccess` revokes the token and deletes the file in its `Drop`, so
    every retire path is covered without knowing tokens exist.
  - Startup sweeps the config directory, because no runtime owns anything there
    yet. `--strict-mcp-config` is deliberately not used, because the host's own
    MCP servers and skills must survive.
- **Codex reaches the tools through `dynamicTools`.**
  - The gateway injects the `remotecoder` namespace into client-originated
    `thread/start` as it proxies it. Codex persists the declarations and
    restores them on resume; resume accepts no declaration updates.
  - Gateway-internal starts, such as the voice shadow thread, stay tool-free.
  - Codex requests a call with `item/tool/call`, which the gateway answers
    upstream and never broadcasts. No client declared these tools, so no client
    can answer them, and an unanswered call stalls the turn forever.
  - `dynamicTools` is an experimental app-server field. It is absent from
    `codex app-server generate-json-schema` output but present in the binary,
    and the gateway negotiates `capabilities.experimentalApi = true`.
- Registry Codex calls claim `(threadId, callId)` once per gateway. Copies join
  the same result and answer on their own connection. Completed claims remain
  for 60 seconds; capacity refuses new calls without evicting live claims.
  Tool results carry text and inline images; journals retain image sizes only.
- In Codex code mode, a dynamic tool's result reaches `exec` JavaScript as one
  string of text and `data:` URL lines, and its declaration says
  `Promise<unknown>`. Models otherwise assume the MCP `result.content` shape,
  so the Codex projection of `take_photo` states the string shape and how to
  pass each image to `image()`. `just gateway-e2e-device-tools-live` proves it.
- **Verify by calling, not by listing.** `just gateway-e2e-agent-tools-live`
  makes a live agent on each provider call `end_voice_call` and asserts the
  gateway journalled the dispatch and the turn completed. Registration alone
  proves nothing: a negotiation or projection regression still advertises the
  tools but never delivers a call. With no call up, `end_voice_call` answers
  "No active voice call to end.", a round trip with no side effect.

## Voice (gateway side)

The iOS side is in `RemoteCoder/AGENTS.md`; both paths are in
`docs/system-architecture.md`, *Voice paths*.

- Codex voice sessions let app-server own handoffs. Keep Codex realtime start
  params aligned with the official desktop client: do not send
  `delegationAckFiller`, and do not claim `handoffOwner`.
- Claude voice uses a host-default Codex realtime shadow thread with client-owned
  typed handoffs; only this path sends `handoffOwner: "client"`. The gateway
  runs those handoffs against the warm Claude runtime and streams commentary and
  final output back to the realtime model. Further spoken instructions steer the
  in-flight Claude stream instead of starting a competing process.
- Claude delegation mirrors the upstream desktop client
  (`src/voice/handoff.rs`):
  - At most one delegation is active; the newest wins when the user speaks
    again mid-task.
  - Each Claude turn gets exactly one authoritative completion, at
    `turn/completed`. Mid-turn agent messages are commentary appends and
    completion candidates, never completions.
  - Superseded delegations are silently retired, never completed with invented
    failure text.
- Every Claude runtime's `--settings` file carries a `SessionStart` hook
  (`claude-session-context`, `src/providers/claude/session_context.rs`) that
  supplies RemoteCoder's context, requesting regular assistant-text progress
  usable in text and voice. Claude Code records it as hook context once per
  conversation, adds it on resume when missing, and leaves resumed
  system-prompt snapshots unchanged. Never send it as stream-json input: the
  CLI prefixes a synthetic frame without a typed origin with `[MESSAGE FROM
  NON-USER SOURCE - NOT USER INPUT]` and merges it into the user's next prompt.
  `isSynthetic` skills and local command output stay out of user bubbles.
  - Voice delegations carry `<realtime_delegation>` with `<input>` and
    `<transcript_delta>`, and replay strips that envelope.
  - A handoff binds only when the CLI echoes its exact input UUID, so an earlier
    turn's completion cannot consume a queued spoken request.
- Joining voice observes any running Claude turn and speaks its later assistant
  messages through `thread/realtime/appendSpeech`; it never dispatches a
  replacement task. Explicit spoken requests use the handoff append/complete
  protocol, and leaving voice stops only that output route.
- Voice wording and named-goodbye recognition use optional
  `RC_CODEX_GATEWAY_USER_NAME`; no configured name means neutral wording.
  Outgoing third-party calls require that identity rather than guessing it.
- `voice/session/connected` from the owning client greets a user-started call
  once through `appendSpeech` (`voice_mode_greeting`); `VoiceSession.greeted`
  makes a repeated report a no-op. Agent calls keep their own
  `calls/connected` greeting.
- A user-started call passes `prompts/voice-mode.md` through
  `voice_mode_prompt`, appending only the configured user name, as the realtime `prompt`:
  speaking style, a delegation policy, and an ending policy: the voice answers
  a goodbye or hang-up request with a reply whose last sentence is "Bye!".
  `FarewellWatch::for_user` (`src/voice/farewell.rs`) arms on that sign-off when it
  answers a user line, and the gateway ends the call through the same
  `agentEnded` path as `end_voice_call` once the voice has been quiet for
  1.5 s, at most 10 s; any user speech cancels it. Agent calls keep Codex's
  default prompt plus their brief and have no farewell watch. Spoken requests
  get no gateway acknowledgement; the voice model acknowledges them itself.
- After 45–60 s without assistant text, the watchdog reports once that the task
  is still active, labelling any tool evidence as the last reported activity.
  It waits for real assistant output before another quiet-period notice.
- A bound turn missing from two executor snapshots fails its delegation, and an
  unconsumed handoff whose runtime has ended also fails visibly.
- `VoiceCoordinator` (`src/voice/session.rs`) owns the process-wide call as one
  phase: idle, starting (with its owner), active (owner and session) or
  draining (session), plus retiring transport identity awaiting closure.
  Every change goes through its transition operations, and
  an install is refused when the start was cleared meanwhile. Its `ShadowPool`
  (`src/voice/shadows.rs`) holds one ready shadow thread, one reservation and at
  most 8 stale threads awaiting deletion; shadows left unused at shutdown or on
  a failed start are deleted, not abandoned.
- A delegation buffers at most 8 KiB of streamed text before its next flush and
  reads at most 32 KiB of result aloud; a longer result is completed with a
  notice that points to the chat. A missing-turn failure applies only while the
  active delegation is still the exact bound turn the watchdog observed missing.
- `voice/session/stop` drains rather than drops. The session lives on for a
  short grace window, so the transcript-tail flush handoff can still record in
  the Claude thread how the call ended. Then a finalize task removes it.
- The gateway has one process-wide voice transport.
  - A user-initiated `voice/session/start` always replaces it. An automatic
    reconnect may reclaim only the same stable `realtimeSessionId`, so an older
    reconnect cannot steal a newer call. The latest admitted logical session
    keeps that authority across Idle; terminal closure revokes it. Admission of
    another explicit call supersedes all earlier ids without keeping a history.
    A fresh coordinator permits its first automatic recovery after a gateway
    restart, then retains only that admitted session's authority in memory.
  - The displaced client receives typed `voice/session/preempted`, and stale
    stop requests are idempotent no-ops.
- `end_voice_call` and the farewell close end a call terminally.
  - The gateway broadcasts typed `voice/session/agentEnded` before asking Codex
    to stop the transport, so it always precedes `thread/realtime/closed`.
  - It revokes reclaim authority for the `realtimeSessionId` and refuses an
    automatic reconnect (`replaceExistingSession=false`) of that id with the
    stable error text `voice call already ended by the agent`.
  - A user-initiated start that reuses the stable per-conversation session id
    renews its authority.
- Realtime errors with `terminal: false` are diagnostics: preserve the call
  and never retry its output. Missing `terminal` retains legacy terminal behavior.
  Every provider closure, including unknown or missing reasons, uses the same
  terminal-call fence before clearing the exact realtime thread. Only legacy
  `transport_closed` keeps automatic media recovery. `providerClosed: true`
  identifies an explicit provider receipt and forbids automatic reclaim even
  when its verbatim reason equals `requested`, `transport_closed` or `error`.
  An omitted flag preserves legacy behavior. A requested local stop
  retains its transcript-tail grace; a provider closure can end that drain.
  A start awaits its predecessor's actual `Closed` before installing or sending
  the successor: a stop RPC response acknowledges queue admission only. This
  also protects Codex replacements that reuse the same thread. Local `requested`
  or legacy `transport_closed` releases automatic reclaim; provider termination
  invalidates it. Explicit replacement waits for closure but may then start.
  `Error` never satisfies that receipt. Draining records an observed closure so
  later starts need no duplicate. Releasing the transition retires an uninstalled
  start and retains an unclosed predecessor in the bounded retiring phase.
  A retired predecessor cannot revoke a newer admitted logical session; an
  automatic retry of that newer admission still waits for the old transport's
  actual closure before installing.
  Control notifications never await that transition lock: its holder can be
  waiting for a control response. Persisted call closure matches both client
  and logical session, including after awaits.
- Every voice session writes
  `~/Library/Logs/remote-coder/voice-sessions/<started>-<realtime-thread>.jsonl`
  (`src/observability/voice.rs`). It holds both transcripts (`thread/realtime/transcript/done`),
  the full delegation lifecycle (requested, superseded, bound, append, complete
  and failed, with text and latency), turn boundaries and a closing summary.
  Evaluate past calls from this file first. The newest 100 sessions are
  retained.

## Text-provider fallback admission

`gateway::provider_fallback` owns new client text conversation selection before
provider dispatch: selected first-party provider/model, other first-party
harness (latest Opus or native Sol), then configured external provider. Clients
must use the returned exact thread and admitted model/effort for first dispatch.
Existing threads never migrate. Managed Claude is ineligible for restricted
Codex requests. Voice and internal starts keep their realtime/native contract.
`docs/provider-health.md` owns readiness evidence, effort adaptation and the
no-replay boundary. Keep this policy in the gateway rather than client retries.

Cluster identity belongs to `identity.rs`: the host UUID is stable, the ledger
incarnation fences job and receipt store epochs, and same-epoch backup restores
require `cluster reset-identity`. Membership and pinned links belong to
`cluster/`. Membership mutations require the local operator; every peer request
rechecks the retained membership, including on existing sockets. Cluster
credentials are journal-redacted.

`agents/jobs` remains the only job, intent, fence and result owner. The execution
driver owns native custody and local delivery; `cluster/driver.rs` owns network
reconciliation. Parent tags decide current placement, notification classification
and `message_agent parent`; immutable origin never grants authority. Delivery
with uncertain acceptance stays on its frozen receiver and identity until
reconciled. Thread headers expose the current nested parent address. The flat
parent thread ID is only a compatibility projection for local parents.

Use the sessions projection for native conversation inventory and resolution;
never add another transcript reader. An unavailable projection is not an empty
inventory. Native parent moves need no JobSpec; continuing unknown native
permissions fails closed.
