import SwiftUI

struct HostFileNestedPresentation: ViewModifier {
    let opener: HostFileOpener?
    let scope: UUID

    @ViewBuilder func body(content: Content) -> some View {
        if let opener {
            content
                .modifier(HostFilePresentation(opener: opener, isBlocked: false, scope: scope))
                .onDisappear { opener.leavePresentationScope(scope) }
        } else {
            content
        }
    }
}
