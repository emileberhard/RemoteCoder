import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct ConversationHeaderNavigationTests {
    @Test func missingThreadOpensResolvingInReverseOrderKeepTheLatestSelection() async {
        let navigation = ConversationHeaderNavigation()
        let reads = HeaderReads()
        var presented: [String] = []
        var failures = 0
        let first = navigation.open(threadID: "first", read: reads.read,
            present: { presented.append($0.id) }, failed: { _ in failures += 1 })
        await reads.waitFor("first")
        let second = navigation.open(threadID: "second", read: reads.read,
            present: { presented.append($0.id) }, failed: { _ in failures += 1 })
        await reads.waitFor("second")
        reads.resolve("second")
        await second.value
        reads.resolve("first")
        await first.value
        #expect(presented == ["second"])
        #expect(failures == 0)
    }

    @Test func leavingTheConversationRejectsALateHeader() async {
        let navigation = ConversationHeaderNavigation()
        let reads = HeaderReads()
        var presented = false
        var failed = false
        let task = navigation.open(threadID: "old", read: reads.read,
            present: { _ in presented = true }, failed: { _ in failed = true })
        await reads.waitFor("old")
        navigation.cancel()
        reads.resolve("old")
        await task.value
        #expect(!presented)
        #expect(!failed)
    }

    @Test func uncachedHeaderCarriesTheDraftOnlyAfterTheDestinationCommits() async {
        let headers = ConversationHeaderNavigation()
        let navigation = ConversationDraftNavigation()
        let reads = HeaderReads()
        var selected = "previous"
        var source = "draft"
        var drafts = ["previous": "previous draft", "destination": ""]
        let transfer = navigation.retarget {
            let opening = headers.open(threadID: "destination", read: reads.read,
                present: { selected = $0.id }, failed: { _ in })
            await withTaskCancellationHandler {
                await opening.value
            } onCancel: { opening.cancel() }
            return selected == "destination"
        } carry: {
            drafts[selected] = source
            source = ""
            return .moved
        }
        await reads.waitFor("destination")
        #expect(selected == "previous")
        #expect(drafts["previous"] == "previous draft")
        #expect(source == "draft")
        source = "draft edited while loading"
        reads.resolve("destination")
        await transfer.value
        #expect(drafts["previous"] == "previous draft")
        #expect(drafts["destination"] == "draft edited while loading")
        #expect(source.isEmpty)
    }

    @Test func supersededNavigationCarriesTheOriginalDraftOnlyToTheLatestDestination() async throws {
        let navigation = ConversationDraftNavigation()
        let started = AsyncStream<Void>.makeStream()
        var pending: [String: CheckedContinuation<Bool, Never>] = [:]
        var carried: [String] = []
        let first = navigation.retarget {
            await withCheckedContinuation {
                pending["first"] = $0
                started.continuation.yield(())
            }
        } carry: { carried.append("original draft"); return .moved }
        var starts = started.stream.makeAsyncIterator()
        _ = await starts.next()
        let second = navigation.retarget {
            await withCheckedContinuation {
                pending["second"] = $0
                started.continuation.yield(())
            }
        } carry: { carried.append("intermediate conversation draft"); return .moved }
        _ = await starts.next()
        try #require(pending["first"]).resume(returning: true)
        await first.value
        #expect(carried.isEmpty)
        try #require(pending["second"]).resume(returning: true)
        await second.value
        #expect(carried == ["original draft"])
        started.continuation.finish()
    }

    @Test func supersededQueuedNavigationDoesNotChangeSelection() async {
        let navigation = ConversationDraftNavigation()
        var selections: [String] = []
        let first = navigation.retarget {
            selections.append("first")
            return true
        } carry: { .moved }
        let second = navigation.retarget {
            selections.append("second")
            return true
        } carry: { .moved }
        await first.value
        await second.value
        #expect(selections == ["second"])
    }

    @Test func retargetDuringACarrySaveJoinsCleanupBeforeMovingTheCurrentDraftAgain() async {
        let navigation = ConversationDraftNavigation()
        var selected = "A"
        var drafts = ["A": "Keep this", "B": "", "C": ""]
        let (saving, admitted) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (saved, release) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let first = navigation.retarget { selected = "B"; return true } carry: {
            return await navigation.commit {
                drafts["B"] = drafts["A"]
                admitted.yield(())
                for await _ in saved { break }
                drafts["A"] = ""
                return .moved
            }
        }
        var starts = saving.makeAsyncIterator()
        _ = await starts.next()
        let second = navigation.retarget { selected = "C"; return true } carry: {
            drafts["C"] = drafts["B"]
            drafts["B"] = ""
            return .moved
        }
        #expect(first == second)
        #expect(selected == "B")
        release.yield(())
        await second.value
        #expect(selected == "C")
        #expect(drafts == ["A": "", "B": "", "C": "Keep this"])
    }

    @Test func aFailedCarryRetainsItsOriginalSourceForTheQueuedDestination() async {
        let navigation = ConversationDraftNavigation()
        let (saving, admitted) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (saved, release) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var selected = "B"
        var source = "Keep A"
        var drafts = ["B": "", "C": ""]
        var attempts = 0
        var copiedIntermediate = false
        let first = navigation.retarget { selected = "B"; return true } carry: {
            return await navigation.commit {
                attempts += 1
                drafts[selected] = source
                if attempts == 1 {
                    admitted.yield(())
                    for await _ in saved { break }
                    drafts[selected] = ""
                    return .retained
                }
                source = ""
                return .moved
            }
        }
        var starts = saving.makeAsyncIterator()
        _ = await starts.next()
        let latest = navigation.retarget { selected = "C"; return true } carry: {
            copiedIntermediate = true
            return .moved
        }
        release.yield(())
        await first.value
        await latest.value
        #expect(!copiedIntermediate)
        #expect(attempts == 2)
        #expect(drafts == ["B": "", "C": "Keep A"])
        #expect(source.isEmpty)
    }

    @Test func aFailedSaveWithNewDestinationEditsStopsTheQueuedSecondCopy() async {
        let navigation = ConversationDraftNavigation()
        let (saving, admitted) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (saved, release) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var selected = "B"
        var destinationRevision = 0
        let source = "Keep A"
        var drafts = ["B": "", "C": ""]
        let first = navigation.retarget { selected = "B"; return true } carry: {
            return await navigation.commit {
                drafts["B"] = source
                let preparedRevision = destinationRevision
                admitted.yield(())
                for await _ in saved { break }
                if destinationRevision != preparedRevision { return .stopped }
                drafts["B"] = ""
                return .retained
            }
        }
        var starts = saving.makeAsyncIterator()
        _ = await starts.next()
        let latest = navigation.retarget { selected = "C"; return true } carry: {
            drafts["C"] = source
            return .moved
        }
        drafts["B"] = "Keep A plus new B typing"
        destinationRevision += 1
        release.yield(())
        await first.value
        await latest.value
        #expect(selected == "B")
        #expect(drafts["B"] == "Keep A plus new B typing")
        #expect(drafts["C"]?.isEmpty == true)
        #expect(source == "Keep A")
    }

    @Test func retargetBeforeCarryAdmissionPreservesTheOriginalSourceAndLatestTarget() async {
        let navigation = ConversationDraftNavigation()
        let (loading, arrived) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (loaded, release) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let read = Task { for await _ in loaded { break } }
        var selected = "B"
        var source = "Original"
        var drafts = ["B": "Existing B", "C": ""]
        let first = navigation.retarget { selected = "B"; return true } carry: {
            arrived.yield(())
            await read.value
            guard !Task.isCancelled else { return .retained }
            return await navigation.commit { drafts[selected] = source; source = ""; return .moved }
        }
        var starts = loading.makeAsyncIterator()
        _ = await starts.next()
        let latest = navigation.retarget { selected = "C"; return true } carry: {
            drafts[selected] = "Intermediate"
            return .moved
        }
        _ = await starts.next()
        #expect(selected == "C")
        release.yield(())
        await first.value
        await latest.value
        #expect(drafts == ["B": "Existing B", "C": "Original"])
        #expect(source.isEmpty)
    }

    @Test func cancellingNavigationAfterCarryAdmissionStillFinishesItsSavedCleanup() async {
        let navigation = ConversationDraftNavigation()
        let (saving, admitted) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (saved, release) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var source = "Keep this"
        var destination = ""
        var selected = "B"
        let first = navigation.retarget { true } carry: {
            return await navigation.commit {
                destination = source
                admitted.yield(())
                for await _ in saved { break }
                source = ""
                return .moved
            }
        }
        var starts = saving.makeAsyncIterator()
        _ = await starts.next()
        navigation.retarget { selected = "C"; return true } carry: { .moved }
        navigation.cancel()
        release.yield(())
        await first.value
        #expect(source.isEmpty)
        #expect(destination == "Keep this")
        #expect(selected == "B")
    }

    @Test func failedNavigationReleasesTheOriginalDraftCapture() async {
        let navigation = ConversationDraftNavigation()
        var carried: [String] = []
        let failed = navigation.retarget { false } carry: { carried.append("failed source"); return .moved }
        await failed.value
        #expect(carried.isEmpty)
        let next = navigation.retarget { true } carry: { carried.append("current source"); return .moved }
        await next.value
        #expect(carried == ["current source"])
    }
}

@MainActor
private final class HeaderReads {
    private var pending: [String: CheckedContinuation<ConversationHeader, Never>] = [:]
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]

    func read(_ threadID: String) async -> ConversationHeader {
        await withCheckedContinuation {
            pending[threadID] = $0
            waiting.removeValue(forKey: threadID)?.resume()
        }
    }

    func waitFor(_ threadID: String) async {
        if pending[threadID] != nil { return }
        await withCheckedContinuation { waiting[threadID] = $0 }
    }

    func resolve(_ threadID: String) {
        let header = ConversationHeader(.init(id: threadID, preview: "", createdAt: 1, updatedAt: 1,
            path: nil, cwd: "", source: .string("cli"), name: nil, status: .idle))
        pending.removeValue(forKey: threadID)?.resume(returning: header)
    }
}
