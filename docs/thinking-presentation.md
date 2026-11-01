# Thinking presentation

The live timeline header shows Thinking with a moving band on iOS and Mac.
Completed headers keep their observed duration or action count.
Timeline liveness remains owned by conversation projection; animation never
invents an active turn.

## Ownership

`shimmer(isActive:)` is the shared design-system entry point. The caller supplies
liveness. One shared CA owner manages the native gradient and animation lifetime;
thin UIKit and AppKit bridges forward layout and visibility. SwiftUI
keeps the original content as the layout, hit-testing and accessibility owner.
The overlay uses that content's alpha as its mask and contributes no accessible
element. Its updates change native layers only when color, direction or size
changes. There is no repeating SwiftUI clock or per-frame observable state.

The modifier stops immediately when inactive, hidden, offscreen, in Reduce
Motion, Increase Contrast, or energy conservation. Within a transcript it uses
the central row-visibility owner. Outside a transcript, surface visibility is
the caller's existing environment responsibility. The Mac bridge also observes
its attached window's occlusion and close notifications: retained views stop
animating while their window is closed, hidden, minimized or occluded, and
resume with the common media-time phase when visible again.

The band follows a continuous 1.5-second ease-in-out sweep with a narrow opacity
profile and a shared media-time phase. Repeated publications do not restart it.
The native group requests minimum, maximum and preferred rates of 30 Hz. This
caps the requested animation cadence without a discrete image sequence or an
app frame callback; the operating system still chooses the actual cadence.
The sweep adds render-server work compared with static text.
Short controlled recordings establish neither battery savings nor a fixed panel
rate. Keep the original native renderer unless a new measured mechanism justifies
changing it.

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

## Mac rendering

Mac motion is an explicit product trade-off: the shared CA implementation keeps
the same look and feel without adding a shader, child window or frame driver.
Its 30 Hz request does not guarantee a 30 Hz panel refresh or eliminate
WindowServer work. Busy-host comparisons do not establish idle CPU, GPU or power
ceilings; detailed measurements and limitations stay in the private operator
records. A future custom renderer needs a demonstrated improvement over this
capped baseline. Keep occlusion and central row visibility with their existing
owners; do not redefine `visualsVisible` to gate decoration motion.
