import Foundation

struct DeviceToolRefusal: LocalizedError, Sendable {
    let reason: DeviceToolRefusalReason
    let detail: String
    var errorDescription: String? { detail }
}

struct DeviceToolOutput: Sendable {
    let content: [DeviceToolContent]
    let originals: [DeviceToolOriginal]
    let detail: String?
}

struct DeviceToolContext: Sendable {
    enum OriginalUploadError: LocalizedError {
        case deadlinePassed

        var errorDescription: String? { "The original upload deadline was reached." }
    }

    let host: GatewayHostConfiguration
    let uploader: any GatewayFileUploading
    let deadlineUnixMs: Int64

    func checkCanStart() throws {
        try Task.checkCancellation()
        guard Int64(Date.now.timeIntervalSince1970 * 1_000) < deadlineUnixMs else {
            throw DeviceToolRefusal(reason: .deadlinePassed, detail: "The device tool deadline has passed.")
        }
    }

    func uploadOriginal(_ fileURL: URL, name: String) async throws -> UploadedFile {
        try Task.checkCancellation()
        let remaining = Double(deadlineUnixMs) / 1_000 - Date.now.timeIntervalSince1970 - 8
        guard remaining > 0 else { throw OriginalUploadError.deadlinePassed }
        let uploaded = try await withThrowingTaskGroup(of: UploadedFile.self) { group in
            group.addTask {
                let upload = try await GatewayUpload.prepare(id: UUID(), file: fileURL, name: name)
                return try await uploader.upload(upload, to: host, progress: { _ in })
            }
            group.addTask {
                try await Task.sleep(for: .seconds(remaining))
                throw OriginalUploadError.deadlinePassed
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
        try Task.checkCancellation()
        return uploaded
    }
}

protocol DeviceTool: Sendable {
    var declaration: DeviceToolsDeclare.Tool { get }
    func execute(arguments: JSONValue, context: DeviceToolContext) async throws -> DeviceToolOutput
}

struct DeviceToolConnection: Sendable {
    let host: DeviceToolHost
    let uploadHost: GatewayHostConfiguration
    let uploader: any GatewayFileUploading
}

actor DeviceToolHost {
    private struct Operation {
        let id: String
        let generation: UUID
        let task: Task<Void, Never>
    }

    nonisolated let declarations: DeviceToolsDeclare
    private let tools: [String: any DeviceTool]
    private var running: Operation?

    init(tools: [any DeviceTool]) {
        precondition(Set(tools.map { $0.declaration.name }).count == tools.count)
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.declaration.name, $0) })
        declarations = DeviceToolsDeclare(tools: tools.map(\.declaration))
    }

    func invoke(_ invoke: DeviceToolInvoke, generation: UUID, context: DeviceToolContext,
                deliver: @escaping @Sendable (DeviceToolResult) async -> Void) -> DeviceToolResult? {
        guard running?.id != invoke.operationId || running?.generation != generation else { return nil }
        guard Int64(Date.now.timeIntervalSince1970 * 1_000) < invoke.deadlineUnixMs else {
            return refusal(invoke.operationId, reason: .deadlinePassed, detail: "The device tool deadline has passed.")
        }
        guard let tool = tools[invoke.tool], tool.declaration.version == invoke.version else {
            return refusal(invoke.operationId, reason: .invalidArguments, detail: "Unsupported device tool or version.")
        }
        guard running == nil else {
            return refusal(invoke.operationId, reason: .busy, detail: "Another iPhone tool is running.")
        }
        let task = Task { [self] in
            let result: DeviceToolResult
            do {
                try context.checkCanStart()
                let output = try await tool.execute(arguments: invoke.arguments, context: context)
                try Task.checkCancellation()
                result = DeviceToolResult(operationId: invoke.operationId, outcome: .succeeded, reason: nil,
                                          detail: output.detail, content: output.content, originals: output.originals)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    result = DeviceToolResult(operationId: invoke.operationId, outcome: .cancelled, reason: nil,
                                              detail: nil, content: nil, originals: nil)
                } else if let refusal = error as? DeviceToolRefusal {
                    result = self.refusal(invoke.operationId, reason: refusal.reason, detail: refusal.detail)
                } else {
                    result = DeviceToolResult(operationId: invoke.operationId, outcome: .failed, reason: nil,
                                              detail: error.localizedDescription, content: nil, originals: nil)
                }
            }
            await deliver(result)
            if running?.id == invoke.operationId, running?.generation == generation { running = nil }
        }
        running = Operation(id: invoke.operationId, generation: generation, task: task)
        return nil
    }

    func cancel(_ cancel: DeviceToolCancel, generation: UUID) {
        guard running?.id == cancel.operationId, running?.generation == generation else { return }
        running?.task.cancel()
    }

    func connectionLost(generation: UUID) {
        guard running?.generation == generation else { return }
        running?.task.cancel()
    }

    private func refusal(_ id: String, reason: DeviceToolRefusalReason, detail: String) -> DeviceToolResult {
        DeviceToolResult(operationId: id, outcome: .refused, reason: reason, detail: detail, content: nil, originals: nil)
    }
}
