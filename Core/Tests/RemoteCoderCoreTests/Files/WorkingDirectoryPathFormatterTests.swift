import Foundation
import Testing
@testable import RemoteCoderCore

struct WorkingDirectoryPathFormatterTests {
    @Test func testDisplayPathPreservesFullHomeRelativePath() {
        let path = "/Users/developer/projects/clients/RemoteCoder/host-daemon-rs"

        #expect(WorkingDirectoryPathFormatter.displayPath(path, remoteHomePath: "/Users/developer") == "~/projects/clients/RemoteCoder/host-daemon-rs")
    }

    @Test func testCondensedPathKeepsCompactTwoComponentSummary() {
        let path = "/Users/developer/projects/clients/RemoteCoder/host-daemon-rs"

        #expect(WorkingDirectoryPathFormatter.condensedPath(path, remoteHomePath: "/Users/developer") == "~/RemoteCoder/host-daemon-rs")
    }

    @Test func testDisplayPathDoesNotTreatSiblingPrefixAsHomeDirectory() {
        let path = "/Users/developery/projects/RemoteCoder"

        #expect(WorkingDirectoryPathFormatter.displayPath(path, remoteHomePath: "/Users/developer") == "/Users/developery/projects/RemoteCoder")
    }
}
