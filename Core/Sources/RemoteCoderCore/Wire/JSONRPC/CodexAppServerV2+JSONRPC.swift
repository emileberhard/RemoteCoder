import Foundation

extension CodexAppServerV2 {
    enum JSONRPC {}
}

extension CodexAppServerV2.JSONRPC {
    enum RequestId: Hashable, Sendable {
        case string(String)
        case integer(Int64)
    }
}

extension CodexAppServerV2.JSONRPC.RequestId: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid request id")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        }
    }
}

extension CodexAppServerV2.JSONRPC {
    struct Request: Codable, Sendable {
        let id: RequestId
        let method: String
        let params: JSONValue?
    }

    struct Notification: Codable, Sendable {
        let method: String
        let params: JSONValue?
    }

    struct Response: Codable, Sendable {
        let id: RequestId
        let result: JSONValue
    }

    struct ErrorObject: Codable, Sendable {
        let code: Int64
        let data: JSONValue?
        let message: String
    }

    struct ErrorResponse: Codable, Sendable {
        let error: ErrorObject
        let id: RequestId
    }

    enum Message: Sendable {
        case request(Request)
        case notification(Notification)
        case response(Response)
        case error(ErrorResponse)
    }
}

extension CodexAppServerV2.JSONRPC.Message: Codable {
    init(from decoder: Decoder) throws {
        if let value = try? CodexAppServerV2.JSONRPC.ErrorResponse(from: decoder) {
            self = .error(value)
            return
        }
        if let value = try? CodexAppServerV2.JSONRPC.Response(from: decoder) {
            self = .response(value)
            return
        }
        if let value = try? CodexAppServerV2.JSONRPC.Request(from: decoder) {
            self = .request(value)
            return
        }
        if let value = try? CodexAppServerV2.JSONRPC.Notification(from: decoder) {
            self = .notification(value)
            return
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown JSON-RPC message")
        )
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .request(let value):
            try value.encode(to: encoder)
        case .notification(let value):
            try value.encode(to: encoder)
        case .response(let value):
            try value.encode(to: encoder)
        case .error(let value):
            try value.encode(to: encoder)
        }
    }
}
