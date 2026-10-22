import Foundation
import Testing
@testable import RemoteCoderCore

struct DirectoryListingTests {
    @Test func responseInitFiltersHiddenEntriesAndNonDirectoriesThenSortsByName() {
        let response = CodexAppServerV2.FsReadDirectoryResponse(entries: [
            .init(fileName: "zebra", isDirectory: true),
            .init(fileName: ".git", isDirectory: true),
            .init(fileName: "README.md", isDirectory: false),
            .init(fileName: "apple", isDirectory: true),
        ])

        let listing = DirectoryListing(path: "/home/project", response: response)

        #expect(listing.childNames == ["apple", "zebra"])
    }

    @Test func childItemsAreAbsolutePathsUnderTheListedDirectory() {
        let listing = DirectoryListing(path: "/home/project", childNames: ["apple", "zebra"])

        #expect(listing.childItems.map(\.path) == ["/home/project/apple", "/home/project/zebra"])
    }
}
