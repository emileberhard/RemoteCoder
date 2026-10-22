#if os(macOS)
import SwiftUI

struct CompletionNotificationOverlay: View {
    let workspace: ChatWorkspaceModel

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
    }
}
#endif
