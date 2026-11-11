import SwiftUI

struct ChatScreenToolbar: View {
    @Namespace private var navigationNamespace
    let workspace: ChatWorkspaceModel
    let screen: ChatScreenModel
    let onReturnToParent: () -> Void
    let onOpenConversation: (ConversationAddress) -> Void
    let onOpenConversations: (() -> Void)?
    let onChooseFolder: () -> Void
    let onNewChatInHome: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            header
            ScreenForkOriginHeader(screen: screen, onOpen: onOpenConversation)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private var header: some View {
        ChatHeader(
            screen: screen,
            hostName: workspace.conversationTargetName(of: screen),
            favorites: { workspace.favoriteFolders },
            onChooseFolder: onChooseFolder,
            onSelectFavorite: { workspace.selectFavorite($0, from: screen, ifStillShowing: $1) }
        ) {
            if returnsToParent || onOpenConversations != nil {
                navigationButton
            }
        } trailing: {
            NewChatButton(onNewChat: screen.startNewConversation, onNewChatInHome: onNewChatInHome)
        }
    }

    /// The drawer used to be reachable only by an edge drag, which no
    /// accessibility technology and no UI test can perform.
    private var navigationButton: some View {
        GlassCircleButton(
            systemImage: returnsToParent ? "chevron.left" : "text.justify.leading",
            symbolSize: returnsToParent ? 18 : 17,
            feedback: returnsToParent ? .iconPress : nil
        ) {
            if returnsToParent { onReturnToParent() }
            else { onOpenConversations?() }
        }
        .glassEffectID("navigation", in: navigationNamespace)
        .accessibilityLabel(returnsToParent ? "Return to parent conversation" : "Conversations")
        .accessibilityIdentifier(returnsToParent ? "return-to-parent" : "open-conversations")
    }

    private var returnsToParent: Bool { screen.agentParent != nil }
}
