import CryptoKit
import Foundation

protocol GatewayFileUploading: Sendable {
    func upload(_ upload: GatewayUpload, to host: GatewayHostConfiguration,
                progress: @escaping @Sendable (GatewayUploadProgress) -> Void) async throws -> UploadedFile
}

protocol ResumableFileUploading: GatewayFileUploading {
    func discard(_ id: UUID, on host: GatewayHostConfiguration) async throws
    func networkPathChanges() async -> AsyncStream<Void>
}

struct GatewayUpload: Sendable, Equatable {
    let id: UUID
    let file: URL
    let name: String
    let byteCount: Int64
    let sha256: String

    @concurrent
    static func prepare(id: UUID, file: URL, name: String) async throws -> GatewayUpload {
        let byteCount = Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while try autoreleasepool(invoking: {
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {
            try Task.checkCancellation()
        }
        let sha256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return GatewayUpload(id: id, file: file, name: name, byteCount: byteCount, sha256: sha256)
    }

    func body(from offset: Int64) -> InputStream? {
        let stream = InputStream(url: file)
        stream?.setProperty(NSNumber(value: offset), forKey: .fileCurrentOffsetKey)
        return stream
    }
}

struct GatewayUploadProgress: Sendable, Equatable {
    let confirmed: Int64
    let sent: Int64
}

enum GatewayUploadError: LocalizedError, Equatable {
    case interrupted(String)
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .interrupted(let message), .rejected(let message): message
        }
    }
}

actor GatewayUploadClient: ResumableFileUploading {
    private let routes: GatewayRoutes

    init(routes: GatewayRoutes) {
        self.routes = routes
    }

    func upload(_ upload: GatewayUpload, to host: GatewayHostConfiguration,
                progress: @escaping @Sendable (GatewayUploadProgress) -> Void) async throws -> UploadedFile {
        do {
            let status = try await status(of: upload, on: host)
            if let file = status.file { return try Self.verified(file, for: upload) }
            guard (0...upload.byteCount).contains(status.offset) else {
                throw GatewayUploadError.rejected("The gateway reported an impossible upload offset.")
            }
            progress(GatewayUploadProgress(confirmed: status.offset, sent: status.offset))
            return try Self.verified(try await append(upload, from: status.offset, to: host, progress: progress),
                                     for: upload)
        } catch let error as URLError {
            if Task.isCancelled { throw CancellationError() }
            throw GatewayUploadError.interrupted(error.localizedDescription)
        }
    }

    func discard(_ id: UUID, on host: GatewayHostConfiguration) async throws {
        let request = try Self.request("DELETE", id: id, on: host)
        let (data, response) = try await routes.send(request, traffic: .mutation) { try await $1.data(for: $0) }
        let status = try Self.statusCode(of: response)
        guard status == 204 || status == 409 else { throw Self.failure(status, data) }
    }

    func networkPathChanges() async -> AsyncStream<Void> {
        await routes.networkPathChanges()
    }

    private func status(of upload: GatewayUpload, on host: GatewayHostConfiguration) async throws -> Status {
        let request = try Self.request("GET", id: upload.id, on: host)
        let (data, response) = try await routes.send(request, traffic: .read) { try await $1.data(for: $0) }
        switch try Self.statusCode(of: response) {
        case 200:
            do { return try JSONDecoder().decode(Status.self, from: data) }
            catch { throw GatewayUploadError.rejected("The gateway's upload status could not be read.") }
        case 404:
            throw GatewayUploadError.rejected("Update this host's gateway to upload files.")
        case let status:
            throw Self.failure(status, data)
        }
    }

    private func append(_ upload: GatewayUpload, from offset: Int64, to host: GatewayHostConfiguration,
                        progress: @escaping @Sendable (GatewayUploadProgress) -> Void) async throws -> UploadedFile {
        var request = try Self.request("PUT", id: upload.id, name: upload.name, on: host)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(upload.byteCount - offset), forHTTPHeaderField: "Content-Length")
        request.setValue(String(offset), forHTTPHeaderField: "X-RemoteCoder-Upload-Offset")
        request.setValue(String(upload.byteCount), forHTTPHeaderField: "X-RemoteCoder-Upload-Length")
        request.setValue(upload.sha256, forHTTPHeaderField: "X-RemoteCoder-SHA256")
        let (data, response) = try await routes.send(request, traffic: .mutation) { request, session in
            var request = request
            guard let body = upload.body(from: offset) else {
                throw GatewayUploadError.rejected("The local copy can no longer be read.")
            }
            request.httpBodyStream = body
            return try await session.data(for: request, delegate: AppendDelegate(upload, from: offset, progress: progress))
        }
        switch try Self.statusCode(of: response) {
        case 201:
            do { return try JSONDecoder().decode(UploadedFile.self, from: data) }
            catch { throw GatewayUploadError.rejected("The gateway's upload reply could not be read.") }
        case 409:
            throw GatewayUploadError.interrupted("The upload continued from another offset.")
        case let status:
            throw Self.failure(status, data)
        }
    }

    private static func request(_ method: String, id: UUID, name: String? = nil,
                                on host: GatewayHostConfiguration) throws -> URLRequest {
        guard let base = host.gatewayHTTPBaseURL(),
              var components = URLComponents(url: base.appending(path: "uploads").appending(path: id.uuidString.lowercased()),
                                             resolvingAgainstBaseURL: false)
        else { throw GatewayUploadError.rejected("The gateway address is invalid.") }
        if let name { components.queryItems = [URLQueryItem(name: "name", value: name)] }
        guard let url = components.url else { throw GatewayUploadError.rejected("The gateway address is invalid.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(host.authToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func statusCode(of response: URLResponse) throws -> Int {
        guard let http = response as? HTTPURLResponse else {
            throw GatewayUploadError.interrupted("The gateway returned no HTTP response.")
        }
        return http.statusCode
    }

    private static func failure(_ status: Int, _ data: Data) -> GatewayUploadError {
        let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            ?? "The gateway answered HTTP \(status)."
        switch status {
        case 408, 429, 500, 502, 503, 504: return .interrupted(message)
        default: return .rejected(message)
        }
    }

    private static func verified(_ file: UploadedFile, for upload: GatewayUpload) throws -> UploadedFile {
        guard file.sha256 == upload.sha256, file.bytes == upload.byteCount else {
            throw GatewayUploadError.rejected("The gateway stored a different file than was sent.")
        }
        return file
    }

    private struct Status: Decodable {
        let offset: Int64
        let file: UploadedFile?
    }

    private struct ErrorBody: Decodable {
        let error: String
    }

    /// URLSession serializes delegate calls on its own queue, so the
    /// last-reported value needs no lock.
    private final class AppendDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let upload: GatewayUpload
        private let offset: Int64
        private let progress: @Sendable (GatewayUploadProgress) -> Void
        private var lastReportedPercent = -1

        init(_ upload: GatewayUpload, from offset: Int64, progress: @escaping @Sendable (GatewayUploadProgress) -> Void) {
            self.upload = upload
            self.offset = offset
            self.progress = progress
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        needNewBodyStream completionHandler: @escaping @Sendable (InputStream?) -> Void) {
            completionHandler(upload.body(from: offset))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                        totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            guard upload.byteCount > 0 else { return }
            let sent = offset + totalBytesSent
            let percent = Int(Double(sent) / Double(upload.byteCount) * 100)
            guard percent != lastReportedPercent else { return }
            lastReportedPercent = percent
            progress(GatewayUploadProgress(confirmed: offset, sent: sent))
        }
    }
}
