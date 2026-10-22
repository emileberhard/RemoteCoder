//
//  DirectoryPickerView.swift
//  RemoteCoder
//
//  Directory picker for selecting Codex working directory.
//  Browses REMOTE directories via the Codex gateway (command/exec) with expand/collapse.
//

import SwiftUI
import Foundation

extension DynamicTypeSize {
    var favoriteColumnCount: Int { self >= .xxxLarge ? 1 : 2 }
}

// MARK: - Main Directory Picker View

struct DirectoryPickerView<HostSwitcher: View>: View {
    let directories: HostDirectories
    let favorites: [FavoriteFolder]
    let currentWorkingDirectory: String?
    let prefetchedRootChildren: [DirectoryItem]
    let folderListID: ObjectIdentifier
    @ViewBuilder let hostSwitcher: HostSwitcher
    let onSelectFavorite: (FavoriteFolder) -> Void
    let onRemoveFavorite: (FavoriteFolder) -> Void
    let onSelect: (String) -> Void
    @Environment(\.interfaceScale) private var interfaceScale
    @State private var contextMenu = ScrollItemContextMenu<DirectoryMenuID>()

    var body: some View {
        NavigationStack {
            DirectoryFolderList(
                contextMenu: contextMenu,
                directories: directories,
                favorites: favorites,
                currentWorkingDirectory: currentWorkingDirectory,
                prefetchedRootChildren: prefetchedRootChildren,
                onSelectFavorite: onSelectFavorite,
                onRemoveFavorite: onRemoveFavorite,
                onSelect: onSelect
            )
            .id(folderListID)
            .safeAreaBar(edge: .top, spacing: 0) {
                VStack(spacing: 0) { hostSwitcher }
                    .scrollItemMenuObstruction(contextMenu)
            }
        }
        #if os(macOS)
        // A scrolling list has no intrinsic height. Mac sheets need a size
        // independent of the iOS detent so the browser cannot collapse away.
        .frame(
            minWidth: 480 * interfaceScale, idealWidth: 560 * interfaceScale,
            minHeight: 420 * interfaceScale, idealHeight: 560 * interfaceScale
        )
        #endif
        // Choosing a folder always meant scrolling past the half sheet.
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

private struct DirectoryFolderList: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppThemeStore.self) private var themeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var viewModel: DirectoryPickerViewModel
    @State private var isVisible = false
    let contextMenu: ScrollItemContextMenu<DirectoryMenuID>
    @Environment(\.scenePhase) private var scenePhase

    let onSelect: (String) -> Void
    let onSelectFavorite: (FavoriteFolder) -> Void
    let onRemoveFavorite: (FavoriteFolder) -> Void
    let directories: HostDirectories
    let favorites: [FavoriteFolder]
    let currentWorkingDirectory: String?

    /// The directories service and host both come from the chat model that
    /// opened this picker, so a directory can never be resolved against
    /// whichever host happens to be selected after an `await`.
    init(
        contextMenu: ScrollItemContextMenu<DirectoryMenuID>,
        directories: HostDirectories,
        favorites: [FavoriteFolder],
        currentWorkingDirectory: String?,
        prefetchedRootChildren: [DirectoryItem],
        onSelectFavorite: @escaping (FavoriteFolder) -> Void,
        onRemoveFavorite: @escaping (FavoriteFolder) -> Void,
        onSelect: @escaping (String) -> Void
    ) {
        self.contextMenu = contextMenu
        self.viewModel = DirectoryPickerViewModel(
            directories: directories,
            currentWorkingDirectory: currentWorkingDirectory,
            prefetchedRootChildren: prefetchedRootChildren
        )
        self.directories = directories
        self.favorites = favorites
        self.onSelectFavorite = onSelectFavorite
        self.onRemoveFavorite = onRemoveFavorite
        self.onSelect = onSelect
        self.currentWorkingDirectory = currentWorkingDirectory
    }

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .scaledFont(.footnote)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                }
                .listRowBackground(Color.orange.opacity(0.10))
            }

            if !favorites.isEmpty {
                Section {
                    Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                        let columns = dynamicTypeSize.favoriteColumnCount
                        ForEach(Array(stride(from: 0, to: favorites.count, by: columns)), id: \.self) { start in
                            GridRow {
                                ForEach(favorites[start..<min(start + columns, favorites.count)]) { favorite in
                                    favoriteButton(favorite)
                                }
                                if columns == 2, start + 1 == favorites.count {
                                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                                }
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 12, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } header: {
                    Label("Favorites", systemImage: "star.fill")
                        .textCase(nil)
                }
            }

            Section("Browse") {
                ForEach(homeDirectoryRows) { row in
                    let isRoot = row.item.path == "~"
                    directoryRow(
                        item: row.item,
                        level: row.level,
                        showsToggle: !isRoot,
                        isFavorite: isRoot ? false : viewModel.isFavorite(row.item)
                    )
                }

                switch viewModel.tree.root.children {
                case .notLoaded, .loading:
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading…")
                            .scaledFont(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(sheetListRowBackground)
                case .loaded(let children) where children.isEmpty:
                    ContentUnavailableView(
                        "No subdirectories found",
                        systemImage: "folder.badge.questionmark"
                    )
                    .listRowBackground(sheetListRowBackground)
                case .loaded, .failed:
                    EmptyView()
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, ControlMetrics.minimumTarget)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 4, for: .scrollContent)
        .clearNavigationBackground()
        .scrollEdgeEffectStyle(.soft, for: .all)
        .navigationTitle("Working Directory")
        .inlineNavigationTitle()
        .navigationSubtitle(viewModel.selectedPath ?? "No folder selected")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", systemImage: "xmark") {
                    HapticService.shared.play(.disclosure)
                    dismiss()
                }
            }
        }
        .task {
            await viewModel.loadInitialChildren()
        }
        .onChange(of: directories.homeChildren) { _, children in
            guard isVisible, let children else { return }
            viewModel.replaceRootChildren(with: children.childItems)
        }
        .onChange(of: currentWorkingDirectory) { _, newValue in
            viewModel.syncWorkingDirectory(newValue)
        }
        .onAppear { isVisible = true }
        .onDisappear {
            isVisible = false
            viewModel.cancelPendingLoads()
        }
    }

    private var homeDirectoryRows: [DirectoryRowEntry] {
        viewModel.tree.visibleRows().map { DirectoryRowEntry(item: $0.item, level: $0.level) }
    }

    private func directoryRow(
        item: DirectoryItem,
        level: Int,
        showsToggle: Bool,
        isFavorite: Bool
    ) -> some View {
        let selected = isSelected(item)
        let isLoading = { if case .loading = item.children { true } else { false } }()

        return DirectoryRow(
            menu: contextMenu,
            menuID: .browse(.init(hostID: directories.hostID, path: item.path)),
            item: item,
            level: level,
            isSelected: selected,
            showsToggle: showsToggle,
            isLoading: isLoading,
            isFavorite: isFavorite,
            supportsFavorite: item.path != "~",
            onToggle: {
                withAnimation(.smooth) {
                    viewModel.toggleExpansion(for: item)
                }
            },
            onSelect: { select(item) },
            onToggleFavorite: { toggleFavorite(item) }
        )
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowBackground(selected ? themeStore.theme.colors.accentTint.opacity(0.10) : .clear)
    }

    private func favoriteButton(_ favorite: FavoriteFolder) -> some View {
        let selected = isSelected(favorite)
        return Button { select(favorite) } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "folder.fill" : "folder")
                    .foregroundStyle(selected ? AnyShapeStyle(themeStore.theme.colors.accentTint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(favorite.title)
                        .scaledFont(.subheadline.weight(.medium))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .truncationMode(.middle)
                    if favorite.showsHostLabel {
                        Text(favorite.hostName)
                            .scaledFont(.caption2.weight(.semibold))
                            .foregroundStyle(themeStore.theme.colors.accentTint)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if selected {
                    Image(systemName: "checkmark")
                        .scaledFont(.caption.weight(.bold))
                        .foregroundStyle(themeStore.theme.colors.accentTint)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: ControlMetrics.minimumTarget + 8, alignment: .leading)
            .foregroundStyle(.primary)
            .background(selected ? themeStore.theme.colors.accentTint.opacity(0.14) : sheetListRowBackground,
                        in: .rect(cornerRadius: 14))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(themeStore.theme.colors.accentTint.opacity(0.5), lineWidth: 1)
                }
            }
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(ResponsiveButtonStyle(feedback: selected ? .buttonPress : nil, pressedScale: 0.98, pressedOpacity: 0.9))
        .accessibilityLabel(favorite.showsHostLabel ? "\(favorite.title), on \(favorite.hostName)" : favorite.title)
        .accessibilityValue(favorite.path)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .modifier(DirectoryRowFavoriteContextMenu(
            menu: contextMenu, id: .favorite(favorite.id),
            item: DirectoryItem(path: favorite.path), supportsFavorite: true, isFavorite: true,
            preview: ControlPeekPreview(symbol: "folder.fill", title: favorite.title,
                                        subtitle: favorite.hostName, detail: favorite.path),
            onSelect: { select(favorite) }, onToggleFavorite: { removeFavorite(favorite) }
        ))
    }

    private func select(_ favorite: FavoriteFolder) {
        let changesSelection = !isSelected(favorite)
        Task { @MainActor in
            guard isVisible else { return }
            if changesSelection { HapticService.shared.play(.selection) }
            dismiss()
            onSelectFavorite(favorite)
        }
    }

    private func removeFavorite(_ favorite: FavoriteFolder) {
        onRemoveFavorite(favorite)
        if isVisible, scenePhase == .active { HapticService.shared.play(.toggleOff) }
    }

    private func isSelected(_ favorite: FavoriteFolder) -> Bool {
        favorite.hostID == directories.hostID && viewModel.selectedPath == favorite.path
    }

    private func select(_ item: DirectoryItem) {
        let changesSelection = !isSelected(item)
        Task { @MainActor in
            guard let path = await viewModel.selectDirectory(item), isVisible else { return }
            if changesSelection { HapticService.shared.play(.selection) }
            dismiss()
            onSelect(path)
        }
    }

    private func toggleFavorite(_ item: DirectoryItem) {
        let previous = viewModel.isFavorite(item)
        Task {
            await viewModel.toggleFavorite(for: item)
            guard isVisible, scenePhase == .active else { return }
            let current = viewModel.isFavorite(item)
            if current != previous { HapticService.shared.play(current ? .toggleOn : .toggleOff) }
            else if viewModel.errorMessage != nil { HapticService.shared.play(.error) }
        }
    }

    private func isSelected(_ item: DirectoryItem) -> Bool {
        if item.path == "~", let homePath = viewModel.resolvedHomeDirectory {
            return viewModel.selectedPath == "~" || viewModel.selectedPath == homePath
        }
        return viewModel.selectedPath == item.path
    }

    private var sheetListRowBackground: Color {
        themeStore.theme.sheetListRowBackground(for: colorScheme)
    }

}

private struct DirectoryRowEntry: Identifiable {
    let item: DirectoryItem
    let level: Int

    var id: String { item.id }
}

struct WorkspaceDirectoryPicker: View {
    let workspace: ChatWorkspaceModel

    var body: some View {
        if let screen = workspace.selectedScreen {
            let contextID = screen.currentConversationID
            DirectoryPickerView(
                directories: screen.target.directories,
                favorites: workspace.favoriteFolders,
                currentWorkingDirectory: screen.workingDirectory,
                prefetchedRootChildren: screen.target.directories.homeChildren?.childItems ?? [],
                folderListID: ObjectIdentifier(screen),
                hostSwitcher: { hostSwitcher },
                onSelectFavorite: { workspace.selectFavorite($0, from: screen, ifStillShowing: contextID) },
                onRemoveFavorite: { workspace.removeFavorite($0) }
            ) { path in
                workspace.selectWorkingDirectory(path, on: screen, ifStillShowing: contextID)
            }
            .onAppear { workspace.syncFavoriteFolders() }
        }
    }

    private var hostSwitcher: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(workspace.settings.hosts) { host in
                    let selected = host.id == workspace.selectedHostID
                    Button {
                        workspace.select(hostID: host.id)
                        if !selected, workspace.selectedHostID == host.id { HapticService.shared.play(.selection) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: selected ? "checkmark" : "server.rack")
                            Text(host.name)
                        }
                        .scaledFont(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(minHeight: ControlMetrics.minimumTarget)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(ResponsiveButtonStyle(feedback: selected ? .buttonPress : nil, pressedScale: 0.97, pressedOpacity: 0.9))
                    .appContentSurface(selected ? .selected : .standard, in: .capsule)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityLabel("Host, \(host.name)")
                    .accessibilityIdentifier("directory-host-\(host.id.uuidString)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
    }
}
