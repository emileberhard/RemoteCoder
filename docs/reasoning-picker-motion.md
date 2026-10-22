# Reasoning picker motion

`ConversationSettingsControls` owns the compact gauge and its persistent UIKit
activation surface. `ReasoningPickerOverlay` owns the floating presentation in
both chat and Voice Mode. Tap, hold/slide/release, cancellation, RTL, and the
per-provider visible-effort choices retain their existing input owners.

This is the iOS arm. The Mac arm of `ConversationSettingsControls` uses a native
menu of the same choices and no slider.

## Geometry and lifetime

The glyph's measured SwiftUI global rectangle is the source for both expansion
and collapse. The larger touch target and UIKit touch location are not visual
anchors. Both source and destination are converted into the screen overlay's
coordinates once. The expanded capsule lifts 12 points from the glyph center,
subject to viewport bounds, instead of travelling from below the composer.

A single native `Animatable` progress value interpolates the capsule rectangle.
The thumb uses the current height, so widening the capsule does not stretch the
thumb into an ellipse. Labels fade independently at their final readable size;
the backdrop also has its own short opacity animation. Geometry uses a restrained
0.32-second spring opening and a 0.22-second smooth spring closing. These are
perceptual durations, not wall-clock completion guarantees.

The active input session ends immediately on finish/cancel. A retained
`presentedSession` exists only until SwiftUI's removal completion; it cannot
commit again, intercept closing touches, or clear a replacement presentation.
The compact gauge's existing settle/haptic task starts after this completion,
not after a guessed 450-millisecond sleep. Viewport changes, screen departure,
and backgrounding clear both states. Reduce Motion uses an opacity-only swap.

This deliberately uses neither a keyframe player nor a generic transition
framework. `matchedGeometryEffect` links geometry but does not define rendering,
and removing the source control would break its ongoing UIKit long-press touch.
The small explicit presentation keeps that touch surface mounted.

## Sources consulted (2026-09-20)

- [Apple HIG: Motion](https://developer.apple.com/design/human-interface-guidelines/motion)
- [Explore SwiftUI animation, WWDC23](https://developer.apple.com/videos/play/wwdc2023/10156/)
- [Animate with springs, WWDC23](https://developer.apple.com/videos/play/wwdc2023/10158/)
- [Advanced animations and keyframe trade-offs, WWDC23](https://developer.apple.com/videos/play/wwdc2023/10157/)
- [Animatable](https://developer.apple.com/documentation/swiftui/animatable)
- [Animation completion](https://developer.apple.com/documentation/swiftui/withanimation(_:completioncriteria:_:completion:))
- [Matched geometry](https://developer.apple.com/documentation/swiftui/view/matchedgeometryeffect(id:in:properties:anchor:issource:))

The user's comparison recording is the visual reference, not evidence of
ChatGPT's internal implementation. Final visual acceptance is on the user's
physical iPhone; this iteration intentionally does not run simulator/heavy tests.
