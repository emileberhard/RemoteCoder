import Foundation
import SwiftUI
import Testing
import UIKit
@testable import RemoteCoder

@MainActor @Suite(.timeLimit(.minutes(1)))
struct ConversationAgentsPlaceholderTests {
    @Test func confirmedEmptyResultKeepsItsPresentationDuringRevalidation() async throws {
        let server = try FakeGatewayServer()
        let gateway = GatewayClient(config: .init(url: try await server.startURL(), authToken: "fixture", hostLabel: "Fixture"), routes: nil)
        let model = ConversationAgentsModel(address: .init(hostID: UUID(), threadID: "parent"), gateway: gateway)
        do {
            let initial = try rendered(model)
            await model.refresh()
            try #require(model.hasLoaded && model.agents.isEmpty && model.error == nil)
            let confirmed = try rendered(model)
            #expect(initial != confirmed)
            await server.holdAgents()
            let refresh = Task { await model.refresh() }
            defer { refresh.cancel() }
            try #require(await waitUntil { await server.requests("conversation/agents/list").count == 2 })
            #expect(model.isRefreshing)
            let revalidating = try rendered(model)
            await server.releaseAgents()
            await refresh.value
            #expect(confirmed == revalidating)
            await gateway.retire()
            await server.stop()
        } catch {
            await server.releaseAgents()
            await gateway.retire()
            await server.stop()
            throw error
        }
    }

    private func rendered(_ model: ConversationAgentsModel) throws -> Data {
        let renderer = ImageRenderer(content: ConversationAgentsPlaceholder(model: model)
            .environment(\.colorScheme, .light).frame(width: 320, height: 240))
        return try #require(renderer.uiImage?.pngData())
    }
}
