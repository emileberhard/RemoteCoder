import Foundation
import Observation
import SwiftUI
import UIKit
import Testing
@testable import RemoteCoder

@MainActor
struct QuestionEditorTests {
    @Test func localSaveDoesNotImplyAdmissionAndDoubleTapCannotDispatchTwice() async throws {
        let gate = EditorSubmissionGate()
        let id = UUID()
        let prompt = makePrompt()
        let editor = QuestionEditor(prompt: prompt,
            submit: { entries, revision in
                #expect(entries.map(\.index) == [0, 1])
                #expect(revision == QuestionVersion(epoch: "fixture-epoch", revision: 1))
                await gate.wait()
                return id
            }, dismiss: {}, refresh: {}, allowResend: { _ in })
        editor.reconcile(prompt)
        editor.flow.setFreeText("Saved free text", at: 1)
        editor.send(prompt)
        editor.send(prompt)
        await gate.started()
        #expect(editor.isBusy)
        #expect(!editor.wasAdmitted(in: prompt))
        await gate.release()
        #expect(await waitUntil { !editor.isBusy })
        #expect(editor.submissionID == id)
        #expect(!editor.wasAdmitted(in: prompt))
        var admitted = prompt
        admitted.deliveries = [.init(id: id, status: .accepted, indices: [0, 1])]
        #expect(editor.wasAdmitted(in: admitted))
        admitted.deliveries = [.init(id: UUID(), status: .accepted, indices: [0, 1])]
        #expect(!editor.wasAdmitted(in: admitted))
        #expect(await gate.count == 1)
        editor.stop()
    }

    @Test func rejectedSaveKeepsEditingAndExternalPartialAnswerPreservesOtherDraft() async throws {
        enum Failure: LocalizedError { case disk; var errorDescription: String? { "Cannot save the answer" } }
        let prompt = makePrompt()
        let editor = QuestionEditor(prompt: prompt,
            submit: { _, _ in throw Failure.disk }, dismiss: {}, refresh: {}, allowResend: { _ in })
        editor.reconcile(prompt)
        editor.flow.setFreeText("Do not lose my words", at: 1)
        editor.send(prompt)
        #expect(await waitUntil { !editor.isBusy })
        #expect(editor.error == "Cannot save the answer")
        #expect(editor.submissionID == nil)
        let partial = makePrompt(first: .answered)
        editor.reconcile(partial)
        #expect(editor.flow.indices == [1])
        #expect(editor.flow.freeText(at: 1) == "Do not lose my words")
        let entries = try #require(editor.flow.entries(itemID: "q"))
        #expect(entries.map(\.index) == [1])
        #expect(entries.first?.reply.answer == "Do not lose my words")
        editor.stop()
    }

    @Test func dismissedHistoryRequiresExplicitAnswerAnywayAndReceiptStillBlocksDuplicate() {
        let prompt = makePrompt(first: .dismissed, second: .dismissed)
        let editor = QuestionEditor(prompt: prompt,
            submit: { _, _ in UUID() }, dismiss: {}, refresh: {}, allowResend: { _ in })
        editor.reconcile(prompt)
        #expect(editor.flow.indices.isEmpty)
        #expect(!prompt.isPending)
        editor.answerAnyway(prompt)
        #expect(editor.flow.indices == [0, 1])
        #expect(!prompt.isPending)
        var sending = prompt
        sending.deliveries = [.init(id: UUID(), status: .uncertain, indices: [0, 1])]
        editor.reconcile(sending)
        #expect(editor.flow.indices.isEmpty)
        editor.stop()
    }

    @Test func dismissalFailureIsVisibleAndDoesNotManufactureResolution() async throws {
        enum Failure: Error { case full }
        let prompt = makePrompt()
        let editor = QuestionEditor(prompt: prompt,
            submit: { _, _ in UUID() }, dismiss: { throw Failure.full }, refresh: {}, allowResend: { _ in })
        editor.reconcile(prompt)
        editor.dismissQuestion()
        #expect(await waitUntil { !editor.isBusy })
        #expect(editor.error != nil)
        #expect(prompt.isPending)
        #expect(editor.flow.indices == [0, 1])
        editor.stop()
    }

    @Test func replacedHistoryDoesNotReuseAnOldEditorDraft() {
        let prompt = makePrompt()
        var replacement = prompt
        replacement.epoch = "new-history"
        let editor = QuestionEditor(prompt: prompt,
            submit: { _, _ in Issue.record("Old editor must not submit into a new history"); return UUID() },
            dismiss: {}, refresh: {}, allowResend: { _ in })
        editor.flow.setFreeText("Old history draft", at: 0)
        editor.reconcile(replacement)
        editor.send(replacement)
        #expect(editor.flow.indices.isEmpty)
        #expect(!editor.isBusy)
    }
}

private actor EditorSubmissionGate {
    private(set) var count = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var start: CheckedContinuation<Void, Never>?
    func wait() async {
        count += 1
        start?.resume(); start = nil
        await withCheckedContinuation { continuation = $0 }
    }
    func started() async { if count == 0 { await withCheckedContinuation { start = $0 } } }
    func release() { continuation?.resume(); continuation = nil }
}

private func makePrompt(first: QuestionRecord.Slot.Resolution = .pending,
                        second: QuestionRecord.Slot.Resolution = .pending) -> QuestionPrompt {
    let record = QuestionRecord(itemId: "q", turnId: "turn", ordinal: 956, askedAtMs: nil, revision: 1,
        questions: [first, second].enumerated().map { index, resolution in
            .init(index: index, title: "Question \(index)", options: ["A", "B"], resolution: resolution,
                  answer: resolution == .answered ? .init(text: "A", itemId: "reply", clientId: nil, ordinal: 976, atMs: nil) : nil)
        })
    return .init(record: record, epoch: "fixture-epoch", isCurrent: true, deliveries: [])
}


@Suite(.serialized)
@MainActor
struct QuestionCardRenderingTests {
    @Test(arguments: [QuestionRecord.Slot.Resolution.answered, .dismissed, .superseded])
    func resolvedMultiQuestionHistoryCanReconcileDuringFirstRender(resolution: QuestionRecord.Slot.Resolution) async throws {
        let fixture = QuestionRenderingFixture(prompt: makePrompt(first: resolution, second: resolution))
        #expect(fixture.editor.flow.indices.isEmpty, "A historical card must start from its actual resolution")
        try await withCard(fixture) { view in
            try await render(view)
            #expect(fixture.editor.flow.indices.isEmpty)
            #expect(!fixture.prompt.isPending)
            #expect(!fixture.editor.flow.canSend)
        }
    }

    @Test func mountedCardSurvivesTwoQuestionsThenOneThenNone() async throws {
        let fixture = QuestionRenderingFixture(prompt: makePrompt())
        try await withCard(fixture) { view in
            try await render(view)
            #expect(fixture.editor.flow.indices == [0, 1])
            fixture.editor.flow.setFreeText("Keep this draft", at: 1)
            fixture.editor.flow.jump(to: 1)
            try await render(view)

            fixture.prompt = makePrompt(first: .answered)
            try await render(view)
            #expect(fixture.editor.flow.indices == [1])
            #expect(fixture.editor.flow.current == 1)
            #expect(fixture.editor.flow.freeText(at: 1) == "Keep this draft")

            fixture.prompt = makePrompt(first: .answered, second: .dismissed)
            try await render(view)
            #expect(fixture.editor.flow.indices.isEmpty)
            #expect(!fixture.editor.flow.canSend)
        }
    }

    @Test func admissionRemovesAllQuestionsWhileProgressDotsAreMounted() async throws {
        let fixture = QuestionRenderingFixture(prompt: makePrompt())
        try await withCard(fixture) { view in
            try await render(view)
            #expect(fixture.editor.flow.indices == [0, 1])
            fixture.prompt.deliveries = [.init(id: UUID(), status: .accepted, indices: [0, 1])]
            try await render(view)
            #expect(fixture.editor.flow.indices.isEmpty)
            #expect(!fixture.prompt.isPending)
        }
    }

    @Test func retainedDotsKeepOriginalIdentityAndCanRenderAfterTheirFlowShrinks() throws {
        var flow = QuestionFlow(questions: [
            .init(title: "First", options: ["A"]),
            .init(title: "Second", options: ["B"]),
            .init(title: "Third", options: [])
        ])
        flow.updateIndices([0, 2])
        let dots = QuestionProgressDots(flow: flow) { flow.jump(to: $0) }
        #expect(dots.dots.map(\.id) == [0, 2])
        #expect(dots.dots.map(\.isAnswered) == [true, false])
        dots.onSelect(2)
        #expect(flow.current == 2, "Selection carries the original index, not a position in the filtered list")

        flow.setFreeText("A newer draft", at: 2)
        flow.updateIndices([2])
        dots.onSelect(0)
        #expect(flow.current == 2, "A delayed action for a removed question must be ignored")
        let movedToRemovedQuestion = flow.jump(to: 0)
        #expect(!movedToRemovedQuestion)
        #expect(dots.dots.map(\.isAnswered) == [true, false], "Old labels must read immutable values")
        let renderer = ImageRenderer(content: dots.environment(AppThemeStore()).frame(width: 300))
        #expect(renderer.uiImage != nil)

        flow.updateIndices([])
        dots.onSelect(2)
        let movedInRetiredFlow = flow.jump(to: 2)
        #expect(!movedInRetiredFlow)
        #expect(flow.indices.isEmpty)
        let retiredRenderer = ImageRenderer(content: dots.environment(AppThemeStore()).frame(width: 300))
        #expect(retiredRenderer.uiImage != nil, "Even a fully retired dot snapshot must remain safe to evaluate")
    }

    private func withCard(_ fixture: QuestionRenderingFixture, check: (UIView) async throws -> Void) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        let host = UIHostingController(rootView: QuestionRenderingFixtureView(fixture: fixture)
            .environment(AppThemeStore()))
        hosted.show(host)
        defer { fixture.editor.stop(); hosted.close() }
        try await check(host.view)
    }

    private func render(_ view: UIView) async throws {
        // Exercise deferred ForEach child evaluation across real SwiftUI updates.
        for _ in 0..<5 {
            view.setNeedsLayout()
            view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(view.bounds.width > 0 && view.bounds.height > 0)
    }
}

@MainActor @Observable
private final class QuestionRenderingFixture {
    var prompt: QuestionPrompt
    let editor: QuestionEditor

    init(prompt: QuestionPrompt) {
        self.prompt = prompt
        editor = QuestionEditor(prompt: prompt,
            submit: { _, _ in Issue.record("Rendering must not submit an answer"); return UUID() },
            dismiss: { Issue.record("Rendering must not dismiss a question") },
            refresh: {}, allowResend: { _ in Issue.record("Rendering must not resend") })
    }
}

private struct QuestionRenderingFixtureView: View {
    let fixture: QuestionRenderingFixture

    var body: some View {
        ScrollView {
            QuestionCard(prompt: fixture.prompt, editor: fixture.editor).padding()
        }
    }
}
