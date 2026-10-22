import Foundation
import Testing
@testable import RemoteCoderCore

struct RealtimeVoiceTranscriptTests {
    @Test func interruptionSealsOnlyAssistantTextAndKeepsIdenticalOutputIndependent() throws {
        for nextText in ["Independent B", "Generated A"] {
            var transcript = RealtimeVoiceTranscriptState()
            _ = transcript.append(delta: "Caller partial", role: .user)
            _ = transcript.append(delta: "Generated A", role: .assistant)

            let interruption = transcript.interruptAssistant()
            let interrupted = try #require(interruption)
            #expect(interrupted.role == .assistant)
            #expect(interrupted.text == "Generated A")
            #expect(transcript.liveAssistantText.isEmpty)
            #expect(transcript.liveUserText == "Caller partial")

            _ = transcript.append(delta: nextText, role: .assistant)
            let completion = transcript.complete(text: "Uncorrelated final revision", role: .assistant)
            let completed = try #require(completion)
            #expect(completed.id != interrupted.id)
            #expect(transcript.entries.map(\.text) == ["Generated A", nextText])
            #expect(transcript.liveAssistantText.isEmpty)
            #expect(transcript.liveUserText == "Caller partial")
        }
    }

    private enum OldFinalOrdering: CaseIterable {
        case beforeNewDelta, afterNewDelta, absent
    }

    @Test func oldFinalOrderingNeverImportsTextOrDuplicatesNewDeltas() {
        for ordering in OldFinalOrdering.allCases {
            var transcript = RealtimeVoiceTranscriptState()
            _ = transcript.append(delta: "Generated A", role: .assistant)
            _ = transcript.interruptAssistant()
            if ordering == .beforeNewDelta {
                _ = transcript.complete(text: "Uncorrelated old final", role: .assistant)
            }
            _ = transcript.append(delta: "B first", role: .assistant)
            if ordering == .afterNewDelta {
                _ = transcript.complete(text: "Uncorrelated old final", role: .assistant)
            }
            _ = transcript.append(delta: " and second", role: .assistant)
            _ = transcript.complete(text: "Uncorrelated new final", role: .assistant)
            let repeatedFinal = transcript.complete(text: "Repeated final", role: .assistant)

            #expect(repeatedFinal == nil)
            let expected = ordering == .afterNewDelta
                ? ["Generated A", "B first", "and second"]
                : ["Generated A", "B first and second"]
            #expect(transcript.entries.map(\.text) == expected)
            #expect(transcript.liveAssistantText.isEmpty)
        }
    }

    @Test func deltaOnlyPolicySurvivesFinalsErrorsAndEmptyDeltasWithoutAffectingCaller() {
        var transcript = RealtimeVoiceTranscriptState()
        _ = transcript.append(delta: "Caller partial", role: .user)
        _ = transcript.append(delta: "Generated A", role: .assistant)
        _ = transcript.interruptAssistant()
        for _ in 0..<2 {
            let interruption = transcript.interruptAssistant()
            let emptyDelta = transcript.append(delta: "", role: .assistant)
            let final = transcript.complete(text: "Uncorrelated final-only text", role: .assistant)
            #expect(interruption == nil)
            #expect(!emptyDelta)
            #expect(final == nil)
        }
        _ = transcript.append(delta: "Generated B", role: .assistant)
        _ = transcript.interruptAssistant()
        _ = transcript.complete(text: "Uncorrelated B revision", role: .assistant)
        _ = transcript.append(delta: " continued", role: .user)
        #expect(transcript.liveUserText == "Caller partial continued")
        _ = transcript.complete(text: "Caller authoritative final", role: .user)
        _ = transcript.complete(text: "Still unsupported final-only text", role: .assistant)
        #expect(transcript.entries.map(\.text) == ["Generated A", "Generated B", "Caller authoritative final"])
        #expect(transcript.entries.map(\.role) == [.assistant, .assistant, .user])
        #expect(transcript.liveUserText.isEmpty)
    }

    @Test func errorWithoutOpenAssistantOutputPreservesFinalOnlyTextAndRevisions() {
        var transcript = RealtimeVoiceTranscriptState()
        _ = transcript.append(delta: "Caller partial", role: .user)
        _ = transcript.append(delta: "Initial delta", role: .assistant)
        _ = transcript.complete(text: "Initial final revision", role: .assistant)
        let firstInterruption = transcript.interruptAssistant()
        let repeatedInterruption = transcript.interruptAssistant()
        #expect(firstInterruption == nil)
        #expect(repeatedInterruption == nil)
        _ = transcript.complete(text: "Final-only answer", role: .assistant)
        #expect(transcript.entries.map(\.text) == ["Initial final revision", "Final-only answer"])
        #expect(transcript.liveUserText == "Caller partial")
    }

    @Test func identicalDeltasContributeOnceEachAfterInterruption() {
        var transcript = RealtimeVoiceTranscriptState()
        _ = transcript.append(delta: "Same", role: .assistant)
        _ = transcript.interruptAssistant()
        _ = transcript.append(delta: "Same", role: .assistant)
        _ = transcript.append(delta: "Same", role: .assistant)
        _ = transcript.complete(text: "Same", role: .assistant)
        #expect(transcript.entries.map(\.text) == ["Same", "SameSame"])
    }

    @Test func sameProviderReceiptAndRecoveryPreserveDeltaOnlyPolicyAndOpenOutput() {
        var transcript = RealtimeVoiceTranscriptState()
        let connectionID = UUID()
        _ = transcript.beginProviderSession(connectionID: connectionID)
        _ = transcript.append(delta: "Generated A", role: .assistant)
        _ = transcript.interruptAssistant()
        _ = transcript.append(delta: "Generated B", role: .assistant)

        let duplicateReceipt = transcript.beginProviderSession(connectionID: connectionID)
        #expect(duplicateReceipt == nil)
        #expect(transcript.liveAssistantText == "Generated B")
        _ = transcript.complete(text: "Uncorrelated B revision", role: .assistant)
        let finalOnly = transcript.complete(text: "Unsupported final-only text", role: .assistant)
        #expect(finalOnly == nil)
        #expect(transcript.entries.map(\.text) == ["Generated A", "Generated B"])
    }

    @Test func freshProviderReceiptRestoresFinalTextWithoutClearingCallHistoryOrCaller() throws {
        var transcript = RealtimeVoiceTranscriptState()
        _ = transcript.beginProviderSession(connectionID: UUID())
        _ = transcript.append(delta: "Caller partial", role: .user)
        _ = transcript.append(delta: "Generated A", role: .assistant)
        _ = transcript.interruptAssistant()
        _ = transcript.append(delta: "Old provider remainder", role: .assistant)

        let boundary = transcript.beginProviderSession(connectionID: UUID())
        let retained = try #require(boundary)
        #expect(retained.text == "Old provider remainder")
        #expect(transcript.liveAssistantText.isEmpty)
        #expect(transcript.liveUserText == "Caller partial")
        _ = transcript.complete(text: "Fresh provider final-only text", role: .assistant)
        _ = transcript.append(delta: "Fresh provider delta", role: .assistant)
        _ = transcript.complete(text: "Fresh provider final revision", role: .assistant)
        #expect(transcript.entries.map(\.text) == [
            "Generated A", "Old provider remainder", "Fresh provider final-only text",
            "Fresh provider final revision"
        ])
        #expect(transcript.liveUserText == "Caller partial")
    }

    @Test func resettingForANewCallClearsPriorTranscript() {
        var transcript = RealtimeVoiceTranscriptState()
        let connectionID = UUID()
        _ = transcript.beginProviderSession(connectionID: connectionID)
        _ = transcript.append(delta: "Caller partial", role: .user)
        _ = transcript.append(delta: "Generated A", role: .assistant)
        _ = transcript.interruptAssistant()
        transcript.reset()
        #expect(transcript.entries.isEmpty)
        #expect(transcript.liveUserText.isEmpty)
        #expect(transcript.liveAssistantText.isEmpty)
        _ = transcript.beginProviderSession(connectionID: connectionID)
        _ = transcript.complete(text: "New call final", role: .assistant)
        #expect(transcript.entries.map(\.text) == ["New call final"])
    }
}
