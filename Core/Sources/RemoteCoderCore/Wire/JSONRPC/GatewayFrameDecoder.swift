import Foundation

/// Parse away from the connection actor so a large response cannot hold
/// steering and voice control behind JSON materialization.
enum GatewayFrameDecoder {
    enum DecodePath: String, Sendable { case header, envelope }

    struct Failure: Error, Sendable {
        let decodePath: DecodePath
        let kind: String
        let path: String
        let prefix: String

        nonisolated init(_ error: DecodingError, data: Data, decodePath: DecodePath) {
            self.decodePath = decodePath
            let diagnostic = GatewayFrameDecoder.diagnostic(error)
            kind = diagnostic.kind
            path = diagnostic.path
            let bytes = data.prefix(64)
            guard !bytes.contains(0), String(data: bytes, encoding: .utf8) != nil else {
                prefix = String(repeating: "_", count: bytes.count)
                return
            }
            var quoted = false
            var escaped = false
            prefix = String(decoding: bytes.map { byte in
                if quoted {
                    if escaped { escaped = false }
                    else if byte == 92 { escaped = true }
                    else if byte == 34 { quoted = false; return byte }
                    return UInt8(95)
                }
                if byte == 34 { quoted = true; return byte }
                return [UInt8(123), 125, 91, 93, 58, 44, 32].contains(byte) ? byte : UInt8(95)
            }, as: UTF8.self)
        }
    }

    enum Frame: Sendable {
        case largeFrame(bytes: Int)
        case rawResponse(id: Int64, data: Data)
        case response(CodexAppServerV2.JSONRPC.Response)
        case error(CodexAppServerV2.JSONRPC.ErrorResponse)
        case request(CodexAppServerV2.JSONRPC.Request)
        case notification(CodexAppServerV2.JSONRPC.Notification, ServerNotification, sequence: UInt64?)
    }

    private struct Header: Decodable {
        let id: CodexAppServerV2.JSONRPC.RequestId?
        let method: String?
        let error: CodexAppServerV2.JSONRPC.ErrorObject?
        let rcSequence: UInt64?
    }

    private struct ResultEnvelope<T: Decodable>: Decodable {
        let result: T
    }

    private struct SubscriptionHandle: Decodable, Sendable {
        let status: String?
        let subscriptionId: String?
    }

    static func subscriptionHandle(from data: Data) async -> String? {
        guard let result = try? await decodeResult(SubscriptionHandle.self, from: data, dateDecodingStrategy: .deferredToDate),
              result.status == "subscribed" else { return nil }
        return result.subscriptionId
    }

    private struct LargeFrameEnvelope: Decodable {
        struct Params: Decodable { let bytes: Int }
        let params: Params
    }

    nonisolated static func diagnostic(_ error: DecodingError) -> (kind: String, path: String) {
        let kind: String
        let path: [any CodingKey]
        switch error {
        case .dataCorrupted(let context): kind = "dataCorrupted"; path = context.codingPath
        case .keyNotFound(let key, let context): kind = "keyNotFound"; path = context.codingPath + [key]
        case .typeMismatch(_, let context): kind = "typeMismatch"; path = context.codingPath
        case .valueNotFound(_, let context): kind = "valueNotFound"; path = context.codingPath
        @unknown default: kind = "unknown"; path = []
        }
        let known = ["id", "method", "error", "rcSequence", "result", "params", "code", "message", "data"]
        let safePath = path.prefix(16).map { key in
            key.intValue == nil ? (known.contains(key.stringValue) ? key.stringValue : "<key>") : "[]"
        }.joined(separator: ".")
        return (kind, String(safePath.prefix(128)))
    }

    @concurrent
    static func decode(_ data: Data, rawResponseIDs: Set<Int64>) async throws -> Frame {
        try decodeSynchronously(data, rawResponseIDs: rawResponseIDs)
    }

    nonisolated
    static func decodeSynchronously(_ data: Data, rawResponseIDs: Set<Int64>) throws -> Frame {
        let header: Header
        do { header = try JSONDecoder().decode(Header.self, from: data) }
        catch let error as DecodingError { throw Failure(error, data: data, decodePath: .header) }
        if header.method == nil, header.error == nil, case .integer(let id) = header.id,
           rawResponseIDs.contains(id) {
            return .rawResponse(id: id, data: data)
        }
        let message: CodexAppServerV2.JSONRPC.Message
        do { message = try JSONDecoder().decode(CodexAppServerV2.JSONRPC.Message.self, from: data) }
        catch let error as DecodingError { throw Failure(error, data: data, decodePath: .envelope) }
        switch message {
        case .response(let response): return .response(response)
        case .error(let error): return .error(error)
        case .request(let request): return .request(request)
        case .notification(let notification):
            if notification.method == "connection/largeFrame" {
                let bytes = try JSONDecoder().decode(LargeFrameEnvelope.self, from: data).params.bytes
                guard bytes > GatewayTransportLimits.largeFrameThresholdBytes,
                      bytes <= GatewayTransportLimits.maximumMessageSizeBytes else {
                    throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid large frame size"))
                }
                return .largeFrame(bytes: bytes)
            }
            return .notification(notification, ServerNotification.decode(method: notification.method, frame: data),
                                 sequence: header.rcSequence)
        }
    }

    @concurrent
    static func decodeResult<T: Decodable & Sendable>(
        _ type: T.Type, from data: Data, dateDecodingStrategy: JSONDecoder.DateDecodingStrategy
    ) async throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = dateDecodingStrategy
        return try decoder.decode(ResultEnvelope<T>.self, from: data).result
    }
}
