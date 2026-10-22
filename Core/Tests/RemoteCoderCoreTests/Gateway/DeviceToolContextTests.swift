import Foundation
import Testing
@testable import RemoteCoderCore

@Suite(.timeLimit(.minutes(1)))
struct DeviceToolContextTests {
    @Test func uploadPreservesGatewayTargetAndReceipt() async throws {
        let receipt = UploadedFile(path: "/uploads/back-wide.jpg", bytes: 123, sha256: "digest")
        let uploader = PhotoUploadProbe(receipt: receipt)
        let context = makeContext(uploader: uploader, remaining: 60)
        let file = try Self.photo("photo.jpg")
        #expect(try await context.uploadOriginal(file, name: "back-wide.jpg") == receipt)
        #expect(await uploader.request?.host == context.host)
        #expect(await uploader.request?.file == file)
        #expect(await uploader.request?.name == "back-wide.jpg")
    }

    @Test func uploadNeverStartsInsideResultDeliveryMargin() async {
        let uploader = PhotoUploadProbe(receipt: nil)
        let context = makeContext(uploader: uploader, remaining: 7)
        await #expect(throws: DeviceToolContext.OriginalUploadError.deadlinePassed) {
            try await context.uploadOriginal(try Self.photo("photo.jpg"), name: "back-wide.jpg")
        }
        #expect(await uploader.request == nil)
    }

    @Test func timeoutCancelsOnlyUploadAndLeavesOperationTaskUsable() async throws {
        let uploader = PhotoUploadProbe(receipt: nil)
        let context = makeContext(uploader: uploader, remaining: 9)
        await #expect(throws: DeviceToolContext.OriginalUploadError.deadlinePassed) {
            try await context.uploadOriginal(try Self.photo("photo.jpg"), name: "back-wide.jpg")
        }
        #expect(await uploader.cancellations == 1)
        try Task.checkCancellation()
        let next = makeContext(uploader: PhotoUploadProbe(receipt: .init(path: "/uploads/front.jpg", bytes: 1, sha256: "digest")), remaining: 60)
        #expect(try await next.uploadOriginal(try Self.photo("front.jpg"), name: "front.jpg").path == "/uploads/front.jpg")
    }

    @Test func turnCancellationPropagatesAndCancelsUpload() async {
        let uploader = PhotoUploadProbe(receipt: nil)
        let context = makeContext(uploader: uploader, remaining: 60)
        let task = Task { try await context.uploadOriginal(try Self.photo("photo.jpg"), name: "back-wide.jpg") }
        await uploader.waitUntilStarted()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await uploader.cancellations == 1)
    }

    private static func photo(_ name: String) throws -> URL {
        let file = URL.temporaryDirectory.appending(path: "device-tool-\(UUID())-\(name)")
        try Data("jpeg".utf8).write(to: file)
        return file
    }

    private func makeContext(uploader: any GatewayFileUploading, remaining: TimeInterval) -> DeviceToolContext {
        .init(host: .init(id: UUID(), name: "Camera host", hostname: "localhost", port: 8787, authToken: "fixture", transport: .trustedNetwork),
              uploader: uploader, deadlineUnixMs: Int64(Date.now.addingTimeInterval(remaining).timeIntervalSince1970 * 1_000))
    }
}

private actor PhotoUploadProbe: GatewayFileUploading {
    struct Request: Equatable {
        let file: URL
        let name: String
        let host: GatewayHostConfiguration
    }

    private let receipt: UploadedFile?
    private(set) var request: Request?
    private(set) var cancellations = 0
    private var pending: CheckedContinuation<UploadedFile, Error>?
    private var started: CheckedContinuation<Void, Never>?

    init(receipt: UploadedFile?) { self.receipt = receipt }

    func upload(_ upload: GatewayUpload, to host: GatewayHostConfiguration,
                progress: @escaping @Sendable (GatewayUploadProgress) -> Void) async throws -> UploadedFile {
        request = Request(file: upload.file, name: upload.name, host: host)
        started?.resume()
        started = nil
        if let receipt { return receipt }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { pending = $0 }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitUntilStarted() async {
        if request != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    private func cancel() {
        cancellations += 1
        pending?.resume(throwing: CancellationError())
        pending = nil
    }
}
