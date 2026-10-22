import SwiftUI

struct ChatHeader<Leading: View, Trailing: View>: View {
    let screen: ChatScreenModel
    let hostName: String
    let favorites: () -> [FavoriteFolder]
    let onChooseFolder: () -> Void
    let onSelectFavorite: (_ favorite: FavoriteFolder, _ contextID: UUID) -> Void
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        let contextID = screen.currentConversationID
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                leading

                WorkingDirectoryHeader(
                    path: screen.workingDirectory,
                    remoteHomePath: screen.target.remoteHomePath,
                    hostID: screen.hostID,
                    hostName: hostName,
                    favorites: favorites,
                    contextID: contextID,
                    onActivate: onChooseFolder,
                    onSelectFavorite: { onSelectFavorite($0, contextID) }
                )
                .chromeTransitionSource("directory")
                .frame(maxWidth: .infinity)
                .layoutPriority(1)

                trailing
            }
        }
    }
}
