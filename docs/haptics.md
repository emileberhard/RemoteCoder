# Haptics and press previews

RemoteCoder has one semantic vocabulary with **Standard** and **Strong** recipes.
Strong is the default, including for existing installs without a saved strength;
an existing App haptics opt-out is preserved. It increases everyday contact,
uses firmer slider detents and adds two short, gesture-owned lift/seating accents.
Standard keeps the earlier impact strengths and system selection ticks. Neither
profile changes the meaning of success, warning or error. There is no audio click
track, haptic library dependency, background rumble or perpetual keep-warm timer.

## Native SwiftUI control rule

Use `AppMenu` for native menu triggers. It embeds the real SwiftUI `Menu`, its
button menu style and the shared tactile button style. Use `trigger: .icon` for
icon-only menus; the default is labeled. The primary-action initializer is only
for a real tap action (for example, New Conversation); it preserves native hold
and menu tracking, not a dummy action to produce feedback. Parent/caller plain
button styling cannot silently replace the wrapper's internal tactile style.

Ordinary buttons use `.appButtonFeedback()` / `.appIconButtonFeedback()` or the
existing semantic `ResponsiveButtonStyle`. UIKit-backed controls can share
`.appPressFeedback(event, isPressed:)` without adding another gesture recognizer.

Native glass buttons use `.buttonStyle(.appGlass)` and acknowledge activation
while keeping system glass animation and tracking. When the action already owns
its acknowledgement, use `.appGlassActionFeedback` explicitly: removal reports
its accepted result, Scroll to latest reports disclosure, and neither also emits
an extra activation pulse. This is an ownership choice, not a second glass look.

Native picker and settings-tab **input bindings** use
`.nativeSelectionFeedback()`. Strong adds one selection acknowledgement only
when a new user value is accepted; Standard leaves the native feedback alone.
Programmatic restores, normalized/rejected writes, repeated values and remote
updates stay silent. This supplements, rather than disables or scales, any
system feedback. Native switches keep their native treatment; the custom Fast
mode toggle already owns its on/off recipes.

`scripts/lint-haptics` rejects raw `Menu` outside `UI/DesignSystem/AppMenu.swift` and
raw haptic generators/recipes or sensory modifiers outside `Core/Haptics`. It
runs with install-dev, local device installs, verify and the release gate. It is a
source guard, not a Swift compiler plugin; intentional native-control exceptions
must be implemented at the owning component rather than bypassed at call sites.

## Platform contract

Use `HapticEvent.recipe(for:)` as the only pattern/intensity catalog. The same
`HapticRecipe` maps to SwiftUI sensory feedback for ordinary controls and UIKit
for prepared gesture ticks. `HapticAccent` owns the two custom patterns. The newer
`SensoryFeedback.press`, `release`, and typed `selection` members are callable from
iOS code but their individual Apple documentation specifies **visionOS-only
playback**. They are not iPhone replacements for impact/selection feedback.
`start` and `stop` similarly play only on watchOS. Do not infer physical support
from a symbol's availability annotation.

The iPhone catalog maps button/icon compression to light impacts, toggle states
to rigid/soft impacts, and slider boundaries to distinct rigid impacts. Ordinary
selection uses `.selection`; Standard slider steps do too, while Strong uses a
modest rigid impact. Local acceptance becomes a medium impact under Strong.
Actual outcomes retain `.success`, `.warning`, or `.error`. Tunable strengths live
in the catalog, not views. Intensity parameters are not calibrated percentages
of perceived force; test the actual device/case/grip.

References:
- [Apple: Playing haptics](https://developer.apple.com/design/human-interface-guidelines/playing-haptics)
- [SwiftUI sensory feedback](https://developer.apple.com/documentation/swiftui/sensoryfeedback)
- [Press button playback limitation](https://developer.apple.com/documentation/swiftui/sensoryfeedback/pressfeedback/button)
- [Slider release playback limitation](https://developer.apple.com/documentation/swiftui/sensoryfeedback/releasefeedback/slider)
- [Typed selection playback limitation](https://developer.apple.com/documentation/swiftui/sensoryfeedback/selectionfeedback/on)
- [Native context-menu previews](https://developer.apple.com/documentation/swiftui/view/contextmenu(menuitems:preview:))

## Ownership and timing

`ResponsiveButtonStyle` observes the native button's press state. It supplies
a short 75 ms press-in, a spring return, and a rising-edge haptic without adding
a competing tap or drag recognizer. Reduce Motion removes custom compression, not meaningful feedback.
Native menus, pickers, switches, camera and system call UI keep their own behavior.
Explicit actions in native-styled forms can acknowledge activation without
replacing their visual style.

Selection happens at an actual user choice, not at touch-down. Directory
selection follows successful path resolution; host chips acknowledge the accepted
host change. An already-selected
custom row can acknowledge a press, but never reports a second selection change.
Selecting an answer produces one selection tick; automatic question advancement
is silent. Manual page changes and folder disclosures have their own quiet
acknowledgement. The conversation drawer acknowledges finger lift after a
horizontal drag through the shared gesture-feedback modifier in the same update.
This includes a slow drag released at the endpoint. Touch-down, settle
completion, and programmatically moving the drawer emit no additional pulse.
Dynamic composer recovery buttons reserve their actual bounds from empty-space
focus, just like the always-visible controls. Keyboard focus, typing, scrolling, streamed
text/tool events, upload percentages and usage updates stay silent.

Send deliberately has two meanings: touch-down confirms the button was pressed;
`dispatch` confirms that the message was persisted locally. Keyboard submission
uses the same local-acceptance path. Neither signal claims remote acceptance or
completion. Copy feedback follows the clipboard write on every explicit copy,
including repeated copies while the checkmark is already visible.

`HapticService` owns the app preference, hardware/foreground/audio policy and
bounded occurrence deduplication. A tiny `HapticOutput` under the app root observes
semantic pulses; the transcript and control trees do not observe that stream.
This output survives an accepted action dismissing a sheet or replacing a card.
Pulses capture their strength, expire after 200 ms, and are discarded, never
queued for a later foreground or post-recording replay. Changing strength or
turning feedback off invalidates any pending pulse. This is a stale-event cutoff, not a hardware latency
claim. No file loading, custom-engine start, network request, background task or
keep-warm timer occurs on this dispatch path.

Async model actions capture `feedbackForCurrentConversation()` before suspending.
That callback requires the same host model, conversation, presentation, visibility
generation and scene generation, and rejects retired owners. Attachments also
require the original draft. A mixed image/video selection shares one aggregate
staging outcome; a later upload failure is distinct and emitted once per batch.

Live and replayed turn completions share `reportTurnFeedback`.
It deduplicates host-qualified normalized turn identities independently of runtime
retirement, so either delivery order produces at most one eligible result. Only a
known completed turn emits success; failures emit error; interrupted/unknown
outcomes never become success. Replays and hidden-owner occurrences are consumed
silently. Other-thread notification alerts remain system-owned, so the app does
not add a competing arrival vibration. Banners preserve the actual result rather
than labeling every terminal state successful.

## Hold, peek and open

`ReasoningGaugePosition` maps the enabled explicit efforts evenly from **25%**
to **100%**, so the lowest effort never looks like zero. The needle, filled arc,
and picker-to-gauge transition share this mapping. A single enabled effort is
also the maximum and stays at 100%; Automatic retains its full arc and A label.
This display mapping does not change slider detents or distance-based tick counts.

The gauge reports the visible arc-and-stroke bounds, including its open bottom,
rather than the full construction circle. It and the Fast bolt share one scaled
symbol height and centered touch targets; the floating picker reuses those exact
glyph bounds when returning to the composer.

The reasoning control retains its public UIKit short-tap/long-press bridge. A hold
lifts the slider; moving across discrete levels produces detents, with stronger
endpoints and no repeated boundary buzz. `ReasoningDetents` uses a directional
10%-of-step dead band around each midpoint, so boundary jitter changes neither
selection nor feedback. Large moves still go directly to their destination;
right-to-left layout and endpoints retain their existing meaning.

The final touch location updates selection without requesting a second detent:
release owns that final contact. A changed selection is committed once. A
successful hold/drag can still acknowledge release without changing the value;
vertical cancellation, replacement, resize and preview restoration are silent.
Normal tap opens the same slider for a second touch. After the picker returns,
the gauge animates to the accepted value with **two ticks per visible reasoning
step**, at least two for a changed selection. X-High → High is two, X-High → Medium
is four, and X-High → Low is six when those levels are visible. Count is based on
start-to-final distance, not back-and-forth travel during the gesture. Automatic
is the first visible detent; hidden levels do not count. Unchanged/cancelled
selections do not start a gauge-adjustment sequence.

`ReasoningGaugeFeedback` captures the distance when the value is accepted. Its
first tick accompanies the start of motion; subsequent ticks slow down slightly.
Small changes retain a 300 ms spring. Larger jumps extend the shared motion/tick
timeline rather than compressing clicks together (six ticks: 430 ms animation;
twelve ticks: 850 ms). There is no added delay after the picker returns and no
extra seating pulse at animation completion. Strong and Standard use their
existing central slider-step recipes through the prepared player.
The view's task is keyed to the accepted change; new contact, replacement,
disappearance and lifecycle changes cancel old feedback. Deadlines are absolute
from animation start; a tick more than 40 ms late drops the rest of the sequence
rather than producing a catch-up burst. The finite playback task releases the
player without changing the saved selection. An immediate animation completion
(for example, Automatic and the top effort sharing the same gauge fraction)
cannot truncate the ticks. Reduce Motion keeps one seating acknowledgement
and the state change without the animated tick sequence.

### Geometry is not cancellation after acceptance

Only a still-tracking reasoning picker is cancelled by changes to the settings
row's global frame. Once a value is accepted, the needle animation and
its ticks survive composer reflow. Settings synchronize silently in the
background and do not resize the composer. A warning or error can still appear below the
controls. That moves the row without changing its
owner or accepted selection; it must not erase `gaugeChange` or release the
prepared haptic player. Draft conversations do not take that synchronization path.
Actual context loss (new contact, a changed model/value, disappearing control,
or inactive scene) retains its cancellation behavior.

`ReasoningControlLifecycleTests` mounts just the production control with local
bindings and a recording haptic player. It covers chat identity changes,
repeated changes within the same control with and without synchronization
status, status insertion/removal around acceptance, and cancellation of a live
gesture or an old settling owner. No gateway, UI-automation runner or physical
haptics is used.

### Prepared gesture playback

`HapticService` owns at most one active gesture and one finite finishing accent,
qualified by the originating control UUID. A new owner cancels the previous one;
a late completion/cancel for another owner cannot touch the new player. Native
impact/selection generators are allocated/prepared at contact, reused through
that gesture, and re-prepared after ticks. Requests go directly to the prepared
player rather than through a single SwiftUI latest-value pulse. No tick backlog
is accumulated and the final detent/release pair is not blindly layered.

Strong also prepares a haptics-only Core Haptics engine and two cached players.
Startup is asynchronous. If an accent is not ready at its event, a native recipe
plays immediately instead; startup never replays it later. The lift has a 35 ms
rounded onset followed by a crisp transient; seating is a contact plus a fading
65 ms tail (75 ms total). A new gesture event stops the previous accent. Custom
patterns replace, not accompany, the corresponding native impact.

The engine belongs to this interaction, not each tick. Stop/reset/start callbacks
are generation-checked. Reset reconstructs players only for an eligible owner;
a stopped/failed engine leaves native feedback available. Normal completion lets
the finite accent finish before releasing its engine. Cancellation, app opt-out,
strength changes, capture start, call activation and leaving the active scene
stop prepared/finishing playback. No audio-session category, recording allowance
or route is changed by this layer. There is no global prepared-state timer.
Preparation and API-request instrumentation do not prove actuator latency.

Directory rows, conversation rows, the usage ring, and the pending-question bar
offer native context-menu previews and explicit Open/Choose/Answer actions. Message previews remain native. Lift shapes follow the capsule,
circle or rounded row rather than a rectangular screenshot. Ordinary taps retain
their previous behavior. This is modern touch-and-hold interaction, **not pressure
sensing or a restoration of 3D Touch hardware**. Native menus own their lift
feedback; no extra recognizer or blanket preview-arrival vibration is installed.

Working-folder headers instead use the custom hold/slide/release palette in
[`directory-quick-switch.md`](directory-quick-switch.md). The original UIKit touch
owns tracking; contact, lift, hover and acceptance use this same haptic catalog.
Normal tap remains the full directory browser, including for assistive input.

The chat header's New chat button shares that `TapHoldButton` touch owner. Contact
plays `iconPress`; a tap starts a new chat. A recognized hold cancels the tap and
starts the new chat in the host's home folder, with one `commit` and a symbol
bounce (none under Reduce Motion). Release plays nothing further.

Composer Stop and Voice Mode use `SlideToConfirmButton`. Contact plays `iconPress`
and reveals the guide, which stays only while the finger is down. Reaching full
travel plays one `sliderMaximum`, and a confirmed release or upward flick plays
`commit` before the action. A tap, disarming and cancelling are silent.

## Audio and settings

Settings → Chat → Touch feedback controls **App haptics** and **Feedback strength**.
**Try feedback** opens a comparison page with the production button, native-menu,
reasoning-slider and glass-acceptance components. Its selections and acceptance
counter are local samples: it sends no requests, imports nothing and does not
write the clipboard or conversation settings. Choosing Standard/Strong on this
page does change the app's saved strength. Disabling haptics stops app-owned
feedback; system controls and notifications retain their own settings.

Dictation suppression begins before audio activation suspends. Recording stop
acknowledgement follows actual capture stop and successful audio-session release,
before remote transcription finalization. A failure to release the session does
not discard the recording or claim a tactile stop. A stop without an active
recording also tears down capture and releases haptic ownership without acknowledging success. Permission/start failures do
not claim recording readiness. A recovered-recording tile plays `success` when its
text lands in the draft, `error` when transcription fails and `commit` when the
recording is deleted; a tile whose recording no longer exists disappears silently.
A stop that cancels a start before capture began plays nothing. Automatic
dictation handoff remains silent.
`refused` is the only event that plays during capture: it uses the system error
pattern when the user tries to switch chats while dictating. The dictation
session therefore allows haptics during recording; every other app-owned event
stays suppressed by `HapticService`, while native system controls keep their own
feedback.

All app-owned feedback pauses while a live call is active, including when its UI
is minimized. This deliberately protects microphone/call quality. The haptics
layer never changes recording allowance, activates audio, overrides routes or
creates another call lifecycle. System call controls stay system-owned.

## Verification

When changing the behavior these iOS suites cover, run them explicitly in one
GUI test host simulator operation:

```sh
just ios-simulator-test RemoteCoderTests/HapticServiceTests \
  RemoteCoderTests/ReasoningPickerTests RemoteCoderTests/ReasoningControlLifecycleTests
```

They cover profile persistence/opt-out, recipe construction, stale pulses,
prepared-owner replacement/cancellation, same-callback delivery, native binding
transactions and user-only writes, detent hysteresis and final-position/release
ownership. Fake players record API intent without driving the hardware.
`scripts/tests/test_haptic_lint.py` tests the source guard against accidental
raw-menu and haptic bypasses. Static checks are `scripts/lint-haptics`,
`scripts/lint-glass` and `git diff --check`.

Use `just install-dev` for the normal leased build and iPhone
install/readback/launch. The full app unit suite and opt-in UI suites remain
available through their existing repo commands, but are not necessary for every
strength adjustment. Do not substitute a UI test for physical haptic acceptance.

The original refinement used focused unit checks only, no UI or integration
runs. The device pass should compare Standard/Strong from Try feedback, including
short tap, hold/slide/release, cancelled gestures, rapid re-entry, all detents,
keyboard focus, native menus and settings tabs. Also check app/system haptics off,
Reduce Motion, VoiceOver, cold-after-idle feedback, different grips/case and
recording/call routes. The custom accents are tuning candidates, not remotely
validated improvements. Simulator success cannot establish physical feel,
microphone interference, power use or actuator latency. Signposts identify
requests only and never contain copied text, prompts or audio.
