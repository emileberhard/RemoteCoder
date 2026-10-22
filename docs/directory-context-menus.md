# Directory context menus

Each working-directory favorite and Browse row offers Use this folder,
Favorite or Unfavorite where supported, and Copy path. Favorite previews name
both the folder and its host. Menu actions keep the pressed folder's exact
host/path even if the visible host changes.

On iOS, each picker owns one `ScrollItemContextMenu<DirectoryMenuID>`. This
is the drawer's native UIKit interaction, shared with generic item identity.
Weak anchors report each cell's actual geometry in the scroll view, including
its current offset. UIKit captures the preview and flat actions at menu opening;
SwiftUI updates cannot retarget an open menu. The pressed representation alone
hides during the lift, and a reused or detached anchor cannot become a dismissal
target. Accessibility exposes the same actions. Mac uses native SwiftUI menus.

Favorites are one Grid inside a List row. SwiftUI context menus on its cells
can resolve to the first cell instead of the pressed cell. Splitting the grid into two-cell List rows retains
the same ambiguity. Replacing the entire List would change tree layout and
virtualization. Reusing the existing interaction preserves that layout and keeps
hit testing, clipping, menu snapshots and lift lifetime with one owner.

The shared engine remains concrete in its ControlPeekPreview and flat action
content; only item identity varies. Conversation policy stays in
ConversationHistoryActions. DirectoryMenuID separates favorite and Browse
representations of the same host/path so lifting one cannot hide both.

`DirectoryContextMenuTests` exercises both columns, scrolling, identical paths
on different hosts, an absent host switcher and stale dismissal anchors.
Physical acceptance additionally checks previews, Copy path and exact selection
after favorites change while a menu is open. Keep live screenshots, clipboard
contents and device receipts in private operator evidence.
