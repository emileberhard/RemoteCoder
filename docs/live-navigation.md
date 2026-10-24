# Agent Live Navigation

RemoteCoder provides a bounded, agent-facing live-location session. The gateway
issues a location push, the iPhone authenticates encrypted event uploads, and an
agent consumes location/guidance events through JSON-RPC or the CLI.

## Tracer flow

1. The iPhone app performs one foreground setup: Google Navigation terms,
   then Always + Precise Core Location, and `startMonitoringLocationPushes` token
   registration; the app then registers the device, location token included,
   with every configured host. After that, every app activation re-requests the
   token and re-reads authorization and accuracy
   (`LiveNavigationSetupController.refreshRegistration`), so an upgrade, a
   rotated or invalidated token and a permission change re-register without
   another setup. Completed setup implies accepted Google terms, so activation
   never touches the Navigation SDK. A device that lost Always or Precise
   registers `setupReady: false`, and `navigation/start` names what is missing.

2. `navigation/start` creates a six-hour in-memory session. Destination is
   optional; travel mode is required.
3. The gateway sends the command through the configured authenticated
   `/v1/internal/location` broker route and APNs topic
   `<your-bundle-id>.location-query`.
4. `RemoteCoderLocationPushService` validates and stores the command, takes one
   Core Location fix, and uploads a `bootstrap` event.
5. A Darwin notification lets an already-running containing app adopt the
   stored command without polling. The extension does not hand off to a
   suspended or terminated app (Apple's LPSE guide suggests letting the
   extension's `liveUpdates` wake the app; this is not adopted), so such an app
   adopts the stored command when it next launches or comes to the foreground. `LiveNavigationCoordinator` then restores the command, starts
   continuous Core Location, and creates one independent `GMSNavigationSession`
   for road-snapped locations and optional guidance. It holds its Always
   `CLServiceSession` only while that session runs.
6. Agents long-poll `navigation/next`, or use `dev-tools/live-navigation watch`
   for JSONL.

The cold extension-to-containing-app transition is the tracer gate. A bootstrap
event proves LPSE wake and one-shot location only. Continuous guidance is not
claimed until a subsequent app-produced location/road/guidance event arrives.
On 23 October 2026 the iPhone answered a push with a 9.5 m bootstrap fix while
the app was suspended, sent nothing more for three minutes, and streamed
road-snapped fixes from the moment the app came to the foreground. A session
for continuous tracking therefore needs the app opened once when it is not
already running.

`navigation/start` with `singleFix: true` asks for that one bootstrap fix only.
The command carries `singleFix`, so the extension neither stores nor announces
it: a running app cannot adopt it and a later launch cannot resume it. The
gateway records the stop with the session's first event. A single fix takes no
destination.
`dev-tools/live-navigation fix` waits for it and prints its location. Apple
allows roughly 360 location pushes a day per device, replenished one every few
minutes, so poll with a session rather than repeated fixes.

## Build configuration

Navigation is optional. Basic chat compiles and runs without a Maps key;
navigation UI remains unavailable until one is configured. Supply your own
Google Maps key restricted to your signed app's bundle ID, with Maps SDK for
iOS and Navigation SDK enabled. Server-side Routes/Places use a separate key.

Runtime keys stay in ignored local configuration or private deployment inputs.
They must not enter the public tree. See [self-hosting](self-hosting.md) for the
bundle namespace and [the private deployment entrypoint](https://github.com/emileberhard/RemoteCoder-deploy/blob/main/AGENTS.md)
for maintainer installation and release verification.

Setup presents Google's terms before requesting Core Location authorization,
so the two consent dialogs do not compete.

## Setup lifecycle and telemetry

Only setup, the Settings Licenses page and a navigation session touch the
Navigation SDK. When 3.66.8 read the Google terms on every activation, each
activation was followed by one to two minutes of SDK network requests wrapped
in UIKit background tasks, 15,000 to 100,000 of them per ten minutes of use.
Keep SDK calls out of launch, activation and the main Settings view. The Licenses page reads the SDK version and license text in its
view task, on the main actor outside view rendering, as the SDK requires. On
14 September 2026, symbolicated MetricKit watchdog
reports proved a deadlock when a computed view getter called
`areTermsAndConditionsAccepted`: SwiftUI held its render lock while Google's
initialization waited for a worker whose UserDefaults notification needed that
same lock. Do not reintroduce SDK calls into view getters.

Setup uses Core Location's native async token request and awaits disconnection
of its temporary gateway client in `defer`. The `LiveNavigationSetup` OSLog
category records token request, receipt (byte count only), registration, and
errors. The existing app-log exporter uploads those records and MetricKit
diagnostics to the gateway; see [host observability](host-observability.md).

## Trust boundary

- The location-push token is stored on each gateway the device registers with.
- The APNs broker accepts only an authenticated RemoteCoder caller, the exact
  RemoteCoder bundle id, and push type `location`.
- Each session has an independent random bearer upload token and X25519 key.
- The iPhone generates an ephemeral X25519 key for each event, derives a
  ChaCha20-Poly1305 key through HKDF-SHA256, and encrypts the event body.
- The outer session id and monotonically increasing sequence are authenticated
  again inside the sealed payload.
- The app serializes uploads through a bounded queue. Retrying the most recently
  accepted sequence is idempotent, so a lost HTTP response cannot wedge the
  stream or duplicate the event.
- The app and extension coordinate their shared command/progress file with
  in-process and cross-process locks; progress from an old session cannot
  overwrite a newer command.
- Google maneuver and road-snapped detail is kept only in the active in-memory
  gateway session. Sessions retain at most 512 events and 512 KiB of them,
  and expire after six hours; expiry is derived when a session is read, so a
  read reports `expired` rather than `active`. The gateway holds at most 16
  sessions and refuses a start at that limit, evicting only expired or
  stopped ones. When events were evicted before a reader saw them, `next`
  reports `droppedThroughSequence`. A session that already delivered an
  event survives a broker failure that arrives afterwards.

## RPC

- `navigation/start`
- `navigation/status`
- `navigation/next`
- `navigation/stop`

The location token and the start inputs (`eventBaseUrl`, `setupReady`,
`authorization`, `fullAccuracy`, `googleTermsAccepted`) travel in the
`tokens.location` entry of `devices/register`; `navigation/start` reads them
from the most recently registered device holding a location token, ready or
not; preparing a second device therefore lets whichever registered last
receive the pushes. The app
sends it through `devices/register` to every host (`PushTokenSources` supplies
the credentials), not only the active one. The app stores the token locally under
`pushDevice.location` and refreshes it on every activation once setup has run;
the registration only goes out when the token or its inputs changed. `eventBaseUrl`
is the gateway's Serde camel-case spelling. The Swift property `eventBaseURL` has
an explicit coding key; synthesized Swift encoding otherwise causes registration
to fail.

`navigation/start.destination` is nullable. A destinationless session still
streams speed, course, raw fixes, and road-snapped fixes, making it suitable for
a free-roaming tour companion.
