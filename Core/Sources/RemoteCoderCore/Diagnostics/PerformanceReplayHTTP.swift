#if RC_PERF_HARNESS || SWIFT_PACKAGE
import Foundation
import CryptoKit
import Synchronization

final class PerformanceReplayHTTP: URLProtocol, @unchecked Sendable {
    private struct State {
        var responses: [String: (Int, Data)] = [:]
        var requests: [String: Int] = [:]
        var blockedExternal = 0
        var unrecordedHealthRequests = 0
        var missing: Set<String> = []
        var omittedSiteIcons = 0
        var omittedVisuals = 0
        var blockedVisuals = 0
        var telemetryDirectory: URL?
        var telemetryFiles: [String] = []
        var telemetryBytes = 0
        var telemetryFailures: [String] = []
    }
    private static let state = Mutex(State())

    static var omittedSiteIconFetches: Int { state.withLock { $0.omittedSiteIcons } }
    static func omitSiteIcon() { state.withLock { $0.omittedSiteIcons += 1 } }
    static var omittedVisualFetches: Int { state.withLock { $0.omittedVisuals } }
    static func omitVisual() { state.withLock { $0.omittedVisuals += 1 } }
    static var blockedVisualLoads: Int { state.withLock { $0.blockedVisuals } }
    static func blockVisual() { state.withLock { $0.blockedVisuals += 1 } }
    static var telemetryCapture: (files: [String], failures: [String]) {
        state.withLock { ($0.telemetryFiles, $0.telemetryFailures) }
    }

    static func install(_ responses: [String: JSONValue], telemetryDirectory: URL? = nil) throws {
        let encoded = try responses.mapValues { value -> (Int, Data) in
            let object = value.objectValue ?? [:]
            guard case .number(let code) = object["status"], let status = Int(exactly: code), (100...599).contains(status),
                  let body = object["body"] else {
                throw PerformanceReplayScenario.Failure.invalidScenario("HTTP fixture needs a valid status and body")
            }
            return (status, try JSONEncoder().encode(body))
        }
        if let telemetryDirectory {
            try FileManager.default.createDirectory(at: telemetryDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        state.withLock { $0 = State(responses: encoded, telemetryDirectory: telemetryDirectory) }
    }

    static func diagnostics() -> (requests: [String: Int], missing: [String], blockedExternal: Int, unrecordedHealthRequests: Int) {
        state.withLock { ($0.requests, $0.missing.sorted(), $0.blockedExternal, $0.unrecordedHealthRequests) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "http" || request.url?.scheme == "https"
    }

    override class func canInit(with task: URLSessionTask) -> Bool {
        task.currentRequest.map { canInit(with: $0) } ?? false
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        let loopback = ["127.0.0.1", "localhost", "::1"].contains(url.host() ?? "")
        let key = "\(request.httpMethod ?? "GET") \(url.path())"
        let captured = Self.state.withLock { state -> (Int, Data)? in
            guard loopback else { state.blockedExternal += 1; return nil }
            state.requests[key, default: 0] += 1
            if let response = state.responses[key] { return response }
            if key == "GET /health" {
                state.unrecordedHealthRequests += 1
                return (404, Data("{}".utf8))
            }
            state.missing.insert(key)
            return nil
        }
        guard let (status, data) = captured,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        if key == "POST /app-logs", request.value(forHTTPHeaderField: "X-RemoteCoder-Segment")?.hasSuffix("-telemetry") == true {
            Self.retainTelemetry(Self.body(request))
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func body(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = stream.read(&buffer, maxLength: min(buffer.count, 4 * 1_048_576 + 1 - data.count))
            if count < 0 { return nil }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
            if data.count > 4 * 1_048_576 { return nil }
        }
    }

    override func stopLoading() {}

    @concurrent static func retainPendingTelemetry(at directory: URL) async {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            for file in files where file.lastPathComponent.hasSuffix("-telemetry.jsonl") {
                guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1_048_576 else { continue }
                retainTelemetry(GzipEncoding.gzipped(try Data(contentsOf: file)))
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        } catch {
            state.withLock { if $0.telemetryFailures.count < 16 { $0.telemetryFailures.append("Could not read pending telemetry uploads") } }
        }
    }

    private static func retainTelemetry(_ body: Data?) {
        let destination = state.withLock { state -> URL? in
            guard let directory = state.telemetryDirectory else { return nil }
            guard let body, state.telemetryBytes + body.count <= 16 * 1_048_576, state.telemetryFiles.count < 128 else {
                if state.telemetryFailures.isEmpty { state.telemetryFailures.append("Telemetry upload capture missing or exceeds 16 MiB/128 segments") }
                return nil
            }
            let name = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined() + ".jsonl.gz"
            if state.telemetryFiles.contains(name) { return nil }
            state.telemetryBytes += body.count
            state.telemetryFiles.append(name)
            return directory.appending(path: name)
        }
        guard let body, let destination else { return }
        do {
            try body.write(to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            state.withLock { if $0.telemetryFailures.count < 16 { $0.telemetryFailures.append("Could not retain captured telemetry upload") } }
        }
    }
}
#endif
