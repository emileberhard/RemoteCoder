import Foundation
import Testing
@testable import RemoteCoderCore

struct HostHTMLDocumentTests {
    @Test(arguments: [
        ("README.md", "/Users/developer/reports/nested/README.md", nil as Int?),
        ("100%2520ready.txt", "/Users/developer/reports/nested/100%20ready.txt", nil),
        ("styles.css?v=2", "/Users/developer/reports/nested/styles.css", nil)
    ])
    func linksKeepTheRemoteDirectoryAndDecodeOnce(link: String, path: String, anchor: Int?) throws {
        let hostID = UUID()
        let reference = try HostFileReference(hostID: hostID, path: "/Users/developer/reports/nested/index.html")
        let lease = HostFileLease(id: UUID(), reference: reference,
            metadata: HostFileMetadata(path: reference.path, name: "index.html", bytes: 10, modifiedAt: 0, revision: "test"),
            url: URL(filePath: "/cache/original/index.html"), downloadedAt: .now)
        let document = try HostHTMLDocument(lease: lease)
        let destination = try #require(URL(string: link, relativeTo: document.url)?.absoluteURL)
        let fileURL = try #require(document.remoteFileURL(for: destination))
        let resolved = try #require(try HostFileReference.resolve(url: fileURL, hostID: hostID, relativeTo: nil))
        #expect(resolved.hostID == hostID)
        #expect(resolved.path == path)
        #expect(resolved.lineAnchor == anchor)
    }

    @Test func anchorsStayInTheDocumentAndForeignOriginsCannotBecomeHostReads() throws {
        let reference = try HostFileReference(hostID: UUID(), path: "/Users/developer/reports/100%20 ready.html")
        let lease = HostFileLease(id: UUID(), reference: reference,
            metadata: HostFileMetadata(path: reference.path, name: "100%20 ready.html", bytes: 10, modifiedAt: 0, revision: "test"),
            url: URL(filePath: "/cache/original/file.html"), downloadedAt: .now)
        let document = try HostHTMLDocument(lease: lease)
        #expect(document.contains(try #require(URL(string: "#section", relativeTo: document.url)?.absoluteURL)))
        #expect(!document.contains(try #require(URL(string: "other.html", relativeTo: document.url)?.absoluteURL)))
        for link in ["host-file-preview://other/tmp/private.html", "https://example.com/tmp/file.html",
                     "host-file-preview://user@\(reference.hostID.uuidString.lowercased())/tmp/file.html"] {
            #expect(document.remoteFileURL(for: try #require(URL(string: link))) == nil)
        }
        let refreshed = HostFileLease(id: UUID(), reference: reference, metadata: lease.metadata,
                                     url: lease.url, downloadedAt: .now)
        #expect(try HostHTMLDocument(lease: refreshed).url != document.url)
        #expect(document.contains(try #require(URL(string: "?v=2", relativeTo: document.url)?.absoluteURL)))
        let absolute = try #require(URL(string: "file:///Users/developer/reports/My%2520Report.html?v=2#section"))
        let preview = try #require(document.previewURL(for: absolute))
        #expect(preview.host == document.url.host)
        #expect(preview.scheme == HostHTMLDocument.scheme)
        #expect(preview.query == "v=2")
        #expect(preview.fragment == "section")
        #expect(document.remoteFileURL(for: preview)?.path == "/Users/developer/reports/My%20Report.html")
        #expect(document.previewURL(for: try #require(URL(string: "file://other-mac/tmp/report.html"))) == nil)
        #expect(document.previewURL(for: try #require(URL(string: "file://localhost/Users/developer/reports/report.html")))?.host == document.url.host)
        for link in ["../private.txt", "/tmp/private.txt", "%2e%2e/private.txt", "assets/%2e%2e/%2e%2e/private.txt", "../reports-other/private.txt"] {
            let destination = try #require(URL(string: link, relativeTo: document.url)?.absoluteURL)
            #expect(document.remoteFileURL(for: destination) == nil)
        }
    }
}
