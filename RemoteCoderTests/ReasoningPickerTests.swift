import Foundation
import SwiftUI
import Testing
@testable import RemoteCoder

@MainActor
struct ReasoningPickerTests {
    @Test(arguments: [
        ([ReasoningEffort.low, .xhigh], [0.25, 1.0]),
        ([.medium, .high, .xhigh], [0.25, 0.625, 1.0]),
        ([.low, .medium, .high, .xhigh], [0.25, 0.5, 0.75, 1.0]),
        ([.low, .medium, .high, .xhigh, .max, .ultra], [0.25, 0.4, 0.55, 0.7, 0.85, 1.0])
    ])
    func gaugeSpansQuarterToFullAcrossTheEnabledEfforts(
        efforts: [ReasoningEffort], expected: [Double]
    ) {
        for (effort, fraction) in zip(efforts, expected) {
            let position = ReasoningGaugePosition(efforts: efforts, selection: .effort(effort))
            #expect(abs(position.fraction - fraction) < 0.000001)
            #expect(!position.isAutomatic)
        }
    }

    @Test func singleEffortRemainsTheMaximumAndAutomaticKeepsItsOwnDisplay() {
        let single = ReasoningGaugePosition(efforts: [.high], selection: .effort(.high))
        #expect(single.fraction == 1)
        #expect(!single.isAutomatic)
        for efforts: [ReasoningEffort] in [[], [.high], [.low, .medium, .high]] {
            let automatic = ReasoningGaugePosition(efforts: efforts, selection: .automatic)
            #expect(automatic.fraction == 1)
            #expect(automatic.isAutomatic)
        }
    }

    @Test func liftDetentsAndEndpointsHaveOneOwner() throws {
        var events: [HapticEvent] = []
        let picker = ReasoningPickerPresentation { event, _ in events.append(event) }
        let session = try open(picker)
        #expect(events == [.lift])
        session.select(index: 1)
        session.select(index: 1)
        session.select(index: session.choices.count - 1)
        session.select(index: session.choices.count - 1)
        session.select(index: 0)
        #expect(events == [.lift, .sliderStep, .sliderMaximum, .sliderMinimum])
    }

    @Test func cancelledAndInvalidatedSessionsNeverCommitOrEmitRelease() throws {
        var events: [HapticEvent] = []
        var committed = false
        let picker = ReasoningPickerPresentation { event, _ in events.append(event) }
        let session = try open(picker, held: true) { _ in committed = true }
        session.select(index: 1)
        session.update(at: CGPoint(x: session.frame.midX, y: session.frame.midY - 160))
        let before = events
        picker.finish(session)
        session.select(index: 0)
        #expect(events == before)
        #expect(!committed)
        #expect(picker.session == nil)
    }

    @Test func restoringPreviewIsSilentAndTheNextGrabStillWorks() throws {
        var events: [HapticEvent] = []
        let picker = ReasoningPickerPresentation { event, _ in events.append(event) }
        let session = try open(picker)
        session.beginDrag()
        session.select(index: 1)
        let before = events
        session.resetPreview()
        #expect(events == before)
        #expect(session.selection == session.initial)
        session.beginDrag()
        #expect(events.last == .sliderGrab)
    }

    @Test func replacingOrResizingInvalidatesThePreviousOwner() throws {
        var events: [HapticEvent] = []
        let picker = ReasoningPickerPresentation { event, _ in events.append(event) }
        let first = try open(picker)
        let second = try open(picker)
        let before = events
        first.select(index: 1)
        picker.finish(first)
        #expect(events == before)
        #expect(picker.session === second)
        picker.updateViewport(CGRect(x: 0, y: 0, width: 844, height: 390))
        second.select(index: 1)
        #expect(events == before)
    }

    @Test func releaseCommitsChangedSelectionOnlyOnce() throws {
        var events: [HapticEvent] = []
        var commits: [ReasoningSelection] = []
        let picker = ReasoningPickerPresentation { event, _ in events.append(event) }
        let session = try open(picker, held: true) { commits.append($0) }
        session.select(index: 1)
        picker.finish(session)
        picker.finish(session)
        #expect(events == [.lift, .sliderStep, .sliderRelease])
        #expect(commits.count == 1)
    }

    @Test func returnAnimationRetainsOnlyTheVisualAndCannotClearANewerSession() throws {
        let picker = ReasoningPickerPresentation { _, _ in }
        let first = try open(picker)
        picker.dismiss()
        #expect(picker.session == nil)
        #expect(picker.presentedSession === first)
        let second = try open(picker)
        picker.completeDismissal(of: first)
        #expect(picker.presentedSession === second)
        picker.dismiss()
        picker.completeDismissal(of: second)
        #expect(picker.presentedSession == nil)
    }

    @Test func motionStartsAtTheGaugeAndViewportChangesRemoveThePresentation() throws {
        let picker = ReasoningPickerPresentation { _, _ in }
        let session = try open(picker)
        #expect(session.sourceFrame == CGRect(x: 228, y: 690, width: 24, height: 24))
        #expect(session.frame.midY == 690)
        picker.updateViewport(CGRect(x: 0, y: 0, width: 844, height: 390))
        #expect(picker.session == nil)
        #expect(picker.presentedSession == nil)
    }

    @Test func detentsHaveADirectionalDeadBandButStillReachBothEndpoints() {
        let count = 5
        var index = 1
        for position in [1.49, 1.51, 1.55, 1.59, 1.48] {
            index = ReasoningDetents.index(at: position / 4, count: count, current: index)
            #expect(index == 1)
        }
        index = ReasoningDetents.index(at: 1.61 / 4, count: count, current: index)
        #expect(index == 2)
        for position in [1.51, 1.49, 1.42] {
            index = ReasoningDetents.index(at: position / 4, count: count, current: index)
            #expect(index == 2)
        }
        #expect(ReasoningDetents.index(at: 1.39 / 4, count: count, current: index) == 1)
        #expect(ReasoningDetents.index(at: 1, count: count, current: 0) == 4)
        #expect(ReasoningDetents.index(at: 0, count: count, current: 4) == 0)
        #expect(ReasoningDetents.index(at: 0.62, count: 2, current: 0) == 1)
    }

    @Test func finalPositionIsCommittedWithOneReleaseNotAnotherDetent() throws {
        var events: [HapticEvent] = []
        var committed: ReasoningSelection?
        let picker = ReasoningPickerPresentation { event, _ in events.append(event) }
        let session = try open(picker) { committed = $0 }
        session.beginDrag()
        let beforeRelease = events
        picker.finish(session, at: CGPoint(x: session.frame.maxX, y: session.frame.midY))
        #expect(committed == session.choices.last)
        #expect(events == beforeRelease + [.sliderRelease])
        picker.finish(session, at: CGPoint(x: session.frame.minX, y: session.frame.midY))
        #expect(events == beforeRelease + [.sliderRelease])
    }

    @Test func heldFinalPositionAndVerticalCancellationKeepTheirMeaning() throws {
        var events: [HapticEvent] = []
        var committed: ReasoningSelection?
        let picker = ReasoningPickerPresentation { event, _ in events.append(event) }
        let session = try open(picker, held: true) { committed = $0 }
        session.updateHold(at: CGPoint(x: session.frame.midX, y: session.frame.midY))
        picker.finish(session, at: CGPoint(x: session.frame.maxX, y: session.frame.midY))
        #expect(committed == session.choices.last)
        #expect(events == [.lift, .sliderRelease])
        let cancelled = try open(picker, held: true) { committed = $0 }
        cancelled.updateHold(at: CGPoint(x: cancelled.frame.midX, y: cancelled.frame.midY))
        let before = events
        committed = nil
        picker.finish(cancelled, at: CGPoint(x: cancelled.frame.maxX, y: cancelled.frame.midY + 160))
        #expect(committed == nil)
        #expect(events == before)
    }

    @Test(arguments: [
        (ReasoningSelection.effort(.xhigh), ReasoningSelection.effort(.high), 2),
        (.effort(.xhigh), .effort(.medium), 4),
        (.effort(.xhigh), .effort(.low), 6),
        (.effort(.low), .effort(.xhigh), 6),
        (.automatic, .effort(.low), 2),
        (.automatic, .effort(.ultra), 12)
    ])
    func gaugeTicksScaleWithAcceptedDistance(from: ReasoningSelection,
        to: ReasoningSelection, count: Int) async throws {
        let cadence = try #require(ReasoningGaugeFeedback(from: from, to: to,
            efforts: ReasoningEffort.allCases))
        var events: [HapticEvent] = []
        var deadlines: [Duration] = []
        await cadence.play(isCurrent: { true }, waitForTick: { offset in
            #expect(events.count == deadlines.count + 1)
            deadlines.append(offset)
            return true
        }, feedback: { events.append($0) })
        #expect(cadence.tickCount == count)
        #expect(events == Array(repeating: .sliderStep, count: count))
        #expect(deadlines == Array(cadence.tickOffsets.dropFirst()))
        #expect(cadence.tickOffsets.first == .zero)
        #expect(deadlines.allSatisfy { $0 < .seconds(cadence.animationDuration) })
        let gaps = zip(cadence.tickOffsets, cadence.tickOffsets.dropFirst()).map { $1 - $0 }
        #expect(gaps.allSatisfy { $0 >= .milliseconds(60) })
        #expect(zip(gaps, gaps.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(cadence.animationDuration < 1)
    }

    @Test func gaugeDistanceUsesVisibleLevelsAndDoesNotInventAnAdjustment() throws {
        let visible: [ReasoningEffort] = [.low, .high, .xhigh]
        let cadence = try #require(ReasoningGaugeFeedback(from: .effort(.low), to: .effort(.high), efforts: visible))
        #expect(cadence.tickCount == 2)
        #expect(cadence.animationDuration == 0.3)
        #expect(ReasoningGaugeFeedback(from: .effort(.high), to: .effort(.high), efforts: visible) == nil)
        #expect(ReasoningGaugeFeedback(from: .automatic, to: .automatic, efforts: visible) == nil)
        #expect(ReasoningGaugeFeedback(from: .effort(.medium), to: .effort(.high), efforts: visible) == nil)
        #expect(ReasoningGaugeFeedback(from: .effort(.high), to: .effort(.ultra), efforts: visible) == nil)
    }

    @Test func gaugeTicksStopAfterTheirChangeIsReplaced() async throws {
        let cadence = try multiStepGaugeFeedback()
        var current = true
        var events: [HapticEvent] = []
        var waits = 0
        await cadence.play(isCurrent: { current }, waitForTick: { _ in
            waits += 1
            current = false
            return true
        }, feedback: { events.append($0) })
        #expect(events == [.sliderStep])
        #expect(waits == 1)
        await cadence.play(isCurrent: { false }, waitForTick: { _ in
            waits += 1
            return true
        }, feedback: { events.append($0) })
        #expect(events == [.sliderStep])
        #expect(waits == 1)
    }

    @Test func gaugeTicksDoNotCatchUpAfterMissingADeadline() async throws {
        let cadence = try multiStepGaugeFeedback()
        var events: [HapticEvent] = []
        var waits = 0
        await cadence.play(isCurrent: { true }, waitForTick: { _ in
            waits += 1
            return false
        }, feedback: { events.append($0) })
        #expect(events == [.sliderStep])
        #expect(waits == 1)
    }

    @Test func cancelledGaugeSleepStopsWithoutACompletionPulse() async throws {
        let cadence = try multiStepGaugeFeedback()
        var events: [HapticEvent] = []
        await cadence.play(isCurrent: { true }, waitForTick: { _ in
            throw CancellationError()
        }, feedback: { events.append($0) })
        #expect(events == [.sliderStep])
    }

    @Test func gaugeTicksCheckTaskCancellationEvenWhenTheWaitReturns() async throws {
        let cadence = try multiStepGaugeFeedback()
        let task = Task { @MainActor in
            var events: [HapticEvent] = []
            await cadence.play(isCurrent: { true }, waitForTick: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            }, feedback: { events.append($0) })
            return events
        }
        let events = await task.value
        #expect(events == [.sliderStep])
    }

    private func multiStepGaugeFeedback() throws -> ReasoningGaugeFeedback {
        try #require(ReasoningGaugeFeedback(from: .effort(.xhigh), to: .effort(.low),
            efforts: [.low, .medium, .high, .xhigh]))
    }

    private func open(_ picker: ReasoningPickerPresentation, held: Bool = false,
                      commit: @escaping (ReasoningSelection) -> Void = { _ in }) throws -> ReasoningPickerPresentation.Session {
        picker.updateViewport(CGRect(x: 0, y: 0, width: 390, height: 844))
        let model = ClaudeModelCatalog.defaultModel
        return try #require(picker.present(owner: UUID(), model: model, efforts: model.reasoningEfforts, selection: .automatic,
            source: CGRect(x: 228, y: 690, width: 24, height: 24),
            held: held, isRightToLeft: false, commit: commit))
    }
}
