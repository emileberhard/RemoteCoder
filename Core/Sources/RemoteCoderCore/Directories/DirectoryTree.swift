import Foundation

/// A directory's load state, kept distinct from its content: `notLoaded` and
/// `loaded([])` both render zero rows but mean different things to the picker.
enum DirectoryChildren: Equatable, Sendable {
    case notLoaded
    case loading
    case loaded([DirectoryItem])
    case failed(String)
}

struct DirectoryItem: Identifiable, Equatable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    var isExpanded = false
    var children: DirectoryChildren = .notLoaded

    init(path: String) {
        self.path = path
        if path == "~" {
            name = "~"
        } else {
            let lastComponent = (path as NSString).lastPathComponent
            name = lastComponent.isEmpty ? path : lastComponent
        }
    }
}

/// The picker's expandable tree, addressed by path. Every mutation walks from
/// the root, so a stale reference to a node can never overwrite a sibling
/// branch's newer state.
struct DirectoryTree: Equatable, Sendable {
    private(set) var root: DirectoryItem

    init(root: DirectoryItem) {
        self.root = root
    }

    mutating func setExpanded(_ isExpanded: Bool, at path: String) {
        update(path: path) { $0.isExpanded = isExpanded }
    }

    mutating func setChildren(_ children: DirectoryChildren, at path: String) {
        update(path: path) { $0.children = children }
    }

    mutating func replaceRootChildren(_ children: [DirectoryItem]) {
        root.isExpanded = true
        root.children = .loaded(children)
    }

    /// Depth-first, expanded-only rows for the picker list: `(item, level)`.
    /// The root itself is level 0 and its direct children also start at 0, so
    /// the fixed home row never indents its contents.
    func visibleRows() -> [(item: DirectoryItem, level: Int)] {
        rows(for: root, level: 0)
    }

    private func rows(for item: DirectoryItem, level: Int) -> [(item: DirectoryItem, level: Int)] {
        var result = [(item: item, level: level)]
        guard item.isExpanded, case .loaded(let children) = item.children else { return result }
        let nextLevel = item.path == "~" ? 0 : level + 1
        for child in children {
            result.append(contentsOf: rows(for: child, level: nextLevel))
        }
        return result
    }

    private mutating func update(path: String, _ mutate: (inout DirectoryItem) -> Void) {
        root = DirectoryTree.updated(root, path: path, mutate: mutate)
    }

    private static func updated(_ item: DirectoryItem, path: String, mutate: (inout DirectoryItem) -> Void) -> DirectoryItem {
        var item = item
        if item.path == path {
            mutate(&item)
            return item
        }
        if case .loaded(let children) = item.children {
            item.children = .loaded(children.map { updated($0, path: path, mutate: mutate) })
        }
        return item
    }
}
