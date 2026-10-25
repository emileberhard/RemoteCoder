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
  finishes (`Codex is starting`). Once ready it is `fallback` while the
  subscription token is missing or expired and an external provider is
  configured, `unavailable` with the same reason without one, and `ready`
  otherwise.
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
  `data: {kind: "providerUnavailable", retryable: false, provider: "codex",
  reason}` (`protocol-fixtures/errors/provider-unavailable.json`).
- When Codex control becomes ready, the gateway closes every such connection
  with 4012 so the app reconnects through the ordinary path and gets a full
  connection. There is no in-place upstream attach.
- New Codex work (requests that need admission) on any connection waits for
  Codex control to be ready, which happens only after restart recovery has
  resumed the exact interrupted turns. Until then it fails with the same
  `providerUnavailable` error. Gateway-owned handlers that need the control
  connection while none exists fail the same way instead of hanging.

## Copilot fallback

- Codex sign-in no longer gates readiness. A failed router token issue is
  recorded in the generation's auth state, and the renewal loop retries every
  30 seconds until a token is installed.
- The first provider in the operator's external providers file is the
  fallback, and its first listed model is the default fallback model.
- While the subscription is failing, a client-originated `thread/start` on the
  native provider moves to the fallback: `modelProvider` becomes the fallback
  id, the model becomes the fallback model whose slug equals the requested
  model or ends in `/<requested>`, otherwise the default fallback model, and
  service tiers are dropped. The external provider admission then injects its
  provider definition and catalog as for any external start.
- Clients keep sending the model they selected on every turn. On a fallback
  thread, a `turn/start` or settings update that names a native model maps it
  to the fallback model whose slug ends in `/<model>` and drops its service
  tier. An explicit fallback model keeps the ordinary external checks.
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
