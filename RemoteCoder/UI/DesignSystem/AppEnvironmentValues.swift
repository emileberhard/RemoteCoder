import SwiftUI

extension EnvironmentValues {
    @Entry var appEnergyPolicy = AppEnergyPolicy.current
    /// A mounted surface can be covered: the chat by its drawer or a full-screen
    /// call, and the closed drawer by the chat.
    @Entry var visualsVisible = true
    @Entry var isAttachmentDropTargeted = false
    @Entry var chromeTransitionNamespace: Namespace.ID?
    @Entry var chatImageSource: ChatImageSource?
    @Entry var interfaceScale: CGFloat = 1
}
