import Foundation
import Testing
@testable import RemoteCoderCore

struct DirectoryTreeTests {
    private func rootTree() -> DirectoryTree {
        var root = DirectoryItem(path: "~")
        root.isExpanded = true
        root.children = .loaded([DirectoryItem(path: "/home/a"), DirectoryItem(path: "/home/b")])
        return DirectoryTree(root: root)
    }

    @Test func visibleRowsSkipsCollapsedBranchesAndIndentsNestedChildren() {
        var tree = rootTree()
        var nested = DirectoryItem(path: "/home/a")
        nested.isExpanded = true
        nested.children = .loaded([DirectoryItem(path: "/home/a/child")])
        tree.setExpanded(true, at: "/home/a")
        tree.setChildren(nested.children, at: "/home/a")

        let rows = tree.visibleRows()

        #expect(rows.map(\.item.path) == ["~", "/home/a", "/home/a/child", "/home/b"])
        #expect(rows.map(\.level) == [0, 0, 1, 0])
    }

    @Test func visibleRowsOmitsChildrenOfAnUnexpandedItemEvenWhenLoaded() {
        var tree = rootTree()
        var nested = DirectoryItem(path: "/home/a")
        nested.children = .loaded([DirectoryItem(path: "/home/a/child")])
        tree.setChildren(nested.children, at: "/home/a")

        let rows = tree.visibleRows()

        #expect(rows.map(\.item.path) == ["~", "/home/a", "/home/b"])
    }

    @Test func setChildrenOnOneNodeLeavesItsSiblingUntouched() {
        var tree = rootTree()

        tree.setChildren(.failed("boom"), at: "/home/a")

        let rows = tree.visibleRows()
        #expect(rows.first { $0.item.path == "/home/a" }?.item.children == .failed("boom"))
        #expect(rows.first { $0.item.path == "/home/b" }?.item.children == .notLoaded)
    }

    @Test func replaceRootChildrenExpandsTheRootAndReplacesItsChildren() {
        var tree = DirectoryTree(root: DirectoryItem(path: "~"))

        tree.replaceRootChildren([DirectoryItem(path: "/home/only")])

        #expect(tree.root.isExpanded)
        #expect(tree.root.children == .loaded([DirectoryItem(path: "/home/only")]))
    }
}
