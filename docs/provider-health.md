# Provider health

The app keeps working as long as one provider works. A gateway whose Codex
app-server is down, starting, recovering interrupted turns or signed out still
serves Claude chats, history, settings and every other gateway-owned request,
and tells the client which provider is broken and why.

## Health value

`src/gateway/provider_health.rs` owns one value. It reaches every client in the
`daemon/ready` params and, whenever it changes, as `gateway/providerHealth`
(`protocol-fixtures/providers/provider-health.json`):

```json
{"providers": {
  "codex":  {"state": "ready" | "fallback" | "unavailable", "reason": "…", "fallback": "copilot"},
  "claude": {"state": "ready" | "unavailable", "reason": "…"}
}}
```

- `reason` names the cause in one short sentence and is present unless the
  state is `ready`. It never describes the remedy; the app words that itself.
- `fallback` is the external provider id and appears only with `fallback`.
- Codex is `unavailable` while the app-server is not running (`Codex
  app-server is not running`) and from its connection until restart recovery
  finishes (`Codex is starting`, or `Codex is waiting for its subscription
  sign-in to resume interrupted work` while recovery waits for sign-in). Once
  ready it is `fallback` while the subscription token is missing or expired
  and an external provider is configured, `unavailable` with the same reason
  without one, and `ready` otherwise.
- Claude is `unavailable` when it is turned off on the gateway or its last
  preflight failed. It is absent until the first preflight, and a gateway that
  sends no `providers` at all is an older one. Absence means unknown, never
  ready.
- The notification is not stored in replay history; `daemon/ready` carries the
  current value, and the ready frame and later changes are ordered under the
  same lock, so a client never misses or reorders a change.

## Connections without Codex

- A client is refused only while the gateway drains for a planned restart,
  with 4012. Otherwise it is accepted even when Codex control is not ready, a
  recovery journal is pending, or its own app-server connection fails.
- Such a connection has no Codex upstream. The gateway answers `initialize`
  with an empty result, drops `initialized` and responses to server requests,
  and answers every other native request with `-32003` and
  `data: {kind: "providerUnavailable", retryable, provider: "codex", reason}`
  (`protocol-fixtures/errors/provider-unavailable.json`). `retryable` is true
  while Codex is not running, starting or unreachable from this connection,
  and false while recovery waits for sign-in. The reason is read from the live
  control state, so a dropped control connection reports `Codex app-server is
  not running` at once.
- When Codex control becomes ready, the gateway closes every such connection
  with 4012 so the app reconnects through the ordinary path and gets a full
  connection. A connection whose own app-server connect failed while control
  was ready retries the connect after 5 s, doubling to 30 s, for as long as it
  stays open, and closes with 4012 on the first success. There is no in-place
  upstream attach.
- New Codex work (requests that need admission) on any connection waits for
  Codex control to be ready, which happens only after restart recovery has
  resumed the exact interrupted turns. Until then it fails with the same
  `providerUnavailable` error. Gateway-owned handlers that need the control
  connection while none exists fail the same way instead of hanging.

## Copilot fallback

- While the recovery journal has pending tasks, Codex readiness waits up to
  2 minutes for sign-in, retrying every 5 s, so interrupted turns resume
  signed in rather than into a certain auth failure. After that, recovery runs
  anyway: interrupted native turns fail visibly with Codex's sign-in error and
  Codex becomes ready with the fallback, so pending work on fallback threads
  waits at most that long. With nothing pending, a failed router token
  issue is recorded in the generation's auth state, Codex becomes ready, and
  the renewal loop retries every 30 seconds until a token is installed.
- The first provider in the operator's external providers file is the
  fallback, and its first listed model is the default fallback model.
- `ExternalProviders::map_onto_fallback` is the one owner of the
  native-to-fallback mapping. A native model is one no external provider
  lists. It becomes the fallback model whose slug ends in `/<model>`, and
  service tiers are always dropped.
- While the subscription is failing, a client-originated `thread/start` on the
  native provider moves to the fallback: `modelProvider` becomes the fallback
  id and an unmatched native model becomes the default fallback model. The
  external provider admission then injects its provider definition and
  catalog as for any external start.
- Clients keep sending the model and tier they selected on every send. On a
  thread of the fallback provider, `thread/resume`, `thread/fork`,
  `turn/start` and settings updates apply the same mapping; an unmatched
  native `model` is dropped, so the thread keeps its stored model. An
  unmatched native `collaborationMode.settings.model` cannot be dropped, as
  that field is required, and still fails. An explicit fallback model, or a
  model of another external provider, keeps the ordinary external checks.
  Threads of other external providers keep the strict checks too.
- **Copilot conversations stay Copilot.** A conversation started on the
  fallback keeps that provider after the subscription recovers, and existing
  subscription conversations never move to the fallback. Codex fixes a
  thread's provider when it starts or resumes it: only `thread/start`,
  `thread/resume` and `thread/fork` take `modelProvider`, a resume persists
  it, and a resume override is ignored on a thread that is loaded with
  subscribers. Switching providers per turn would therefore be unreliable and
  would rewrite stored state. While the subscription fails, an existing
  subscription conversation is not refused by the gateway; its turn fails with
  Codex's own sign-in error and the app shows the health reason.
- Gateway-internal starts, such as the voice shadow thread, never move to the
  fallback.
- Without an external providers file there is no fallback: Codex reports
  `unavailable`, and the gateway refuses identity-gated Codex work as before.

## Known gaps

- Claude `ready` in router mode proves only that the router key file is
  readable (`providers/claude/auth.rs`). A router-side Claude outage still
  reports `ready`; its turns fail with the router's error.
