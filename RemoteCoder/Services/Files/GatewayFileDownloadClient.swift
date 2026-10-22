import Foundation
import Synchronization

enum GatewayFileDownload: Sendable {
    case unchanged(HostFileMetadata)
    case downloaded(HostFileMetadata, URL)
}

enum GatewayFileDownloadSource: Sendable {
    case file(path: String, containingDirectory: String?)
    case visual(HTMLVisualReference)

    var key: String {
        switch self {
        case .file(let path, _): path
        case .visual(let reference): "rc-visual:" + reference.digest
        }
    }

    var maximumBytes: Int64 {
        switch self {
        case .file: HostFileLimits.maximumFileBytes
        case .visual: Int64(HTMLVisualReference.maximumBytes)
        }
    }

    func validate(_ metadata: HostFileMetadata) throws {
        switch self {
        case .file(let path, _): try metadata.validate(path: path)
        case .visual(let reference):
            try metadata.validate(path: metadata.path)
            guard metadata.path.hasPrefix("/"), metadata.path.utf8.count <= 4096, !metadata.path.contains("\0"),
                  metadata.name == reference.digest + ".html" else { throw HostFileError.invalidResponse }
        }
        guard metadata.bytes <= maximumBytes else { throw HostFileError.tooLarge }
    }
}

protocol GatewayFileDownloading: Sendable {
    func download(source: GatewayFileDownloadSource, knownRevision: String?, to directory: URL,
                  progress: @escaping @Sendable (HostFileProgress) -> Void,
                  admit: @escaping @Sendable (Int64) throws -> Void) async throws -> GatewayFileDownload
}

actor GatewayFileDownloadClient: GatewayFileDownloading {
    private let host: GatewayHostConfiguration
    private let routes: GatewayRoutes

    init(host: GatewayHostConfiguration, routes: GatewayRoutes) {
        self.host = host
        self.routes = routes
    }

    func download(source: GatewayFileDownloadSource, knownRevision: String?, to directory: URL,
                  progress: @escaping @Sendable (HostFileProgress) -> Void,
                  admit: @escaping @Sendable (Int64) throws -> Void) async throws -> GatewayFileDownload {
        guard let url = host.gatewayHTTPBaseURL()?.appending(path: "files/download") else {
            throw HostFileError.unavailable
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(host.authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.httpBody = try JSONEncoder().encode(Request(source: source, knownRevision: knownRevision))
        progress(HostFileProgress(bytesReceived: 0, totalBytes: nil))
        do {
            return try await routes.send(request, traffic: .download) { request, session in
                try await Self.send(request, source: source, knownRevision: knownRevision, to: directory,
                                    over: session, progress: progress, admit: admit)
            }
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            switch error.code {
            case .timedOut, .networkConnectionLost: throw HostFileError.interrupted
            default: throw HostFileError.unavailable
            }
        }
    }

    private struct Request: Encodable {
        let source: GatewayFileDownloadSource
        let knownRevision: String?

        private enum CodingKeys: String, CodingKey {
            case path, visualDigest, knownRevision, containingDirectory
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch source {
            case .file(let path, let containingDirectory):
                try container.encode(path, forKey: .path)
                try container.encodeIfPresent(containingDirectory, forKey: .containingDirectory)
            case .visual(let reference):
                try container.encode(reference.digest, forKey: .visualDigest)
            }
            try container.encodeIfPresent(knownRevision, forKey: .knownRevision)
        }
    }

    private struct ErrorBody: Decodable {
        let kind: String
        let message: String
    }

    private static func send(_ request: URLRequest, source: GatewayFileDownloadSource, knownRevision: String?, to directory: URL,
                             over session: URLSession, progress: @escaping @Sendable (HostFileProgress) -> Void,
                             admit: @escaping @Sendable (Int64) throws -> Void) async throws -> GatewayFileDownload {
        let delegate = ProgressDelegate(source: source, progress: progress, admit: admit)
        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await session.download(for: request, delegate: delegate)
        } catch {
            if let failure = delegate.failure { throw failure }
            throw error
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        if let failure = delegate.failure { throw failure }
        guard let http = response as? HTTPURLResponse else { throw HostFileError.invalidResponse }
        guard http.statusCode == 200 || http.statusCode == 204 else {
            throw try Self.responseError(http.statusCode, file: temporary)
        }
        let metadata = try Self.metadata(from: http, source: source)
        if http.statusCode == 204 {
            guard knownRevision == metadata.revision else { throw HostFileError.invalidResponse }
            return .unchanged(metadata)
        }
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, Int64(size) == metadata.bytes else { throw HostFileError.interrupted }
        try admit(metadata.bytes)
        let destination = directory.appendingPathComponent(metadata.name, isDirectory: false)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temporary.path)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: destination)
        progress(HostFileProgress(bytesReceived: metadata.bytes, totalBytes: metadata.bytes))
        return .downloaded(metadata, destination)
    }

    static func metadata(from response: HTTPURLResponse, source: GatewayFileDownloadSource) throws -> HostFileMetadata {
        guard let encoded = response.value(forHTTPHeaderField: "X-RemoteCoder-File-Metadata"),
              encoded.utf8.count <= 32_768, let data = Data(base64Encoded: encoded),
              let metadata = try? JSONDecoder().decode(HostFileMetadata.self, from: data) else {
            throw HostFileError.invalidResponse
        }
        try source.validate(metadata)
        if response.statusCode == 200 {
            guard let length = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
                  length == metadata.bytes else { throw HostFileError.invalidResponse }
        }
        return metadata
    }

    static func responseError(_ status: Int, file: URL) throws -> HostFileError {
        if status == 401 { return .unauthorized }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 65_537), data.count <= 65_536,
              let body = try? JSONDecoder().decode(ErrorBody.self, from: data),
              body.kind.utf8.count <= 64, body.message.utf8.count <= 2048 else {
            return .invalidResponse
        }
        switch body.kind {
        case "missing": return .missing
        case "accessDenied": return .accessDenied
        case "notFile": return .notFile
        case "tooLarge": return .tooLarge
        case "busy": return .busy
        case "draining": return .server(kind: body.kind, message: body.message)
        case "changed": return .changed
        case "invalidPath": return .invalidPath
        default: return .server(kind: body.kind, message: body.message)
        }
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
        private struct State {
            var metadata: HostFileMetadata?
            var lastPercent = -1
            var failure: (any Error)?
        }

        private let state = Mutex(State())
        private let source: GatewayFileDownloadSource
        private let progress: @Sendable (HostFileProgress) -> Void
        private let admit: @Sendable (Int64) throws -> Void

        init(source: GatewayFileDownloadSource, progress: @escaping @Sendable (HostFileProgress) -> Void,
             admit: @escaping @Sendable (Int64) throws -> Void) {
            self.source = source
            self.progress = progress
            self.admit = admit
        }

        var failure: (any Error)? { state.withLock { $0.failure } }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {}

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            do {
                guard let response = downloadTask.response as? HTTPURLResponse else {
                    throw HostFileError.invalidResponse
                }
                guard response.statusCode == 200 else {
                    guard totalBytesWritten <= 65_536, totalBytesExpectedToWrite <= 65_536 else {
                        throw HostFileError.invalidResponse
                    }
                    return
                }
                let update: HostFileProgress? = try state.withLock { state in
                    let metadata: HostFileMetadata
                    if let validated = state.metadata {
                        metadata = validated
                    } else {
                        metadata = try GatewayFileDownloadClient.metadata(from: response, source: source)
                        try admit(metadata.bytes)
                        state.metadata = metadata
                    }
                    guard totalBytesWritten <= metadata.bytes else { throw HostFileError.invalidResponse }
                    let percent = metadata.bytes > 0 ? Int(totalBytesWritten * 100 / metadata.bytes) : 100
                    guard percent != state.lastPercent else { return nil }
                    state.lastPercent = percent
                    return HostFileProgress(bytesReceived: totalBytesWritten, totalBytes: metadata.bytes)
                }
                if let update { progress(update) }
            } catch {
                state.withLock { $0.failure = error }
                downloadTask.cancel()
            }
        }
    }
}
