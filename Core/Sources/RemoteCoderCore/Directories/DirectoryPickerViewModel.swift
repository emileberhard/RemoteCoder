import Foundation
import Observation

/// The directory picker sheet's screen model: an expandable `DirectoryTree`
/// plus selection state. All directory knowledge (home resolution, listing,
/// favorites) belongs to `HostDirectories`; this model only orchestrates which
/// paths are expanded and loading.
@MainActor
@Observable
final class DirectoryPickerViewModel {
    private(set) var tree: DirectoryTree
    var selectedPath: String?
    var currentWorkingDirectory: String?
    var errorMessage: String?

    @ObservationIgnored private let directories: HostDirectories
    @ObservationIgnored private var expansionTasks: [String: Task<Void, Never>] = [:]

    var resolvedHomeDirectory: String? {
        if case .resolved(let path) = directories.home { return path }
        return nil
    }

    init(directories: HostDirectories, currentWorkingDirectory: String?, prefetchedRootChildren: [DirectoryItem] = []) {
        self.directories = directories
        self.currentWorkingDirectory = currentWorkingDirectory
        selectedPath = currentWorkingDirectory
        var root = DirectoryItem(path: "~")
        root.isExpanded = true
        root.children = prefetchedRootChildren.isEmpty ? .notLoaded : .loaded(prefetchedRootChildren)
        tree = DirectoryTree(root: root)
    }

    func loadInitialChildren() async {
        guard case .notLoaded = tree.root.children else { return }
        tree.setChildren(.loading, at: "~")
        let result = await performLoad(path: "~")
        tree.setChildren(result, at: "~")
    }

    func syncWorkingDirectory(_ newWorkingDirectory: String?) {
        let trimmed = newWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.isEmpty == false else { return }
        currentWorkingDirectory = trimmed
        selectedPath = trimmed
    }

    func isFavorite(_ item: DirectoryItem) -> Bool {
        directories.favorites.contains(item.path)
    }

    func toggleFavorite(for item: DirectoryItem) async {
        guard item.path != "~" else { return }
        do {
            let expandedPath = try await directories.expandedPath(item.path)
            directories.toggleFavorite(expandedPath)
        } catch {
            errorMessage = "Failed to toggle favorite: \(error.localizedDescription)"
        }
    }

    func toggleExpansion(for item: DirectoryItem) {
        guard item.path != "~" else { return }
        let willExpand = !item.isExpanded
        tree.setExpanded(willExpand, at: item.path)
        guard willExpand else { return }
        if case .loaded = item.children { return }
        expansionTasks[item.path]?.cancel()
        tree.setChildren(.loading, at: item.path)
        let path = item.path
        let task = Task { [weak self] in
            guard let self else { return }
            let result = await self.performLoad(path: path)
            guard !Task.isCancelled else { return }
            self.tree.setChildren(result, at: path)
            self.expansionTasks[path] = nil
        }
        expansionTasks[item.path] = task
    }

    /// Resolves the tapped folder to its absolute path and returns it, or nil
    /// when expansion failed and `errorMessage` explains why.
    func selectDirectory(_ item: DirectoryItem) async -> String? {
        selectedPath = item.path
        do {
            let expandedPath = try await directories.expandedPath(item.path)
            selectedPath = expandedPath
            return expandedPath
        } catch {
            errorMessage = "Failed to expand path: \(error.localizedDescription)"
            return nil
        }
    }

    func replaceRootChildren(with children: [DirectoryItem]) {
        tree.replaceRootChildren(children)
    }

    func cancelPendingLoads() {
        for task in expansionTasks.values { task.cancel() }
        expansionTasks.removeAll()
    }

    private func performLoad(path: String) async -> DirectoryChildren {
        do {
            let listing = try await directories.list(path)
            return .loaded(listing.childItems)
        } catch {
            errorMessage = "Failed to load directories: \(error.localizedDescription)"
            return .failed(error.localizedDescription)
        }
    }
}
