import Foundation
import SwiftUI
import Testing
import UIKit
@testable import RemoteCoder

@MainActor
@Suite(.serialized)
struct OnlyMinePresentationTests {
    @Test func dictationSettingsScreenshot() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let settings = fixture.workspace.transcriptionSettings
        let previousModel = settings.model
        let defaults = fixture.defaults
        let previousChoice = defaults.object(forKey: "transcription.voices")
        defer {
            settings.model = previousModel
            defaults.set(previousChoice, forKey: "transcription.voices")
            settings.reload()
        }
        settings.model = .azureMAITranscribe2
        settings.setVoices(.onlyMine)
        try await capture(NavigationStack {
            SettingsPage(title: "Dictation") { TranscriptionSettingsSection(workspace: fixture.workspace) }
        }.environment(AppThemeStore()), named: "only-mine-settings.png")
    }

    @Test func filteredComposerScreenshot() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let screen = try #require(fixture.workspace.selectedScreen)
        try #require(await screen.prepareDraft())
        let draft = try #require(screen.currentDraft)
        try await screen.drafts.appendDictation(.filtered("Please review the capture pipeline.",
            everyone: "Please review the capture pipeline. A background speaker mentions lunch."), recordingID: UUID(), to: draft)
        try await capture(SyntheticComposer(screen: screen).reasoningPickerOverlay()
            .environment(fixture.workspace.modelPickerPreferences)
            .environment(AppThemeStore()), named: "only-mine-restore.png")
    }

    private func capture(_ content: some View, named name: String) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        let controller = UIHostingController(rootView: content.preferredColorScheme(.light))
        hosted.show(controller)
        defer { hosted.close() }
        #expect(await waitUntil { controller.view.window != nil && controller.view.bounds.width > 0 })
        for _ in 0..<3 {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            await Task.yield()
        }
        var complete = false
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            complete = controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        #expect(complete)
        Attachment.record(try #require(image.pngData()), named: name)
    }
}

private struct SyntheticComposer: View {
    let screen: ChatScreenModel
    @Namespace private var namespace
    @State private var presentations = ComposerPresentations()
    @State private var focused = false

    var body: some View {
        NavigationStack {
            Color.clear
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ChatComposerView(screen: screen, focus: $focused, presentations: presentations,
                        onCancelComposerFocus: {}, onOpenVoiceMode: nil, namespace: namespace,
                        onOpenPendingQuestion: {}, modelOptions: [], onSelectModel: { _ in },
                        onSend: { _ in false }, onQueue: { _ in false }, fileImportRequest: 0)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
                .background { ThemedAppBackground() }
                .navigationTitle("New Chat")
                .inlineNavigationTitle()
        }
    }
}
