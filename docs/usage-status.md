# Subscription usage

Codex reports its managed runtime's native account observations. Claude account
inventory, subscription selection and reset redemption below require an
explicitly configured router. Without one, native Claude chat remains available
and router-only usage stays unavailable.

The drawer's floating header shows Claude and Codex usage rings in one glass
capsule, each for its selected subscription. Selection is independent of the
current chat or host. **All Accounts** in the
ring's account menu and Settings → Accounts show the complete
[account directory](provider-accounts.md), deduplicating matching Codex
subscriptions across hosts and matching Claude router account IDs. Hosts configured for the same router
share that inventory; its newest successful list replaces the Claude directory
wholesale, including membership, credentials and usage. The ring's outer arc is
always the **remaining** percentage of
the account's overall weekly limit. An inner arc shows the 5-hour limit's
remaining percentage only while that limit is on pace to run out before it
resets: less than 60% remains, and the average drain from the window's start
(reset minus five hours) to the sample's `observedAt`, projected forward, reaches
zero before the reset. Its color follows how early the projected run-out is,
sweeping hue from lime just before the reset through orange
to alert red at two hours or more ahead (`UsageRunOutWarning`); mixing colors
instead desaturates the middle of the range into mustard; VoiceOver states that lead time. The ring
carries no text: the provider's logo sits in its centre. Tapping it refreshes usage and opens a
compact popover: the provider's account selector, then each limit's
remaining percentage,
capacity bar and reset time. Text appears beyond that only when usage is stale
or the account is not ready. Model-specific limits remain in details and do not
replace the overall circle. All Accounts closes the popover before presenting
its sheet, so the two never stack.

The overview uses compact numeric summaries with explicit 5-hour and weekly
labels. Details use native capacity gauges, always in the same remaining
direction. Healthy values use the primary label color; low remaining values use
amber (11–25%, the `UsageLow` asset with dark and high-contrast variants) or red
(0–10%). Amber avoids reusing Claude's orange brand color for a warning. Details,
the overview and VoiceOver carry the exact numbers, so color never carries the
value alone. Stale samples use secondary styling, a dimmed logo and explicit
last-known or unavailable status. Missing summary windows use an em dash with
“Not reported” for VoiceOver, and a circle without any overall window is dashed
with a dimmed logo.

The logos are template vector assets (`ClaudeMark`, `CodexMark`) tinted in code
with each provider's brand color: Claude `#D97757`, Codex the
`#F4F6FF`→`#C4D3FF`→`#7A9DFF` gradient. The Claude path is from Simple Icons
16.32.0 (CC0-1.0); the Codex path is from Lobe Icons
(`@lobehub/icons-static-svg` 1.95.0, MIT, LobeHub). Each SVG records its source. Codex slots are classified by their reported window duration, never by
a primary/secondary assumption.

## Provider health

Each gateway reports every provider as `ready`, `fallback` (Codex turns run on
a gateway fallback route such as Copilot because the subscription path fails)
or `unavailable`, with a one-line reason unless ready, in `daemon/ready` and in
`gateway/providerHealth` whenever it changes. `ChatTargetModel.providerHealth`
holds the latest value for its host and the rings read the selected host's. A
gateway that reports nothing leaves health unknown, and the app shows nothing.
Replayed notifications never change it, because every connection's
`daemon/ready` carries the current value.

- A broken (`fallback` or `unavailable`) provider's ring dims its logo and adds
  a small warning badge. Its popover states the reason in one line, and
  VoiceOver reads the reason before the usage.
- The model picker keeps every model and marks the broken provider's with a
  warning symbol: every model of an unavailable provider, and during fallback
  only native Codex models, not those of an external `modelProvider`.
- One warning line below the composer's model controls covers the selected
  model. During fallback a new chat on a native Codex model reads "New chats
  run on Copilot": new Codex conversations start on the fallback route and stay
  there. An existing native Codex conversation keeps its subscription provider,
  so it shows the reason, and its turns fail until the subscription recovers.
  An unavailable provider shows the reason everywhere.
- While the preferred new-chat provider is unavailable, a new chat whose model
  was not chosen starts on a working provider's default model, and the warning
  line shows the unavailable provider's reason. When no working provider has a
  visible model, the default stays. Health changes re-resolve such a chat, so
  it returns once the provider recovers. Existing conversations never change
  provider, and the stored preference stays unchanged.
- A native request refused with `providerUnavailable` reads as its reason,
  including as a send error.

## Ownership and recovery

In router mode, Claude authentication and subscription selection belong to llm-router. The
gateway proxies its private accounts API using the shared router transport.
Five-hour and seven-day observations map to 300-minute and 10,080-minute usage
windows; utilization becomes used percentage, capped at 100. Missing windows
remain absent. The app derives staleness from `observedAt`: no observation or
one older than 15 minutes is stale, including while a displayed sample ages.
Native stream token/context observations remain canonical.

Tapping the Claude ring explicitly refreshes router usage. The selector lists
each account's label, plan, shared marker, remaining usage and availability.
**Automatic** follows the router's own choice and marks the account it picks;
choosing an account stores RemoteCoder's router preference, which both hosts
share and new Claude requests use immediately. The ring shows the preferred
account, or the automatic choice when there is none. A preference change uses
the most recent responding route, checking other hosts when it is unavailable.
A lost response triggers an immediate read to confirm the router's actual
preference; it never repeats the mutation. If that read fails or does not
confirm the requested preference, the error remains visible. Credentials,
availability and cooldowns come from the router.
`/health` starts no Claude process or quota probe, and unavailable usage is
never synthesized as zero.
See [Provider accounts](provider-accounts.md#claude-router-and-profile-migration).

## Usage resets

The gateway reports each subscription's reset count and offers separately from
usage windows. Unknown, unavailable and fetched-empty observations remain
distinct; counts come from the provider rather than the offer-list length.
Codex resets expire with its usage windows and are cleared from persisted cache
on gateway restart. Malformed reset data affects only that account's resets.

A redemption uses one idempotency key for the exact account and offer. The
gateway submits once; a known outcome remains known even if the follow-up
refresh fails. Only 504 `redeem_unconfirmed` means the gateway could not confirm
submission's outcome. Other gateway error responses are definite refusals.
After a timeout or connection loss following submission, retrying the same key
through either host is safe: configured routes use the same account owner and the
providers deduplicate by key. A fresh attempt uses a new key.

Codex redeems through the host default and refreshes its account after an
effective or unconfirmed outcome. Claude starts
a Claude-only router refresh after returning the outcome. Refresh completion
can lag the response; the gateway does not invent refilled usage.

The selected account's popover and Settings → Accounts show the provider's
available reset count alongside usage. The count is never derived from the offer
list: a provider may report only a count or cap its details. An unobserved
`resets: null` and an unavailable observation show no count. `offers: null`
means details are unknown; an empty list means details were read and no offers
were reported. A null offer expiry means it does not expire.

Each account's details list reset offers by title and expiry. Use asks for
confirmation naming that account and offer; stale samples, expired, depleted or
explicitly unusable offers cannot be used. Claude's router marks only its next
redeemable grant usable. Claude reset freshness comes from reset state and its
own `observedAt`, with observations older than 15 minutes stale; inference
credentials and inference usage timestamps do not gate reset eligibility.
Opening the overview or Claude details requests an interactive refresh; the
router owns provider-read throttling. Sign-in failures
name the account and ask for an agent to reconnect its router grant.

`AccountDirectory` owns Codex redemption and `ClaudeAccountDirectory` owns
Claude redemption, independently of account preference selection. Their
`AccountResetRedemptions` saves one unresolved attempt per subscription in a
device-local provider ledger before submission. It records the account name,
offer, idempotency key, gateway host and exact gateway account ID. Persisted and
submitted keys use the same lowercase UUID string. Retry keeps that exact host,
account, offer and key. Gateway route failover retains its mutation rule: fail over only when the
request provably never reached the gateway. Codex uses `default-codex`, including
retries restored from retired enrollment endpoints, without a refresh precheck.

Only gateway 504 `redeem_unconfirmed` or a possibly submitted transport failure
makes a fresh attempt unconfirmed. Other HTTP errors are definite refusals,
including `redeem_in_progress`, `redeem_unconfirmed_pending` and
`reset_account_changed`. An unconfirmed attempt offers Retry and blocks another
reset. A definitely refused retry keeps same-key Retry available and adds
Forget attempt. Account absence, reconnection and host configuration changes
cancel an in-flight call while retaining same-key Retry; they do not decide its
outcome. A retry to a missing account or host can then offer Forget.
Forget attempt removes the persisted attempt after confirmation that its original
outcome stays unknown. Orphaned attempts remain accessible in the overview until
forgotten; resolved presentation state is pruned with directory membership.

An in-flight attempt holds the platform's bounded background-execution assertion
and survives scene backgrounding. Termination, system execution expiry or
retirement of its own host cancels it without losing the saved key. Changes to
other hosts leave it running. A provider result never changes allowances
optimistically. Every outcome requests fresh usage; Codex refreshes only the
attempt's host, and Claude refresh waits for an active preference selection
without canceling it.

## Presentation and validation

Normal text sizes use fitted provider popovers. Accessibility sizes use a large,
scrollable sheet with stacked headings and values. Account summaries also stack
at accessibility text sizes. Rings have account-specific semantic labels,
bounded scaling, and reduced-motion-aware value changes.

For simulator UI checks requiring Keychain, build with normal simulator signing
(`CODE_SIGNING_ALLOWED=YES`, simulator identity `-`) through XcodeBuildMCP.
An unsigned test-host bundle installed standalone lacks the generated application
identity and can report Keychain -34018. Do not bypass credential storage or
hand-resign a copied app to mask that failure. The test runner’s unsigned unit
suite is a different execution path from the signed standalone app.

Build/test source and receipts are owned by `scripts/remote-build.py`. Keep
source mirrors and DerivedData under their worktree lease; only one installer
owns the physical device. Disk-space admission failures require restoring actual
free space, not weakening the gateway’s 2 GiB upload reserve.
