# Fleet Live Activity

Decision for [tracker #683](https://github.com/emileberhard/tracker/issues/683).

## Outcome and constraints

The configured machines form one agent platform. One active-tasks Live Activity
shows its running root conversations and unread completions, with exact
host-and-thread links. Voice-call activities retain their separate lifecycle.
Updates must continue while iOS suspends the app. An unavailable host never
becomes an empty host, and it must not prevent healthy hosts from updating.
Existing released clients must continue working during rollout.

## Ownership

The workspace owns one activity service. It chooses one connected, capable
gateway when starting an activity, preferring the existing automations authority
as the available always-on host. That coordinator stays fixed for the activity's
lifetime. Only it receives the activity token; every other device registration
omits it. Foreground failover ends the old activity before creating a fresh
activity and token. This avoids distributed elections and competing APNs clocks.

The coordinator persists the registration's exact declared host UUID set. This
set follows the device's configured hosts, not the coordinator's entire cluster.
Rows carry their authoritative host UUID; thread IDs alone are not unique.

Each cluster member shares only its local authoritative activity snapshot over
the existing authenticated cluster link. A small sender owned by the existing
cluster driver's structured lifetime watches local changes, peer reachability
and membership. It is independent of delegated-job backoff and sends only changed
or unsent current state. No polling subsystem or broker-specific merge is added.
Peer identity comes from the authenticated grant; payloads cannot select another
host. A versioned capability gates the new report protocol.

The existing push aggregation owner is adapted rather than wrapped in a second
aggregator. Local-only snapshots remain available to older clients. Fleet merges
sum counts and select the latest three attention rows across the declared hosts.
Sort ties use host and thread identity. Peer reports never contain fleet merges,
so data cannot circulate and double count.

## Availability, ordering and lifecycle

Fresh local projections and current peer reports certify known state. Restored,
unreachable or explicitly unavailable sources retain their last known content
with incomplete coverage; a source never observed remains unknown. Healthy
sources continue updating the single card. Incomplete coverage is visible and
counts do not claim completeness. End requires every declared source to be
current and empty. Unsupported or unjoined configured hosts remain explicitly
unavailable rather than silently disappearing from the fleet.

Source report ordering must survive normal restarts and reject a late older
report without relying solely on clocks being synchronized. The existing
persisted owner should retain the ordering evidence it needs. A coordinator
serializes content publication, timestamp assignment and APNs delivery. Token
rotation, invalidation, retained state and tasks keep their existing owners and
bounds. Network calls do not hold the device registry's storage lock.

Old per-host activities on this device are retired when the unified service
starts. The compatibility path for older installed clients keeps their token
kind local-only; new fleet registrations are explicitly distinguished. A new
app must tolerate gateways not yet upgraded, rather than requiring release order.
Remove obsolete app host-scope helpers, per-target activity effects and account
aggregation machinery when their callers disappear; retain only compatibility
required by supported installed versions.

## Alternatives and assumptions

An app-only merge cannot update while suspended. Giving every gateway the same
token would let one host overwrite or end another's work. Polling duplicates
existing event and reachability signals. Broker-side merging would require every
host to use one broker, contrary to the supported per-host broker contract.

The automations authority is the existing preference for an always-on host. If
that role later diverges, revise the preference at its owning boundary. If the
chosen coordinator becomes unavailable while the phone is suspended, the card
becomes stale until that host recovers or foreground failover creates a new one.
Background coordinator failover would require additional ownership machinery;
it is outside this change.

## Evidence and verification

An independent Opus architecture challenge confirmed the push-based cluster
reuse and one coordinator per token before implementation. The lead retained
explicit coverage for every configured host and restart-safe source ordering.

Current Apple guidance: [Live Activities HIG](https://developer.apple.com/design/human-interface-guidelines/live-activities),
[ActivityKit push updates](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications)
and [ActivityKit lifecycle](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities).
Apple recommends one activity for multiple events and updates only when content
changes. The payload remains within ActivityKit's 4 KiB limit.

Verify exact row links, device-specific host sets, certified-empty End, unavailable
and restored sources, stale/reordered reports, token rotation, legacy clients and
the single app activity. Run targeted native Swift and gateway tests, affected
app/extension compilation, and an isolated multi-gateway smoke test through real
RPC and broker boundaries before deploying. Inspect the widget on the test device.
