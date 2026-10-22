import SwiftUI

struct ConversationDrawerFilterButton: View {
    var workspace: ChatWorkspaceModel
    let window: ChatWindowModel
    let onSelect: () -> Void
    @State private var isPresented = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GlassCircleButton(systemImage: "line.3.horizontal.decrease",
                          role: workspace.drawerPreferences.unreadOnly ? .selected : .standard) {
            isPresented = true
        }
        .accessibilityLabel("View Options")
        .accessibilityValue(workspace.drawerPreferences.unreadOnly ? "Unread only" : "")
        .accessibilityIdentifier("drawer-view-options")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            ConversationDrawerMenu(workspace: workspace, window: window) {
                isPresented = false
                onSelect()
            }
            .presentationCompactAdaptation(horizontal: dynamicTypeSize.isAccessibilitySize ? .sheet : .popover, vertical: .sheet)
            .presentationSizing(.fitted)
        }
    }
}

struct ConversationDrawerMenu: View {
    var workspace: ChatWorkspaceModel
    let window: ChatWindowModel
    let onSelect: () -> Void
    @Environment(AppThemeStore.self) private var themeStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var preferences = workspace.drawerPreferences
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                modeTile(.priority, title: "Priority", systemImage: "list.star")
                modeTile(.projects, title: "Projects", systemImage: "folder")
            }
            Toggle(isOn: $preferences.unreadOnly) {
                Label("Unread Only", systemImage: "envelope.badge")
            }
            .tint(themeStore.theme.colors.accentTint)
            .accessibilityIdentifier("drawer-unread-only")
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                row("Select…", systemImage: "checkmark.circle", action: onSelect)
                row("Mark All as Read", systemImage: "envelope.open") {
                    workspace.markAllRead()
                    HapticService.shared.play(.commit)
                }
                row("Collapse All", systemImage: "rectangle.compress.vertical") {
                    withAnimation(reduceMotion ? nil : .snappy) {
                        workspace.setAllSectionsFolded(true, in: window)
                    }
                }
                row("Expand All", systemImage: "rectangle.expand.vertical") {
                    withAnimation(reduceMotion ? nil : .snappy) {
                        workspace.setAllSectionsFolded(false, in: window)
                    }
                }
            }
        }
        .scaledFont(.body)
        .padding(16)
        .frame(idealWidth: dynamicTypeSize.isAccessibilitySize ? nil : 280,
               maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 280)
    }

    private func modeTile(_ mode: ConversationDrawerMode, title: String, systemImage: String) -> some View {
        let isSelected = workspace.drawerPreferences.mode == mode
        return Button {
            guard !isSelected else { return }
            withAnimation(reduceMotion ? nil : .snappy) { workspace.drawerPreferences.mode = mode }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .scaledFont(.system(size: 22, weight: .semibold))
                    .symbolVariant(isSelected ? .fill : .none)
                    .foregroundStyle(isSelected ? themeStore.theme.colors.accentTint : .secondary)
                Text(title)
                    .scaledFont(.footnote.weight(.semibold))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(ResponsiveButtonStyle(feedback: isSelected ? nil : .selection, pressedScale: 0.97, pressedOpacity: 0.9))
        .appGlass(isSelected ? .selected : .standard, in: .rect(cornerRadius: 14), interactive: true)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("drawer-mode-\(mode.rawValue)")
    }

    private func row(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
