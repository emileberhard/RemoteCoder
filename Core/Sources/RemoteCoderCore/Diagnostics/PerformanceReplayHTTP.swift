#if RC_PERF_HARNESS || SWIFT_PACKAGE
import Foundation
import Synchronization

final class PerformanceReplayHTTP: URLProtocol, @unchecked Sendable {
    private struct State {
        var responses: [String: (Int, Data)] = [:]
        var requests: [String: Int] = [:]
        var blockedExternal = 0
        var missing: Set<String> = []
        var omittedSiteIcons = 0
        var omittedVisuals = 0
        var blockedVisuals = 0
    }
    private static let state = Mutex(State())

    static var omittedSiteIconFetches: Int { state.withLock { $0.omittedSiteIcons } }
    static func omitSiteIcon() { state.withLock { $0.omittedSiteIcons += 1 } }
    static var omittedVisualFetches: Int { state.withLock { $0.omittedVisuals } }
    static func omitVisual() { state.withLock { $0.omittedVisuals += 1 } }
    static var blockedVisualLoads: Int { state.withLock { $0.blockedVisuals } }
    static func blockVisual() { state.withLock { $0.blockedVisuals += 1 } }

    static func install(_ responses: [String: JSONValue]) throws {
        let encoded = try responses.mapValues { value -> (Int, Data) in
            let object = value.objectValue ?? [:]
            guard case .number(let code) = object["status"], let status = Int(exactly: code), (100...599).contains(status),
                  let body = object["body"] else {
                throw PerformanceReplayScenario.Failure.invalidScenario("HTTP fixture needs a valid status and body")
            }
            return (status, try JSONEncoder().encode(body))
        }
        state.withLock { $0 = State(responses: encoded) }
    }

    static func diagnostics() -> (requests: [String: Int], missing: [String], blockedExternal: Int) {
        state.withLock { ($0.requests, $0.missing.sorted(), $0.blockedExternal) }
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
            if state.responses[key] == nil { state.missing.insert(key) }
            return state.responses[key]
        }
        guard let (status, data) = captured,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
