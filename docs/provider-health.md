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
  "claude": {"state": "ready" | "fallback" | "unavailable", "reason": "…", "fallback": "codex"}
}}
```

- `reason` names the cause in one short sentence and is present unless the
  state is `ready`. It never describes the remedy; the app words that itself.
- `fallback` names the other first-party harness or an external provider and
  appears only with `fallback`. It describes admission for capable clients;
  older clients and restricted requests keep their applicable eligibility rules.
- Codex is `unavailable` while control is disconnected, starting or awaiting
  recovery sign-in, retaining the state-specific reason. Unknown authentication
  evidence is unavailable and never authorizes fallback. Router-backed auth
  reads the installed token; native auth reads generation-fenced `account/read`
  evidence refreshed in the background. A definitive sign-out advertises an
  eligible fallback, or remains unavailable when none exists.
- Claude requires its executable, supervisor and cached authentication preflight.
  Disabled or definitively unavailable Claude advertises an eligible fallback.
  Unchecked readiness is unavailable with an unknown reason. A gateway sending
  no `providers` is older; absence means unknown, never ready.
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

## Conversation admission and fallback

New text conversations from clients sending `acceptProviderFallback: true`
try the selected provider and model first. Older clients retain external-only
fallback because they do not adopt cross-harness settings. When its
control/authentication readiness is unavailable, admission chooses the other
first-party harness: Codex requests use Claude Code's `opus` alias (latest
Opus), and Claude requests use the newest native Sol from `model/list`.
Only when both first-party paths are unavailable does admission choose the
first configured external provider. Native model names map to matching external
models; otherwise its first model is the default. Explicit external
selections retain their provider. Voice keeps its signed-in realtime path.

`Gateway::admit_new_conversation` owns this decision before provider dispatch.
It uses the provider-health owner's control/authentication evidence; unknown
or transient native readiness fails retryably rather than changing harness. Claude eligibility also requires its
executable, supervisor and authentication preflight. These checks establish
local readiness, not provider reachability or available quota. An accepted
start or prompt is never replayed on another harness after an ambiguous or
provider-side failure.

The returned thread ID, model, provider and effort are the admitted settings.
Clients use them for the first turn and persist them for later turns. Existing
conversations keep their exact harness/provider; no history or prompt transfer
occurs. Existing native or Claude conversations report unavailability when
their provider is unavailable. Existing external conversations keep running
on that provider. This avoids a second conversation identity or duplicated
side effects; adding transfer later would require an explicit continuation
contract rather than extending admission.

A cross-harness admission drops provider-specific model/config/tier/cyber
settings and adapts the requested reasoning effort to the target's advertised
levels. Unsupported effort uses the highest supported level, as with Copilot. Managed Claude runs with
full access, so a restricted Codex request cannot move to it; its original
permissions remain enforceable on Codex/Copilot. A missing working directory
still fails the Claude contract rather than inventing one.

`ExternalProviders::map_onto_fallback` owns native model selections on external
fallback threads. A native model is one no external provider lists. It becomes
the fallback model whose slug ends in `/<model>`, and tiers are dropped. An
unmatched native selection on an existing fallback thread retains that thread's
model, read from its authoritative header. External fallback effort is checked
against the effective model's advertised levels: supported effort stays;
unsupported effort becomes its highest supported level. A model without
reasoning support has no config override. Collaboration mode determines the
effective model when present. Model/provider ownership checks stay strict.

Codex control recovery still waits up to two minutes for subscription sign-in
before settling interrupted native work and allowing new native/fallback
admission. A fresh Claude admission does not need Codex control. Existing
subscription conversations never move into external providers. Gateway-internal
starts, including voice shadow threads, never use text fallback admission.

## Known gaps

- Native Claude preflight errors are cached as unavailable until its next check,
  including transient CLI failures. New opted-in conversations can use Sol during
  that interval; admitted threads remain pinned.

- Claude `ready` in router mode proves only that the router key file is
  readable (`providers/claude/auth.rs`). A router-side Claude outage still
  reports `ready`; its turns fail with the router's error.
