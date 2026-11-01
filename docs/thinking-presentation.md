# Thinking presentation

The live timeline header shows Thinking with a moving band. Completed headers
keep their observed duration or action count. Timeline liveness remains owned
by conversation projection; animation never invents an active turn.

## Ownership

`shimmer(isActive:)` is the shared design-system entry point. The caller supplies
liveness. Its iOS arm owns the native gradient and animation lifetime; SwiftUI
keeps the original content as the layout, hit-testing and accessibility owner.
The overlay uses that content's alpha as its mask and contributes no accessible
element. Its updates change native layers only when color, direction or size
changes. There is no repeating SwiftUI clock or per-frame observable state.

The modifier stops immediately when inactive, hidden, offscreen, in Reduce
Motion, Increase Contrast, or energy conservation. Within a transcript it uses
the central row-visibility owner. Outside a transcript, surface visibility is
the caller's existing environment responsibility. The Mac arm keeps the text
static, matching the existing platform policy for repeating decorations.

The band follows a 1.5-second ease-in-out sweep with a narrow opacity profile
and a shared media-time phase. Repeated publications do not restart it. Forty-five
discrete native keyframes per cycle give 30 updates per second without relying
on the frame-rate hint alone. The group also requests a 20–30 Hz range. Physical
display rates and render-server cost remain measurement results, not API guarantees.

## Disclosure motion

The timeline's expansion state and flat activity-row identities stay with their
existing transcript owners. Each event's detail state stays with its row
presentation. Opening details allocates their height once and fades the content
in; closing removes it immediately. The chevron has its own short spring.
Streamed updates inside an open event do not animate text or geometry.

This uses framework-owned transitions rather than a second presentation state,
completion callbacks or a height-animation controller. The trade-off is an
instant layout change when event details open or close. A live-heading queue
is unnecessary for the current Thinking label and is not part of this component.

## Validation

Follow the [controlled preview contract](performance-replay.md#controlled-ui-previews)
for live, completed and expanded states.
Compare the same fixture and energy state on the same device, retaining the
matching app and symbols. Check the native mask, hit testing, text scaling,
direction, gate transitions and expanded streaming content visually. Measure
ProMotion refresh-rate shares separately from the 60 Hz test iPhone.
