import Foundation
import Testing
@testable import RemoteCoderCore

struct FavoriteFolderTests {
    @Test func hostsKeepTheirOrderAndEveryFavoriteNamesItsHost() {
        let mini = UUID()
        let book = UUID()
        let favorites = FavoriteFolder.list([
            .init(id: mini, name: "mac-mini", paths: ["/Users/developer/RemoteCoder", "/Users/developer/ark"],
                  remoteHomePath: "/Users/developer"),
            .init(id: book, name: "macbook", paths: ["/Users/developer/RemoteCoder"], remoteHomePath: "/Users/developer"),
        ])

        #expect(favorites.map(\.id) == [
            .init(hostID: mini, path: "/Users/developer/RemoteCoder"),
            .init(hostID: mini, path: "/Users/developer/ark"),
            .init(hostID: book, path: "/Users/developer/RemoteCoder"),
        ])
        #expect(favorites.map(\.hostName) == ["mac-mini", "mac-mini", "macbook"])
        #expect(favorites.map(\.showsHostLabel) == [true, true, true])
        #expect(favorites.map(\.title) == ["RemoteCoder", "ark", "RemoteCoder"])
        #expect(favorites.map(\.displayPath) == ["~/RemoteCoder", "~/ark", "~/RemoteCoder"])
    }

    @Test func aSingleHostShowsNoHostLabel() {
        let favorites = FavoriteFolder.list([
            .init(id: UUID(), name: "mac-mini", paths: ["/work/ark", "/work"], remoteHomePath: "/work"),
        ])

        #expect(favorites.map(\.showsHostLabel) == [false, false])
        #expect(favorites.map(\.title) == ["ark", "Home"])
    }

    @Test func onlyNamesRepeatedOnOneHostShowTheirHomeRelativePath() {
        let favorites = FavoriteFolder.list([
            .init(id: UUID(), name: "mac-mini",
                  paths: ["/work/clientA/app", "/work/clientB/app", "/work/ark", "/work", "/", "/work/Home"],
                  remoteHomePath: "/work"),
            .init(id: UUID(), name: "macbook", paths: ["/other/ark"], remoteHomePath: "/other"),
        ])

        #expect(favorites.map(\.title) == ["~/clientA/app", "~/clientB/app", "ark", "~", "/", "~/Home", "ark"])
    }
}
