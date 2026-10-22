import Foundation
import Testing
@testable import RemoteCoderCore

struct BuildIdentityTests {
    private let commit = "1a2b3c4d0123456789abcdef0123456789abcdef"

    @Test func releaseAppIncludesBuildNumberAndFullCommit() {
        let identity = BuildIdentity(info: [
            "CFBundleShortVersionString": "3.20.0", "CFBundleVersion": "3020000",
            "RemoteCoderSourceCommit": commit, "RemoteCoderSourceModified": "false",
        ])
        #expect(identity.display == "3.20.0 (3020000) · 1a2b3c4d")
        #expect(identity.commit == commit)
        #expect(identity.modified == false)
    }

    @Test(arguments: [true, false]) func developmentAppReportsModification(modified: Bool) {
        let identity = BuildIdentity(info: [
            "CFBundleShortVersionString": "0.0.0", "CFBundleVersion": "1.2.3",
            "RemoteCoderSourceCommit": commit, "RemoteCoderSourceModified": modified ? "true" : "false",
        ])
        #expect(identity.version == "dev")
        #expect(identity.display == (modified ? "Dev · 1a2b3c4d (modified)" : "Dev · 1a2b3c4d"))
    }

    @Test(arguments: ["", "unrecorded", "1a2b3c4d", String(repeating: "g", count: 40)])
    func unknownCommitIsAbsent(value: String) {
        let identity = BuildIdentity(info: ["RemoteCoderSourceCommit": value, "RemoteCoderSourceModified": "unrecorded"])
        #expect(identity.commit == nil)
        #expect(identity.modified == nil)
        #expect(identity.display == "Dev")
    }

    @Test func modifiedOrIncompleteAppCannotClaimRelease() {
        let modified = BuildIdentity(info: [
            "CFBundleShortVersionString": "3.20.0", "RemoteCoderSourceCommit": commit,
            "RemoteCoderSourceModified": "true",
        ])
        #expect(modified.display == "Dev · 1a2b3c4d (modified)")
        let unknown = BuildIdentity(info: ["CFBundleShortVersionString": "3.20.0", "RemoteCoderSourceModified": "false"])
        #expect(unknown.display == "Dev")
        #expect(BuildIdentity(info: [:]).modified == nil)
    }

    @Test func gatewayReleaseDecodesWithoutAppBuildNumber() throws {
        let data = Data("{\"version\":\"3.20.0\",\"commit\":\"\(commit)\",\"modified\":false}".utf8)
        let identity = try JSONDecoder().decode(BuildIdentity.self, from: data)
        #expect(identity.display == "3.20.0 · 1a2b3c4d")
        #expect(identity.commit == commit)
    }

    @Test(arguments: [true, false]) func gatewayDevelopmentDecodes(modified: Bool) throws {
        let data = Data("{\"version\":\"dev\",\"commit\":\"\(commit)\",\"modified\":\(modified)}".utf8)
        let identity = try JSONDecoder().decode(BuildIdentity.self, from: data)
        #expect(identity.display == (modified ? "Dev · 1a2b3c4d (modified)" : "Dev · 1a2b3c4d"))
    }

    @Test func gatewayUnknownValuesRemainUnknown() throws {
        let identity = try JSONDecoder().decode(BuildIdentity.self, from: Data(#"{"version":"dev","commit":null,"modified":null}"#.utf8))
        #expect(identity.commit == nil)
        #expect(identity.modified == nil)
        #expect(identity.display == "Dev")
    }

    @Test(arguments: [
        #"{"version":"3.20.0","commit":null,"modified":false}"#,
        #"{"version":"3.20.0","commit":"1a2b3c4d0123456789abcdef0123456789abcdef","modified":true}"#,
        #"{"version":"3.1000.0","commit":"1a2b3c4d0123456789abcdef0123456789abcdef","modified":false}"#,
    ])
    func invalidGatewayReleaseIsRejected(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BuildIdentity.self, from: Data(json.utf8))
        }
    }
}
