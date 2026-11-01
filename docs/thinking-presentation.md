# Thinking presentation

The live timeline header shows Thinking with a moving band on iOS and static
text on Mac. Completed headers keep their observed duration or action count.
Timeline liveness remains owned by conversation projection; animation never
invents an active turn.

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
static because a native gradient experiment did not meet its compositor
budget. This is a decision about the measured shimmer, not every repeating
decoration.

The band follows a continuous 1.5-second ease-in-out sweep with a narrow opacity
profile and a shared media-time phase. Repeated publications do not restart it.
The native group requests a 30–60 Hz range; that preference is not a display-rate
guarantee. A discrete 30 Hz variant showed no consistent benefit across the
test iPhone and ProMotion iPad and used more GPU time on the primary iPhone, so
it was removed. The sweep adds render-server work compared with the former dots.
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

## Mac motion admission

A layer-hosting native gradient eliminated recurring app commits but did not
meet the compositor budget. Its 30 Hz preference worked on the measured Mac;
that does not remove WindowServer work. The Mac shimmer remains static.
Detailed measurements and their limitations stay in the private operator records.

A future attempt must prove the animated arm runs, then pass at least three
alternating static/animated pairs with identical fixtures and energy state on
an otherwise idle Mac; record background load. Require app CPU delta ≤0.5 points
of one core, separately sampled WindowServer CPU delta ≤1 point, GPU delta
≤2 ms/s, no recurring animation-driven app commits (idle delta ≤0.2/s), scrolling
hitch rate <10 ms/s with delta ≤1 ms/s, and sustained `powermetrics` CPU + GPU +
ANE power delta ≤0.2 W. Report refresh-rate shares without changing display mode.
Missing or noisy evidence does not pass; zero app commits alone do not pass.
Check scrolling, glass, focus changes without
row-host rebuilding, two windows, Stage Manager, detached rows, hit testing and
one accessibility element. Keep occlusion and central row visibility with their
existing owners; do not redefine `visualsVisible` to gate decoration motion.
