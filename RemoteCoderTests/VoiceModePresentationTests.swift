import SwiftUI
import Testing
import UIKit
@testable import RemoteCoder

@MainActor
@Suite(.serialized)
struct VoiceModePresentationTests {
    @MainActor
    private final class Presentation {
        var isPresented = true
    }

    @Test
    func presentingAnEndedCallClosesTheCoverWithoutStartingACall() async throws {
        let fixture = await WorkspaceFixture(notificationsEnabled: false)
        defer { await fixture.cleanUp() }
        let workspace = fixture.workspace
        let window = workspace.attachWindow(opening: nil)
        defer { workspace.detachWindow(window) }
        let screen = try #require(window.screen(for: .init(hostID: fixture.book.id)))
        let voice = screen.target.realtimeVoice
        defer { await voice.stop() }
        let presentation = Presentation()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        let controller = UIHostingController(rootView: VoiceModeView(
            screen: screen,
            entry: .presentCall(UUID()),
            isPresented: Binding(get: { presentation.isPresented }, set: { presentation.isPresented = $0 })
        )
        .environment(workspace.settings)
        .environment(workspace.modelPickerPreferences)
        .environment(AppThemeStore()))
        hosted.show(controller)
        defer { hosted.close() }

        #expect(await waitUntil { !presentation.isPresented })
        #expect(!voice.isActive)
    }
}
