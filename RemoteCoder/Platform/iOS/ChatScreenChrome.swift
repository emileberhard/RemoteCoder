import SwiftUI

struct ChatScreenChrome: ViewModifier {
    let workspace: ChatWorkspaceModel
    let screen: ChatScreenModel
    let onReturnToParent: () -> Void
    let onOpenConversation: (ConversationAddress) -> Void
    let onOpenConversations: (() -> Void)?
    let onChooseFolder: () -> Void
    let onNewChatInHome: () -> Void
    let onNewChatOnHost: (UUID) -> Void
    let isInspectorOpen: Bool
    let toggleInspector: () -> Void
    let isReviewingChanges: Bool
    let reviewChanges: () -> Void

    func body(content: Content) -> some View {
        content
            .safeAreaBar(edge: .top, spacing: 0) {
                ChatScreenToolbar(
                    workspace: workspace,
                    screen: screen,
                    onReturnToParent: onReturnToParent,
                    onOpenConversation: onOpenConversation,
                    onOpenConversations: onOpenConversations,
                    onChooseFolder: onChooseFolder,
                    onNewChatInHome: onNewChatInHome
                )
                .chatLayoutDiagnostics("header")
            }
    }
}
