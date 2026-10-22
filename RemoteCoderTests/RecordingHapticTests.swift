import Foundation
import Testing
@testable import RemoteCoder

@MainActor
struct RecordingHapticTests {
    private let owner = ExecutionTarget(hostID: UUID())

    @Test func localStopAcknowledgementFollowsCaptureAndSessionRelease() async throws {
        let fixture = HapticFixture()
        defer { fixture.cleanUp() }
        let recordings = try TemporaryDictationRecordings()
        defer { recordings.cleanUp() }
        let recorder = StubVoiceRecorder()
        let controller = VoiceInputController(access: .fixture, owner: owner, transcriber: StubTranscriber(text: "test"),
                                              recorder: recorder, recordings: recordings.store, haptics: fixture.service)
        controller.markRecordingRequested()
        try await controller.startAsync()
        #expect(!fixture.service.canPlay)
        var called = false
        try await controller.stopRecording {
            called = true
            #expect(recorder.didStop)
            #expect(recorder.didDeactivate)
            #expect(fixture.service.canPlay)
            fixture.service.play(.commit)
        }
        #expect(called)
        #expect(fixture.service.pulse?.event == .commit)
        #expect(!controller.isTranscribing)
    }

    @Test func stopWithoutARecordingStillTearsDownCaptureWithoutAcknowledgement() async throws {
        let fixture = HapticFixture()
        defer { fixture.cleanUp() }
        let recordings = try TemporaryDictationRecordings()
        defer { recordings.cleanUp() }
        let recorder = StubVoiceRecorder()
        let controller = VoiceInputController(access: .fixture, owner: owner, transcriber: StubTranscriber(text: ""),
                                              recorder: recorder, recordings: recordings.store, haptics: fixture.service)
        controller.markRecordingRequested()
        var acknowledged = false
        await #expect(throws: DictationError.self) {
            try await controller.stopRecording { acknowledged = true }
        }
        #expect(recorder.didStop)
        #expect(recorder.didDeactivate)
        #expect(!controller.isRecording)
        #expect(!acknowledged)
        #expect(fixture.service.pulse == nil)
    }

    @Test func failedSessionReleaseDoesNotAcknowledgeStopOrLoseTranscription() async throws {
        let fixture = HapticFixture()
        defer { fixture.cleanUp() }
        let recordings = try TemporaryDictationRecordings()
        defer { recordings.cleanUp() }
        let recorder = ReleaseFailingRecorder()
        let controller = VoiceInputController(access: .fixture, owner: owner, transcriber: StubTranscriber(text: "retained"),
                                              recorder: recorder, recordings: recordings.store, haptics: fixture.service)
        controller.markRecordingRequested()
        try await controller.startAsync()
        var acknowledged = false
        try await controller.stopRecording { acknowledged = true }
        #expect(!acknowledged)
        #expect(fixture.service.pulse == nil)
        #expect(try await controller.transcribe().text == "retained")
    }

    @Test func failedAudioActivationReleasesSuppressionWithoutFalseReadiness() async throws {
        let fixture = HapticFixture()
        defer { fixture.cleanUp() }
        let recordings = try TemporaryDictationRecordings()
        defer { recordings.cleanUp() }
        let recorder = RefusingRecorder(haptics: fixture.service)
        let controller = VoiceInputController(access: .fixture, owner: owner, transcriber: StubTranscriber(text: ""),
                                              recorder: recorder, recordings: recordings.store, haptics: fixture.service)
        controller.markRecordingRequested()
        await #expect(throws: RefusingRecorder.Failure.self) { try await controller.startAsync() }
        #expect(recorder.wasSuppressedAtActivation)
        #expect(fixture.service.canPlay)
        #expect(fixture.service.pulse == nil)
        #expect(!controller.isRecording)
    }
}

@MainActor
private final class RefusingRecorder: VoiceInputRecording {
    struct Failure: Error {}
    let haptics: HapticService
    var wasSuppressedAtActivation = false
    init(haptics: HapticService) { self.haptics = haptics }
    func ensurePermission() async throws {}
    func activateSession() async throws {
        wasSuppressedAtActivation = !haptics.canPlay
        throw Failure()
    }
    func deactivateSession() async throws {}
    func start(output: PCM16CaptureOutput) async throws {}
    func stop() {}
    func normalizedLevel() -> Float { 0 }
}

@MainActor
private final class ReleaseFailingRecorder: VoiceInputRecording {
    struct Failure: Error {}
    func ensurePermission() async throws {}
    func activateSession() async throws {}
    func deactivateSession() async throws { throw Failure() }
    func start(output: PCM16CaptureOutput) async throws {
        output.receive(Data(repeating: 1, count: 3_200))
    }
    func stop() {}
    func normalizedLevel() -> Float { 0 }
}
