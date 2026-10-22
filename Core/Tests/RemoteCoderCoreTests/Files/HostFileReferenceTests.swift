import Foundation
import Testing
@testable import RemoteCoderCore

struct HostFileReferenceTests {
    @Test func decodesOnceAndPreservesFilenameColonsUnicodeAndLineAnchor() throws {
        let host = UUID()
        let url = try #require(URL(string: "file:///Users/developer/R%C3%A4ksm%C3%B6rg%C3%A5s%20%2520.swift:42#L19"))
        let reference = try #require(try HostFileReference.resolve(url: url, hostID: host, relativeTo: nil))
        #expect(reference.hostID == host)
        #expect(reference.path == "/Users/developer/Räksmörgås %20.swift:42")
        #expect(reference.lineAnchor == 19)
    }

    @Test func resolvesRelativeDocumentLinksAgainstTheRemoteDirectory() throws {
        let host = UUID()
        let url = try #require(URL(string: "../images/My%20Image.png"))
        let reference = try #require(try HostFileReference.resolve(url: url, hostID: host, relativeTo: "/work/docs"))
        #expect(reference.path == "/work/images/My Image.png")
        #expect(throws: HostFileError.sourceDirectoryUnavailable) {
            try HostFileReference.resolve(url: url, hostID: host, relativeTo: nil)
        }
    }

    @Test func rejectsRemoteAuthoritiesTraversalAndNullBytes() throws {
        for value in ["file://other-mac/private/file", "file:///../../file", "file:///tmp/a%00b", "file:///tmp/a?secret=yes"] {
            let url = try #require(URL(string: value))
            #expect(throws: HostFileError.invalidPath) {
                try HostFileReference.resolve(url: url, hostID: UUID(), relativeTo: nil)
            }
        }
        let local = try #require(URL(string: "file://localhost/tmp/file"))
        #expect(try HostFileReference.resolve(url: local, hostID: UUID(), relativeTo: nil)?.path == "/tmp/file")
    }
}
