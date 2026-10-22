import Foundation
import Testing
@testable import RemoteCoderCore

struct DirectoryFavoritesReplicaTests {
    @Test func legacyFavoritesKeepTheirOrderAsPendingAddsAndDropRelativePaths() throws {
        let replica = DirectoryFavoritesReplica(legacyPaths: ["/work/newest", "~/home-relative", "/work/oldest"])

        #expect(replica.paths == ["/work/newest", "/work/oldest"])
        #expect(replica.pending == [.add("/work/oldest"), .add("/work/newest")])
        let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(replica.pending)) as? [[String: String]]
        #expect(wire == [["op": "add", "path": "/work/oldest"], ["op": "add", "path": "/work/newest"]])
    }

    @Test func pendingChangesStayVisibleUntilTheHostAcknowledgesThem() {
        var replica = DirectoryFavoritesReplica()
        replica.replace(with: DirectoryFavorites(revision: 3, paths: ["/a", "/b"]))
        let admitted = [replica.record(.remove("/a")), replica.record(.add("/c"))]
        #expect(admitted == [true, true])
        #expect(replica.paths == ["/c", "/b"])

        replica.acknowledge(1, current: DirectoryFavorites(revision: 4, paths: ["/b"]))
        #expect(replica.pending == [.add("/c")])
        #expect(replica.paths == ["/c", "/b"])

        replica.reject(1)
        #expect(replica.paths == ["/b"])
    }

    @Test func onlyPathsTheHostAcceptsAreQueuedAndTheQueueIsBounded() {
        var replica = DirectoryFavoritesReplica()
        let validity = [replica.record(.add("relative")), replica.record(.add("/line\nbreak")),
                        replica.record(.add("/ends with space "))]
        #expect(validity == [false, false, true])
        replica.reject(1)
        let filled = (0..<DirectoryFavoritesReplica.changeLimit).map { replica.record(.add("/\($0)")) }
        #expect(filled == Array(repeating: true, count: DirectoryFavoritesReplica.changeLimit))
        let overflow = replica.record(.add("/refused"))
        #expect(!overflow)
        #expect(!replica.paths.contains("/refused"))
    }

    @Test func notificationsApplyOnlyForwardWhileAReadIsAuthoritative() {
        var replica = DirectoryFavoritesReplica()
        replica.receive(DirectoryFavorites(revision: 5, paths: ["/new"]))
        replica.receive(DirectoryFavorites(revision: 4, paths: ["/old"]))
        #expect(replica.paths == ["/new"])

        replica.replace(with: DirectoryFavorites(revision: 1, paths: ["/after-reset"]))
        #expect(replica.paths == ["/after-reset"])
    }
}
