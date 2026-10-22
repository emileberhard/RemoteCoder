# Working-directory quick switch

`WorkingDirectoryHeader` keeps a normal tap opening the full directory browser,
including its host switcher. A 280 ms hold opens a custom Liquid Glass palette
from the header. Slide through the favorites of every host and release to select;
release on the header or outside the palette to cancel. Selecting the already
active directory does not start another conversation. Browse folders and Copy
path remain available in the palette footer.

## Ownership

- `TapHoldButton` owns the original UIKit button/long-press touch until
  end or cancellation. The screen overlay does not intercept that touch.
  The Mac `TapHoldButton` is a plain click, so the Mac has no hold to switch.
- `DirectoryQuickSwitchPresentation` owns the snapshot, hit testing, hover,
  final-contact selection, and haptic lifetime. Stale sessions cannot commit,
  scroll or dismiss a replacement. No directory changes occur while hovering.
- `DirectoryQuickSwitchOverlay` owns the glass morph and bounded edge scrolling.
  Ten 40-point rows of two columns fit at the default size; dwelling at a scrollable
  edge advances the real scroll view. Selection uses its reported offset, not a predicted offset.
- The chat and voice headers share the component. Each host's gateway owns
  its favorites (`directory/favorites/*`), and every device's `HostDirectories`
  replicates them, so a favorite appears on every device;
  `ChatWorkspaceModel.favoriteFolders` lists
  every host's in host order, and `selectFavorite` switches to the favorite's
  host before choosing its folder. The voice header lists only the call's host.
  The header reads the favorites when a hold begins. Changes to host,
  conversation, selected directory, layout or scene cancel active input. Callers also check conversation identity before a write.
  The existing selection operation owns starting a new conversation.

The default palette is at most 360 points wide and lays favorites out in a dense
two-column grid, in reading order, with single-line middle-truncated folder names,
40-point row and footer targets, and a single-line header. Right-to-left layouts
mirror the columns. Like the browser's favorites grid, it becomes a single column
at `xxxLarge` text and above. With more than one host, each cell names its host
under the folder. Names repeated on one host alone show their home-relative
paths. The header remains at least as tall as the source control to preserve its
cancel-on-return region. Short lists shrink to fit; larger lists show
up to ten whole rows (twenty favorites), never partial targets. Rows grow with
Dynamic Type but never shrink below 40 points at smaller text sizes.

One app-themed glass shell unfolds without scaling its text. The current folder
keeps its checkmark; the preview highlight moves independently. Reduce Motion
uses a crossfade. Dynamic Type scales row geometry; constrained layouts fall back
to the full browser. VoiceOver and other button activation open that same full
browser rather than requiring a hold gesture.

## Feedback

Contact, lift, crossing a new cell, and accepted selection use the existing
`buttonPress`, `lift`, `selection`, and `commit` events through `HapticService`.
The prepared player also warms these existing recipes. Four points of cell
hysteresis on both axes suppress boundary jitter; a release never adds a
redundant hover tick.
Cancellation is silent. Copy retains clipboard-owned feedback. Standard/Strong,
opt-out, foreground and microphone/call suppression remain centrally owned.

## Focused verification

When selection, layout, or feedback behavior changes, explicitly run
`just ios-simulator-test RemoteCoderTests/DirectoryQuickSwitchTests`. This
compiles the app and runs the isolated selection/layout/feedback tests on the
GUI test host, using recording haptic players and no gateway requests. The requested
verification deliberately excludes UI automation, simulator visual checks,
integration runs, and physical haptic acceptance. Use `just install-dev` from
main for the final device build, installation and launch.
