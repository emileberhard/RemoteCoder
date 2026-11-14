import AVFAudio
import CloudKit
@testable import DictationLibrary
import Foundation
import Testing
@testable import RemoteCoder

@MainActor
final class DictationFixtureBackground: BackgroundExecution {
    private(set) var holds = 0
    private(set) var releases = 0
    private var expiration: (@MainActor () -> Void)?
    func hold(named name: String, onExpiration: @escaping @MainActor () -> Void) { holds += 1; expiration = onExpiration }
    func holdWithGrace(named name: String, for grace: Duration, onExpiration: @escaping @MainActor () -> Void) { hold(named: name, onExpiration: onExpiration) }
    func release() { releases += 1; expiration = nil }
    func expire() { expiration?() }
    func reset() { holds = 0; releases = 0 }
}

@MainActor
@Suite struct DictationPublicationTests {
    @Test func sealingAndResultsKeepOneBackgroundHoldAndDoNotRefreshTheProfile() async throws {
        let fixture = try await fixture()
        defer { fixture.cleanUp() }
        let capture = try #require(try await fixture.library.prepare(configuration: .init(model: .elevenLabsScribeV2, language: .english)))
        try appendAudio(to: capture)
        await fixture.cloud.holdNextCreate()
        fixture.library.finish(capture)
        await fixture.cloud.waitUntilHeld()
        _ = fixture.library.result(DictationTranscript(text: "Synthetic result", model: "synthetic"), recordingID: capture.id, plan: capture.plan)
        await fixture.library.finishArchiving()
        #expect(fixture.background.holds == 1)
        #expect(fixture.background.releases == 0)
        fixture.library.applicationDidEnterBackground()
        await fixture.cloud.release()
        await fixture.library.publish()
        #expect(fixture.background.releases == 1)
        #expect(await fixture.cloud.resultCount == 1)
        #expect(await fixture.cloud.profileReads == 1)
        #expect(fixture.library.status == "Synced to iCloud")
    }

    @Test func expirationCancelsTheCurrentPassWithoutReplacingTheStatusWithAFailure() async throws {
        let fixture = try await fixture()
        defer { fixture.cleanUp() }
        let capture = try #require(try await fixture.library.prepare(configuration: .init(model: .elevenLabsScribeV2, language: .english)))
        try appendAudio(to: capture)
        await fixture.cloud.holdNextCreate()
        fixture.library.finish(capture)
        await fixture.cloud.waitUntilHeld()
        await fixture.library.finishArchiving()
        let statusBefore = fixture.library.status
        let started = AsyncStream<Void>.makeStream()
        let waiting = Task {
            started.continuation.yield(())
            started.continuation.finish()
            await fixture.library.publish()
        }
        for await _ in started.stream { break }
        fixture.background.expire()
        #expect(fixture.background.releases == 1)
        await fixture.cloud.release()
        await waiting.value
        let status = try await fixture.store.status()
        #expect(status.pendingCaptureCount == 1)
        #expect(status.failures.isEmpty)
        #expect(fixture.background.holds == 1)
        #expect(fixture.background.releases == 1)
        #expect(fixture.library.status == statusBefore)
    }

    @Test func expirationDuringSealingDoesNotStartAnotherPass() async throws {
        let gate = DictationSealingGate()
        let fixture = try await fixture { writer in
            await gate.wait()
            _ = try await writer.finish()
        }
        defer { fixture.cleanUp() }
        let capture = try #require(try await fixture.library.prepare(configuration: .init(model: .elevenLabsScribeV2, language: .english)))
        try appendAudio(to: capture)
        fixture.library.finish(capture)
        await gate.waitUntilStarted()
        fixture.background.expire()
        await gate.release()
        await fixture.library.finishArchiving()
        #expect(try await fixture.store.status().pendingCaptureCount == 1)
        #expect(await fixture.cloud.createCount == 0)
        #expect(fixture.background.holds == 1)
        #expect(fixture.background.releases == 1)
    }

    @Test func anEmptyDictationLeavesTheStatusAlone() async throws {
        let fixture = try await fixture()
        defer { fixture.cleanUp() }
        let capture = try #require(try await fixture.library.prepare(configuration: .init(model: .elevenLabsScribeV2, language: .english)))
        let status = fixture.library.status
        fixture.library.finish(capture)
        await fixture.library.finishArchiving()
        #expect(fixture.library.status == status)
        #expect(try await fixture.store.status().pendingCaptureCount == 0)
        #expect(fixture.background.holds == 1)
        #expect(fixture.background.releases == 1)
    }

    @Test func voiceHistoryVerifiesTheAccountAtAColdLaunch() async throws {
        let name = "SyntheticVoiceHistory.\(UUID())"
        let root = URL.temporaryDirectory.appending(path: name)
        let defaults = try #require(UserDefaults(suiteName: name))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: name)
        }
        defaults.set(true, forKey: "dictation.sharedLibrary.enabled")
        let store = try DictationLibraryStore(directory: root, source: "synthetic", capacityBytes: 16 * 1_024 * 1_024,
                                             cloud: DictationPublicationCloud(profile: Self.profile))
        let library = SharedDictationLibrary(defaults: defaults, directory: root, background: DictationFixtureBackground(), openStore: { _ in store })
        #expect(store.accountSession() == nil)
        let history = try #require(try await library.localVoiceHistory())
        #expect(history.recordings.isEmpty)
        try await history.validate()
    }

    private static let profile = DictationProfile(archiveEnabled: true, preferredModel: TranscriptionModel.elevenLabsScribeV2.libraryID, languages: ["en"], dictionary: [], cleanupEnabled: false, outputLanguage: nil, thinkingLevel: "minimal")

    @MainActor private struct Fixture {
        let root: URL
        let defaults: UserDefaults
        let defaultsName: String
        let library: SharedDictationLibrary
        let store: DictationLibraryStore
        let cloud: DictationPublicationCloud
        let background: DictationFixtureBackground
        func cleanUp() {
            library.cancelPublication()
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: defaultsName)
        }
    }

    private func fixture(finalize: @escaping @Sendable (DictationCaptureWriter) async throws -> Void = { _ = try await $0.finish() }) async throws -> Fixture {
        let name = "SyntheticPublication.\(UUID())"
        let root = URL.temporaryDirectory.appending(path: name)
        let defaults = try #require(UserDefaults(suiteName: name))
        let cloud = DictationPublicationCloud(profile: Self.profile)
        let store = try DictationLibraryStore(directory: root, source: "synthetic", capacityBytes: 16 * 1_024 * 1_024, cloud: cloud)
        let background = DictationFixtureBackground()
        let library = SharedDictationLibrary(defaults: defaults, directory: root, background: background, openStore: { _ in store }, finalize: finalize)
        library.isEnabled = true
        await library.publish()
        background.reset()
        return Fixture(root: root, defaults: defaults, defaultsName: name, library: library, store: store, cloud: cloud, background: background)
    }

    private func appendAudio(to capture: SharedDictationLibrary.Capture) throws {
        let writer = try #require(capture.writer)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let audio = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        audio.frameLength = 4_800
        let samples = try #require(audio.floatChannelData?[0])
        for index in 0..<4_800 { samples[index] = Float(sin(Double(index) * 0.1)) * 0.2 }
        try writer.configure(format: format)
        writer.append(audio)
    }
}

private actor DictationPublicationCloud: LibraryCloud {
    private let value: DictationProfile
    private(set) var profileReads = 0
    private(set) var resultCount = 0
    private(set) var createCount = 0
    private var holdNext = false
    private var held: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    init(profile: DictationProfile) { value = profile }
    func accountIdentifier() -> String? { "synthetic-account" }
    func profile() -> DictationProfile? { profileReads += 1; return value }
    func saveProfile(_ profile: DictationProfile) {}
    func holdNextCreate() { holdNext = true }
    func create(_ record: CKRecord) async throws {
        createCount += 1
        if holdNext {
            holdNext = false
            await withCheckedContinuation { held = $0; waiter?.resume(); waiter = nil }
        }
        if Task.isCancelled { throw CancellationError() }
        if record.recordType == DictationLibrarySchema.resultRecordType { resultCount += 1 }
    }
    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { held?.resume(); held = nil }
    func missing(_ ids: [CKRecord.ID]) -> Set<CKRecord.ID> { [] }
    func changes(since token: Data?, desiredKeys: [String]) -> LibraryCloudPage { LibraryCloudPage(records: [], deletedCount: 0, token: Data(), moreComing: false) }
    func originalChunk(_ id: CKRecord.ID) throws -> Data { throw DictationLibraryError.invalidRecord(id.recordName) }
}

private actor DictationSealingGate {
    private var held: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { held = $0; waiter?.resume(); waiter = nil } }
    func waitUntilStarted() async {
        if held != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { held?.resume(); held = nil }
}
