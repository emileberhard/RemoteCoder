#if RC_PERF_HARNESS
import Foundation

@MainActor
enum PerformanceReplayPreparation {
    static func prepare(_ scenario: PerformanceReplayScenario, model: ChatTargetModel, progressURL: URL) async throws -> [String: Any] {
        let started = ContinuousClock.now
        var prepared = 0
        var pages = 0
        let sidebarDeadline = ContinuousClock.now + .seconds(30)
        func settleSidebar() async throws {
            while !model.conversationList.performanceReplayRefreshState.settled {
                guard ContinuousClock.now < sidebarDeadline else {
                    throw PerformanceReplayScenario.Failure.invalidScenario("sidebar preparation did not settle")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        try await settleSidebar()
        let previousRefresh = model.conversationList.lastSuccessfulRefreshAt
        for attempt in 0..<2 {
            try await model.performanceReplayConnect()
            await model.conversationList.manualRefresh(reason: "performance preparation")
            try await settleSidebar()
            if model.conversationList.lastSuccessfulRefreshAt != previousRefresh { break }
            guard attempt == 0, model.conversationList.performanceReplayRefreshState.deferred,
                  ContinuousClock.now < sidebarDeadline else {
                throw PerformanceReplayScenario.Failure.invalidScenario("sidebar refresh did not succeed; deferred=\(model.conversationList.performanceReplayRefreshState.deferred), neverLoaded=\(model.conversationList.lastSuccessfulRefreshAt == nil), count=\(model.conversationList.threads.count), failure=\(model.conversationList.errorMessage ?? "none")")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        for _ in 0..<64 where model.conversationList.canLoadOlder(query: "") {
            try Task.checkCancellation()
            try await settleSidebar()
            let count = model.conversationList.threads.count
            let position = model.conversationList.continuation
            await model.conversationList.loadOlder(query: "", including: { _ in true })
            try await settleSidebar()
            guard model.conversationList.threads.count != count || model.conversationList.continuation != position else {
                throw PerformanceReplayScenario.Failure.invalidScenario("sidebar traversal made no progress")
            }
        }
        let expectedHeaders = Set(scenario.conversations.compactMap { $0.thread.objectValue?["id"]?.stringValue })
        let loadedHeaders = Set(model.conversationList.threads.map(\.id))
        let nativeChildren = try scenario.conversations.compactMap { conversation -> String? in
            let wire = try JSONDecoder().decode(CodexAppServerV2.Thread.self, from: JSONEncoder().encode(conversation.thread))
            let header = ConversationHeader(wire)
            return header.isNativeAgent ? header.id : nil
        }
        let childHeaders = Set(scenario.responses["conversation/agents/classify"]?.objectValue?["relations"]?.objectValue?.keys.map { $0 } ?? []).union(nativeChildren)
        let expectedRoots = expectedHeaders.subtracting(childHeaders)
        guard loadedHeaders.isSuperset(of: expectedRoots), expectedHeaders.isSuperset(of: loadedHeaders) else {
            throw PerformanceReplayScenario.Failure.invalidScenario("sidebar preparation loaded \(loadedHeaders.count) of \(expectedHeaders.count) captured headers; failure=\(model.conversationList.errorMessage ?? "none")")
        }
        func updated(_ conversation: PerformanceReplayScenario.Conversation) -> Double {
            if case .number(let value) = conversation.thread.objectValue?["updatedAt"] { return value }
            return 0
        }
        let ordered = scenario.conversations.sorted {
            updated($0) < updated($1)
        }
        for conversation in ordered {
            guard let submission = conversation.localSubmission,
                  let threadID = conversation.thread.objectValue?["id"]?.stringValue else { continue }
            try Task.checkCancellation()
            let header = try JSONDecoder().decode(CodexAppServerV2.Thread.self, from: JSONEncoder().encode(conversation.thread))
            let session = await model.conversations.session(threadID: threadID)
            let read = await session.beginHistoryRead()
            var snapshot = try await model.historyService.openTail(header: ConversationHeader(header), base: read.base, bypassCache: true)
            _ = await session.merge(snapshot, read: read)
            pages += 1
            var seen: Set<String> = []
            let maximumReads = conversation.itemCount + conversation.turnCount + 1
            while let cursor = snapshot.window.older {
                guard seen.insert(cursor).inserted, seen.count <= maximumReads else {
                    throw PerformanceReplayScenario.Failure.invalidScenario("preparation history cursor did not advance")
                }
                let read = await session.beginHistoryRead()
                snapshot = try await model.historyService.page(header: snapshot.header, window: snapshot.window,
                    direction: .desc, priority: .foreground)
                _ = await session.merge(snapshot, read: read)
                pages += 1
            }
            let message = ChatMessage(id: submission.messageID, role: .user, text: submission.text)
            _ = try await session.submit(message)
            try await session.persistSubmission(message.id)
            await session.accepted(message.id, turnID: submission.turnID)
            let tailRead = await session.beginHistoryRead()
            var tail = try await model.historyService.openTail(header: ConversationHeader(header), base: tailRead.base, bypassCache: true)
            _ = await session.merge(tail, read: tailRead)
            await session.reconcileDeliveryEvidence(tail)
            pages += 1
            seen.removeAll()
            while !(await session.canEvict), let cursor = tail.window.older {
                guard seen.insert(cursor).inserted, seen.count <= maximumReads else {
                    throw PerformanceReplayScenario.Failure.invalidScenario("reconciliation cursor did not advance")
                }
                let read = await session.beginHistoryRead()
                tail = try await model.historyService.page(header: tail.header, window: tail.window,
                    direction: .desc, priority: .foreground)
                _ = await session.merge(tail, read: read)
                await session.reconcileDeliveryEvidence(tail)
                pages += 1
            }
            try await session.flush()
            guard await session.canEvict else {
                throw PerformanceReplayScenario.Failure.invalidScenario("preparation did not reconcile its captured submission")
            }
            prepared += 1
            await model.conversations.evictIdle(keeping: [])
            if prepared.isMultiple(of: 25) {
                let progress: [String: Any] = ["conversations": prepared, "historyPages": pages,
                    "seconds": started.duration(to: .now) / .seconds(1),
                    "owner": await model.conversations.performanceReplayCheckpointInventory()]
                try JSONSerialization.data(withJSONObject: progress, options: .sortedKeys).write(to: progressURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: progressURL.path)
            }
        }
        var report = try await inventory()
        let owner = await model.conversations.performanceReplayCheckpointInventory()
        report["owner"] = owner
        report["preservedCheckpointCount"] = owner["protectedRecords"]
        let persistence = PersistenceMetrics.shared.snapshot()
        report["persistence"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            Dictionary(uniqueKeysWithValues: persistence.map { ($0.key.rawValue, $0.value) })))
        report["conversations"] = prepared
        report["historyPages"] = pages
        report["seconds"] = started.duration(to: .now) / .seconds(1)
        report["sidebarConversations"] = model.conversationList.threads.count
        report["capturedSidebarConversations"] = expectedHeaders.count
        report["excludedChildHeaders"] = expectedHeaders.subtracting(loadedHeaders).count
        return report
    }

    @concurrent private static func inventory() async throws -> [String: Any] {
        try storageInventory()
    }

    nonisolated private static func storageInventory() throws -> [String: Any] {
        let root = AppStorageScope.current.applicationSupport
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            throw PerformanceReplayScenario.Failure.invalidScenario("preparation storage is unavailable")
        }
        var bytes = 0
        var files = 0
        var checkpointBytes = 0
        var checkpointCount = 0
        var historyCacheBytes = 0
        var historyCacheFiles = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize else { continue }
            bytes += size
            files += 1
            if url.path.contains("/history-pages/") { historyCacheBytes += size; historyCacheFiles += 1 }
            if url.path.contains("/conversations-v1/") {
                checkpointBytes += size
                guard url.pathExtension == "sqlite" else { continue }
                checkpointCount += 1
            }
        }
        return ["physicalBytes": bytes, "files": files, "checkpointPhysicalBytes": checkpointBytes,
            "checkpointCount": checkpointCount,
            "historyCachePhysicalBytes": historyCacheBytes, "historyCacheFiles": historyCacheFiles,
            "byteMetric": "physical file sizes; owner accounting is reported separately"]
    }
}
#endif
