import Foundation
import Testing
@testable import RemoteCoderCore

struct MacBookGatewaySeedTests {
    @Test func configuredMacBookIsSelectedWithoutTheMini() throws {
        let id = try #require(UUID(uuidString: "6A71F6AF-4C5B-47F8-8A59-CFE189450A44"))
        let configuration = LocalConfiguration(macMiniHostname: "mini.example", macBookHostname: "macbook.example",
            codexGatewayPort: 8787, codexGatewayAuthToken: "fixture-token")
        let seed = try GatewayHostConfiguration.macBookSeed(matching: id, from: configuration)
        #expect(seed.id == id)
        #expect(seed.hostname == "macbook.example")
        #expect(GatewayHostConfiguration.builtInDefaults(from: configuration).contains(seed))
    }

    @Test func aMiniPlanIsRejectedEvenWhenBothSeedsAreConfigured() throws {
        let id = try #require(UUID(uuidString: "9F8C0E05-5F3B-4A0F-B55D-FAE0E2D70352"))
        let configuration = LocalConfiguration(macMiniHostname: "mini.example", macBookHostname: "macbook.example",
            codexGatewayAuthToken: "fixture-token")
        #expect(throws: GatewayHostConfiguration.MacBookSeedError.wrongHost) {
            try GatewayHostConfiguration.macBookSeed(matching: id, from: configuration)
        }
    }

    @Test func aMissingMacBookSeedNeverFallsBackToTheMiniOrLocalGateway() throws {
        let id = try #require(UUID(uuidString: "6A71F6AF-4C5B-47F8-8A59-CFE189450A44"))
        for configuration in [LocalConfiguration(macMiniHostname: "mini.example", codexGatewayAuthToken: "fixture-token"),
                              LocalConfiguration(codexGatewayAuthToken: "fixture-token")] {
            #expect(throws: GatewayHostConfiguration.MacBookSeedError.unavailable) {
                try GatewayHostConfiguration.macBookSeed(matching: id, from: configuration)
            }
        }
    }

    @Test func invalidMacBookCredentialsFailBeforeConstructingAHostStore() throws {
        let id = try #require(UUID(uuidString: "6A71F6AF-4C5B-47F8-8A59-CFE189450A44"))
        #expect(throws: GatewayHostConfiguration.MacBookSeedError.invalid) {
            try GatewayHostConfiguration.macBookSeed(matching: id, from: LocalConfiguration(macBookHostname: "macbook.example"))
        }
    }
}
