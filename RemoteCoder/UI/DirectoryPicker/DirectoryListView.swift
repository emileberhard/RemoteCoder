import SwiftUI

private enum DirectoryPickerLayout {
    static let indentUnit: CGFloat = 20
}

// MARK: - Directory Row Component

enum DirectoryMenuID: Hashable {
    case favorite(FavoriteFolder.ID)
    case browse(FavoriteFolder.ID)
}

struct DirectoryRow: View {
    let menu: ScrollItemContextMenu<DirectoryMenuID>
    let menuID: DirectoryMenuID
    let item: DirectoryItem
    let level: Int
    let isSelected: Bool
    let showsToggle: Bool
    let isLoading: Bool
    let isFavorite: Bool
    let supportsFavorite: Bool
    let onToggle: () -> Void
    let onSelect: () -> Void
    let onToggleFavorite: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(AppThemeStore.self) private var themeStore

    private var indentPadding: CGFloat {
        CGFloat(max(level, 0)) * DirectoryPickerLayout.indentUnit
    }

    var body: some View {
        HStack(spacing: 8) {
            if showsToggle {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaledFrame(width: ControlMetrics.minimumTarget, height: ControlMetrics.minimumTarget)
                } else {
                    Button {
                        HapticService.shared.play(.disclosure)
                        onToggle()
                    } label: {
                        Image(systemName: item.isExpanded ? "chevron.down" : "chevron.right")
                            .scaledFont(TypeMetrics.symbol(12, weight: .bold))
                            .foregroundStyle(.secondary)
                            .scaledFrame(width: ControlMetrics.minimumTarget, height: ControlMetrics.minimumTarget)
                            .contentShape(.rect)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(ResponsiveButtonStyle(feedback: nil, pressedScale: 0.86, pressedOpacity: 0.88))
                    .accessibilityLabel("\(item.isExpanded ? "Collapse" : "Expand") \(item.name)")
                    .tooltip(item.isExpanded ? "Collapse" : "Expand")
                    .accessibilityValue(item.isExpanded ? "Expanded" : "Collapsed")
                }
            }

            Button(action: selectFolder) {
                HStack(spacing: 8) {
                    Image(systemName: isSelected ? "folder.fill" : "folder")
                        .scaledFont(TypeMetrics.symbol(16, weight: .semibold))
                        .foregroundStyle(isSelected ? selectedIconStyle : AnyShapeStyle(.secondary))
                        .contentTransition(.symbolEffect(.replace))

                    Text(item.path == "~" ? "Home" : item.name)
                        .scaledFont(.body.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .truncationMode(.middle)

                    Spacer(minLength: 0)

                    if isFavorite {
                        Image(systemName: "star.fill")
                            .scaledFont(TypeMetrics.symbol(11, weight: .semibold))
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Favorite")
                    }

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .scaledFont(TypeMetrics.symbol(17, weight: .semibold))
                            .foregroundStyle(themeStore.theme.colors.accentTint)
                            .transition(.scale.combined(with: .opacity))
                            .accessibilityLabel("Selected")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: ControlMetrics.minimumTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(ResponsiveButtonStyle(feedback: isSelected ? .buttonPress : nil, pressedScale: 0.995, pressedOpacity: 0.92))
        }
        .padding(.leading, indentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .animation(.smooth(duration: 0.18), value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .modifier(DirectoryRowFavoriteContextMenu(
            menu: menu, id: menuID, item: item, supportsFavorite: supportsFavorite, isFavorite: isFavorite,
            preview: ControlPeekPreview(symbol: "folder.fill", title: item.name,
                                        subtitle: isFavorite ? "Favorite folder" : "Remote folder", detail: item.path),
            onSelect: selectFolder, onToggleFavorite: onToggleFavorite
        ))
    }

    private func selectFolder() {
        onSelect()
    }

    private var selectedIconStyle: AnyShapeStyle {
        AnyShapeStyle(themeStore.theme.colors.accentTint)
    }
}

struct DirectoryRowFavoriteContextMenu: ViewModifier {
    let menu: ScrollItemContextMenu<DirectoryMenuID>
    let id: DirectoryMenuID
    let item: DirectoryItem
    let supportsFavorite: Bool
    let isFavorite: Bool
    let preview: ControlPeekPreview
    let onSelect: () -> Void
    let onToggleFavorite: () -> Void

    func body(content: Content) -> some View {
        let items = menuItems
        content
            .accessibilityActions {
                ForEach(items) { item in
                    Button(item.title, systemImage: item.systemImage, action: item.perform)
                }
            }
            .scrollItemMenu(menu, content: ScrollItemMenuContent(
                id: id,
                items: items,
                preview: preview,
                cornerRadius: 14
            ))
    }

    private var menuItems: [ContextMenuItem] {
        var items = [ContextMenuItem(title: "Use this folder", systemImage: "folder", perform: onSelect)]
        if supportsFavorite {
            items.append(ContextMenuItem(title: isFavorite ? "Unfavorite" : "Favorite",
                                         systemImage: isFavorite ? "star.slash" : "star", perform: onToggleFavorite))
        }
        items.append(ContextMenuItem(title: "Copy path", systemImage: "doc.on.doc") { HapticService.shared.copy(item.path) })
        return items
    }
}
