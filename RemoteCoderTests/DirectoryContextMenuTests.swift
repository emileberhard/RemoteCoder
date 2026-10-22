import SwiftUI
import Testing
import UIKit
@testable import RemoteCoder

@MainActor
@Suite(.serialized)
struct DirectoryContextMenuTests {
    @Test func favoriteGridTargetsBothColumnsAndHostsAfterScrolling() async throws {
        let fixture = try PickerFixture(hostSwitcher: Text("Mini · MacBook").frame(height: 44))
        defer { fixture.close() }
        try await fixture.waitForAnchors()
        let initial = fixture.visibleFavorites
        try #require(initial.count >= 4)
        #expect(Set(initial.map { $0.content.id }).contains(.favorite(.init(hostID: fixture.firstHost, path: "/work/RemoteCoder"))))
        #expect(Set(initial.map { $0.content.id }).contains(.favorite(.init(hostID: fixture.secondHost, path: "/work/RemoteCoder"))))
        let initialIDs = Set(initial.map(\.content.id))
        for anchor in initial { try fixture.checkPress(on: anchor) }

        let scroll = try #require(initial.first?.superview).nearestScrollView
        let list = try #require(scroll)
        list.setContentOffset(CGPoint(x: 0, y: 220), animated: false)
        fixture.controller.view.layoutIfNeeded()
        let scrolled = fixture.visibleFavorites
        try #require(!scrolled.isEmpty)
        #expect(scrolled.contains { !initialIDs.contains($0.content.id) })
        for anchor in scrolled { try fixture.checkPress(on: anchor) }
    }

    @Test func aPickerWithoutAHostSwitcherKeepsFavoritesVisible() async throws {
        let fixture = try PickerFixture(hostSwitcher: EmptyView())
        defer { fixture.close() }
        try await fixture.waitForAnchors()
        try fixture.checkPress(on: #require(fixture.visibleFavorites.first))
    }

    @Test func reusedOrDetachedCellCannotReceiveDismissalPreview() async throws {
        let fixture = try PickerFixture(hostSwitcher: Text("Mini · MacBook").frame(height: 44))
        defer { fixture.close() }
        try await fixture.waitForAnchors()
        let anchor = try #require(fixture.visibleFavorites.last)
        let (menu, interaction, configuration) = try fixture.openMenu(on: anchor)
        let original = anchor.content
        #expect(menu.contextMenuInteraction(interaction, configuration: configuration,
                                           dismissalPreviewForItemWithIdentifier: "item" as NSString) != nil)
        anchor.content = ScrollItemMenuContent(id: .browse(.init(hostID: fixture.firstHost, path: "/work/other")),
                                               items: original.items, preview: original.preview, cornerRadius: 14)
        #expect(menu.contextMenuInteraction(interaction, configuration: configuration,
                                           dismissalPreviewForItemWithIdentifier: "item" as NSString) == nil)
        anchor.content = original
        anchor.removeFromSuperview()
        #expect(menu.contextMenuInteraction(interaction, configuration: configuration,
                                           dismissalPreviewForItemWithIdentifier: "item" as NSString) == nil)
        menu.contextMenuInteraction(interaction, willEndFor: configuration, animator: nil)
        #expect(menu.liftedID == nil)
    }

    @MainActor
    private final class PickerFixture {
        typealias Anchor = ScrollItemMenuAnchor<DirectoryMenuID>.AnchorView
        let firstHost = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
        let secondHost = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))
        let window: HostedWindow
        let controller: UIViewController
        let defaults: UserDefaults
        let suite = "DirectoryContextMenuTests.\(UUID().uuidString)"

        init(hostSwitcher: some View) throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            let gateway = GatewayClient(config: .init(url: try #require(URL(string: "ws://127.0.0.1:1/ws")),
                                                      authToken: "test", hostLabel: "Test"), routes: nil)
            let directories = HostDirectories(gateway: gateway, hostID: firstHost, hostLabel: "Mini", defaults: defaults)
            let favorites = FavoriteFolder.list([
                .init(id: firstHost, name: "Mini", paths: ["/work/family-recipes", "/work/RemoteCoder"], remoteHomePath: "/work"),
                .init(id: secondHost, name: "MacBook", paths: ["/work/RemoteCoder"] + (0..<20).map { "/work/folder-\($0)" }, remoteHomePath: "/work")
            ])
            let picker = DirectoryPickerView(directories: directories, favorites: favorites,
                                             currentWorkingDirectory: "/work/RemoteCoder",
                                             prefetchedRootChildren: [DirectoryItem(path: "/work/RemoteCoder")],
                                             folderListID: ObjectIdentifier(directories), hostSwitcher: { hostSwitcher },
                                             onSelectFavorite: { _ in }, onRemoveFavorite: { _ in }, onSelect: { _ in })
                .environment(AppThemeStore())
                .environment(\.dynamicTypeSize, .large)
            controller = UIHostingController(rootView: picker)
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            window = HostedWindow(scene: scene)
            window.show(controller)
        }

        var anchors: [Anchor] { controller.view.descendants.compactMap { $0 as? Anchor } }

        var visibleFavorites: [Anchor] {
            anchors.filter { anchor in
                guard case .favorite = anchor.content.id, let scroll = anchor.nearestScrollView else { return false }
                let point = anchor.convert(CGPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: scroll)
                return scroll.bounds.inset(by: scroll.adjustedContentInset).contains(point)
            }
        }

        func waitForAnchors() async throws {
            for _ in 0..<100 {
                controller.view.layoutIfNeeded()
                if visibleFavorites.count >= 4 {
                    try await Task.sleep(for: .milliseconds(100))
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("The directory picker did not expose visible favorite cells")
        }

        func openMenu(on anchor: Anchor) throws -> (ScrollItemContextMenu<DirectoryMenuID>, UIContextMenuInteraction, UIContextMenuConfiguration) {
            let scroll = try #require(anchor.nearestScrollView)
            let interaction = try #require(scroll.interactions.compactMap { $0 as? UIContextMenuInteraction }
                .first { $0.delegate is ScrollItemContextMenu<DirectoryMenuID> })
            let menu = try #require(interaction.delegate as? ScrollItemContextMenu<DirectoryMenuID>)
            let point = anchor.convert(CGPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: scroll)
            let configuration = try #require(menu.contextMenuInteraction(interaction, configurationForMenuAtLocation: point),
                "No menu for \(anchor.content.id) at \(point), viewport \(scroll.bounds), insets \(scroll.adjustedContentInset)")
            _ = menu.contextMenuInteraction(interaction, configuration: configuration,
                                             highlightPreviewForItemWithIdentifier: "item" as NSString)
            #expect(menu.liftedID == anchor.content.id)
            return (menu, interaction, configuration)
        }

        func checkPress(on anchor: Anchor) throws {
            let (menu, interaction, configuration) = try openMenu(on: anchor)
            menu.contextMenuInteraction(interaction, willEndFor: configuration, animator: nil)
            #expect(menu.liftedID == nil)
        }

        func close() {
            window.close()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}

@MainActor
private extension UIView {
    var descendants: [UIView] { subviews.flatMap { [$0] + $0.descendants } }
    var nearestScrollView: UIScrollView? {
        sequence(first: self, next: \.superview).compactMap { $0 as? UIScrollView }.first
    }
}
