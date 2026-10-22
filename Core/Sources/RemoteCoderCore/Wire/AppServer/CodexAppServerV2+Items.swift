extension CodexAppServerV2 {
    struct ByteRange: Codable, Sendable, Hashable {
        let start: Int
        let end: Int
    }

    struct TextElement: Codable, Sendable, Hashable {
        let byteRange: ByteRange
        let placeholder: String?
    }

    struct ToolMedia: Codable, Sendable, Hashable {
        let path: String
        let mimeType: String
        var name: String?
    }

    enum ImageReference: Sendable, Hashable, Codable {
        case inline(url: String)
        case file(id: String)
    }

    enum UserInput: Sendable, Equatable {
        case text(text: String, textElements: [TextElement])
        case image(ImageReference)
        case localImage(path: String)
        case skill(name: String, path: String)
        case mention(name: String, path: String)
    }

    enum ThreadItem: Sendable, Equatable {
        case userMessage(id: String, content: [UserInput], clientId: String? = nil)
        case hookPrompt(id: String, fragments: [HookPromptFragment])
        case agentMessage(
            id: String,
            text: String,
            phase: AgentMessagePhase? = nil,
            delivery: AgentMessageDelivery? = nil,
            questions: [AsyncUserInputQuestion]? = nil
        )
        case plan(id: String, text: String)
        case reasoning(id: String, summary: [String], content: [String])
        case commandExecution(
            id: String,
            command: String,
            cwd: String,
            status: CommandExecutionStatus,
            commandActions: [JSONValue],
            aggregatedOutput: String?,
            exitCode: Int?,
            durationMs: Int64?
        )
        case fileChange(id: String, changes: [FileUpdateChange], status: PatchApplyStatus)
        case mcpToolCall(
            id: String,
            server: String,
            tool: String,
            status: McpToolCallStatus,
            arguments: JSONValue,
            result: McpToolCallResult?,
            error: McpToolCallError?,
            durationMs: Int64?,
            media: [ToolMedia],
            visual: HTMLVisualPublication? = nil
        )
        case dynamicToolCall(
            id: String,
            namespace: String?,
            tool: String,
            status: DynamicToolCallStatus,
            arguments: JSONValue,
            success: Bool?,
            contentItems: [DynamicToolCallOutputContentItem]?,
            durationMs: Int64?,
            media: [ToolMedia],
            visual: HTMLVisualPublication? = nil
        )
        case subAgentActivity(id: String, kind: String, agentThreadId: String, agentPath: String)
        case collabAgentToolCall(
            id: String,
            tool: CollabAgentTool,
            status: CollabAgentToolCallStatus,
            receiverThreadIds: [String],
            prompt: String?
        )
        case webSearch(id: String, query: String, action: JSONValue?)
        case imageView(id: String, path: String)
        case imageGeneration(
            id: String,
            status: String,
            result: String,
            revisedPrompt: String?,
            savedPath: String?
        )
        case enteredReviewMode(id: String, review: String)
        case exitedReviewMode(id: String, review: String)
        case contextCompaction(id: String)
        case unknown(id: String, type: String, payload: JSONValue)
    }

    struct HookPromptFragment: Codable, Sendable, Hashable {
        let text: String
    }

    struct AgentMessagePhase: RawRepresentable, Sendable, Hashable {
        let rawValue: String
        init(rawValue: String) { self.rawValue = rawValue }
        static let commentary = Self(rawValue: "commentary")
        static let finalAnswer = Self(rawValue: "final_answer")
    }

    /// `async` marks a message the model emitted without waiting for a reply;
    /// today that is only a `request_user_input_async` question item.
    struct AgentMessageDelivery: RawRepresentable, Sendable, Hashable {
        let rawValue: String
        init(rawValue: String) { self.rawValue = rawValue }
        static let `async` = Self(rawValue: "async")
    }

    /// One question of an async user-input item. The tool contract puts the
    /// recommended answer first; `options == nil` means free text only.
    struct AsyncUserInputQuestion: Codable, Sendable, Hashable {
        let title: String
        let options: [String]?
    }

    enum DynamicToolCallStatus: String, Codable, Sendable, Hashable {
        case inProgress
        case completed
        case failed
    }

    enum CommandExecutionStatus: String, Codable, Sendable, Hashable {
        case inProgress
        case completed
        case failed
        case declined
    }

    typealias CollabAgentTool = String

    struct FileUpdateChange: Codable, Sendable, Hashable {
        let path: String
        let kind: PatchChangeKind
    }

    enum PatchChangeKind: Sendable, Hashable {
        case add
        case delete
        case update(movePath: String?)
    }

    enum PatchApplyStatus: String, Codable, Sendable, Hashable {
        case inProgress
        case completed
        case failed
        case declined
    }

    enum McpToolCallStatus: String, Codable, Sendable, Hashable {
        case inProgress
        case completed
        case failed
    }

    struct CollabAgentToolCallStatus: RawRepresentable, Sendable, Hashable {
        let rawValue: String
        init(rawValue: String) { self.rawValue = rawValue }
        static let inProgress = Self(rawValue: "inProgress")
        static let completed = Self(rawValue: "completed")
        static let failed = Self(rawValue: "failed")
        static let interrupted = Self(rawValue: "interrupted")
    }

    struct McpToolCallResult: Codable, Sendable, Equatable {
        let structuredContent: JSONValue?
    }

    struct McpToolCallError: Codable, Sendable, Hashable {
        let message: String
    }


}

extension CodexAppServerV2.AgentMessagePhase: Codable {
    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension CodexAppServerV2.AgentMessageDelivery: Codable {
    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension CodexAppServerV2.CollabAgentToolCallStatus: Codable {
    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension CodexAppServerV2.TextElement {
    private enum CodingKeys: String, CodingKey {
        case byteRange
        case placeholder
    }
}

extension CodexAppServerV2.UserInput: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case textElements
        case url
        case fileId
        case path
        case name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            let textElements = try container.decodeIfPresent([CodexAppServerV2.TextElement].self, forKey: .textElements) ?? []
            self = .text(text: text, textElements: textElements)
        case "image":
            if let url = try container.decodeIfPresent(String.self, forKey: .url) {
                self = .image(.inline(url: url))
            } else {
                self = .image(.file(id: try container.decode(String.self, forKey: .fileId)))
            }
        case "localImage":
            self = .localImage(path: try container.decode(String.self, forKey: .path))
        case "skill":
            self = .skill(
                name: try container.decode(String.self, forKey: .name),
                path: try container.decode(String.self, forKey: .path)
            )
        case "mention":
            self = .mention(
                name: try container.decode(String.self, forKey: .name),
                path: try container.decode(String.self, forKey: .path)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown user input type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text, let textElements):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
            if !textElements.isEmpty {
                try container.encode(textElements, forKey: .textElements)
            }
        case .image(.inline(let url)):
            try container.encode("image", forKey: .type)
            try container.encode(url, forKey: .url)
        case .image(.file(let id)):
            try container.encode("image", forKey: .type)
            try container.encode(id, forKey: .fileId)
        case .localImage(let path):
            try container.encode("localImage", forKey: .type)
            try container.encode(path, forKey: .path)
        case .skill(let name, let path):
            try container.encode("skill", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(path, forKey: .path)
        case .mention(let name, let path):
            try container.encode("mention", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(path, forKey: .path)
        }
    }
}

extension CodexAppServerV2.PatchChangeKind: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case movePath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "add":
            self = .add
        case "delete":
            self = .delete
        case "update":
            self = .update(movePath: try container.decodeIfPresent(String.self, forKey: .movePath))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown patch change kind: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .add:
            try container.encode("add", forKey: .type)
        case .delete:
            try container.encode("delete", forKey: .type)
        case .update(let movePath):
            try container.encode("update", forKey: .type)
            try container.encodeIfPresent(movePath, forKey: .movePath)
        }
    }
}

private enum ThreadItemPayload {
    typealias V2 = CodexAppServerV2

    struct Header: Decodable {
        let type: String
        let id: String
    }

    struct Tagged<Fields: Encodable>: Encodable {
        private enum Keys: String, CodingKey { case type, id }
        let type: String
        let id: String
        let fields: Fields

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(type, forKey: .type)
            try container.encode(id, forKey: .id)
            try fields.encode(to: encoder)
        }
    }

    struct UserMessage: Codable {
        let content: [V2.UserInput]
        let clientId: String?
    }

    struct HookPrompt: Codable {
        let fragments: [V2.HookPromptFragment]
    }

    struct AgentMessage: Codable {
        let text: String
        let phase: V2.AgentMessagePhase?
        let delivery: V2.AgentMessageDelivery?
        let questions: [V2.AsyncUserInputQuestion]?
    }

    struct Plan: Codable {
        let text: String
    }

    struct Reasoning: Codable {
        let summary: [String]
        let content: [String]

        init(summary: [String], content: [String]) {
            self.summary = summary
            self.content = content
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            summary = try container.decodeIfPresent([String].self, forKey: .summary) ?? []
            content = try container.decodeIfPresent([String].self, forKey: .content) ?? []
        }
    }

    struct CommandExecution: Codable {
        let command: String
        let cwd: String
        let status: V2.CommandExecutionStatus
        let commandActions: [JSONValue]
        let aggregatedOutput: String?
        let exitCode: Int?
        let durationMs: Int64?
    }

    struct FileChange: Codable {
        let changes: [V2.FileUpdateChange]
        let status: V2.PatchApplyStatus
    }

    struct McpToolCall: Codable {
        let server: String
        let tool: String
        let status: V2.McpToolCallStatus
        let arguments: JSONValue
        let result: V2.McpToolCallResult?
        let error: V2.McpToolCallError?
        let durationMs: Int64?
        let rcMedia: [V2.ToolMedia]?
        let rcVisual: HTMLVisualPublication?
    }

    struct DynamicToolCall: Codable {
        let namespace: String?
        let tool: String
        let status: V2.DynamicToolCallStatus
        let arguments: JSONValue
        let success: Bool?
        let contentItems: [V2.DynamicToolCallOutputContentItem]?
        let durationMs: Int64?
        let rcMedia: [V2.ToolMedia]?
        let rcVisual: HTMLVisualPublication?
    }

    struct SubAgentActivity: Codable {
        let kind: String
        let agentThreadId: String
        let agentPath: String
    }

    struct CollabAgentToolCall: Codable {
        let tool: V2.CollabAgentTool
        let status: V2.CollabAgentToolCallStatus
        let receiverThreadIds: [String]
        let prompt: String?
    }

    struct WebSearch: Codable {
        let query: String
        let action: JSONValue?
    }

    struct ImageGeneration: Codable {
        let status: String
        let result: String
        let revisedPrompt: String?
        let savedPath: String?
    }

    struct Review: Codable {
        let review: String
    }

    struct ImageView: Codable {
        let path: String?
    }

    struct Empty: Codable {}
}

extension CodexAppServerV2.ThreadItem: Codable {
    init(from decoder: Decoder) throws {
        typealias Payload = ThreadItemPayload
        let header = try Payload.Header(from: decoder)
        let id = header.id

        switch header.type {
        case "userMessage":
            let payload = try Payload.UserMessage(from: decoder)
            self = .userMessage(id: id, content: payload.content, clientId: payload.clientId)
        case "hookPrompt":
            self = .hookPrompt(id: id, fragments: try Payload.HookPrompt(from: decoder).fragments)
        case "agentMessage":
            let payload = try Payload.AgentMessage(from: decoder)
            self = .agentMessage(id: id, text: payload.text, phase: payload.phase, delivery: payload.delivery,
                                 questions: payload.questions)
        case "plan":
            self = .plan(id: id, text: try Payload.Plan(from: decoder).text)
        case "reasoning":
            let payload = try Payload.Reasoning(from: decoder)
            self = .reasoning(id: id, summary: payload.summary, content: payload.content)
        case "commandExecution":
            let payload = try Payload.CommandExecution(from: decoder)
            self = .commandExecution(id: id, command: payload.command, cwd: payload.cwd, status: payload.status,
                commandActions: payload.commandActions, aggregatedOutput: payload.aggregatedOutput,
                exitCode: payload.exitCode, durationMs: payload.durationMs)
        case "fileChange":
            let payload = try Payload.FileChange(from: decoder)
            self = .fileChange(id: id, changes: payload.changes, status: payload.status)
        case "mcpToolCall":
            let payload = try Payload.McpToolCall(from: decoder)
            self = .mcpToolCall(id: id, server: payload.server, tool: payload.tool, status: payload.status,
                arguments: payload.arguments, result: payload.result, error: payload.error, durationMs: payload.durationMs,
                media: payload.rcMedia ?? [], visual: payload.rcVisual)
        case "dynamicToolCall":
            let payload = try Payload.DynamicToolCall(from: decoder)
            self = .dynamicToolCall(id: id, namespace: payload.namespace, tool: payload.tool, status: payload.status,
                arguments: payload.arguments, success: payload.success, contentItems: payload.contentItems,
                durationMs: payload.durationMs, media: payload.rcMedia ?? [], visual: payload.rcVisual)
        case "subAgentActivity":
            let payload = try Payload.SubAgentActivity(from: decoder)
            self = .subAgentActivity(id: id, kind: payload.kind, agentThreadId: payload.agentThreadId,
                                     agentPath: payload.agentPath)
        case "collabAgentToolCall":
            let payload = try Payload.CollabAgentToolCall(from: decoder)
            self = .collabAgentToolCall(id: id, tool: payload.tool, status: payload.status,
                                        receiverThreadIds: payload.receiverThreadIds, prompt: payload.prompt)
        case "webSearch":
            let payload = try Payload.WebSearch(from: decoder)
            self = .webSearch(id: id, query: payload.query, action: payload.action)
        case "imageView":
            if let path = try Payload.ImageView(from: decoder).path {
                self = .imageView(id: id, path: path)
            } else {
                self = .unknown(id: id, type: header.type, payload: try JSONValue(from: decoder))
            }
        case "imageGeneration":
            let payload = try Payload.ImageGeneration(from: decoder)
            self = .imageGeneration(id: id, status: payload.status, result: payload.result,
                                    revisedPrompt: payload.revisedPrompt, savedPath: payload.savedPath)
        case "enteredReviewMode":
            self = .enteredReviewMode(id: id, review: try Payload.Review(from: decoder).review)
        case "exitedReviewMode":
            self = .exitedReviewMode(id: id, review: try Payload.Review(from: decoder).review)
        case "contextCompaction":
            self = .contextCompaction(id: id)
        default:
            let payload = (try? JSONValue(from: decoder)) ?? .object([:])
            self = .unknown(id: id, type: header.type, payload: payload)
        }
    }

    func encode(to encoder: Encoder) throws {
        typealias Payload = ThreadItemPayload
        func write<Fields: Encodable>(_ type: String, _ id: String, _ fields: Fields) throws {
            try Payload.Tagged(type: type, id: id, fields: fields).encode(to: encoder)
        }
        switch self {
        case .userMessage(let id, let content, let clientId):
            try write("userMessage", id, Payload.UserMessage(content: content, clientId: clientId))
        case .hookPrompt(let id, let fragments):
            try write("hookPrompt", id, Payload.HookPrompt(fragments: fragments))
        case .agentMessage(let id, let text, let phase, let delivery, let questions):
            try write("agentMessage", id, Payload.AgentMessage(text: text, phase: phase, delivery: delivery, questions: questions))
        case .plan(let id, let text):
            try write("plan", id, Payload.Plan(text: text))
        case .reasoning(let id, let summary, let content):
            try write("reasoning", id, Payload.Reasoning(summary: summary, content: content))
        case .commandExecution(let id, let command, let cwd, let status, let commandActions, let aggregatedOutput, let exitCode, let durationMs):
            try write("commandExecution", id, Payload.CommandExecution(command: command, cwd: cwd, status: status,
                commandActions: commandActions, aggregatedOutput: aggregatedOutput, exitCode: exitCode, durationMs: durationMs))
        case .fileChange(let id, let changes, let status):
            try write("fileChange", id, Payload.FileChange(changes: changes, status: status))
        case .mcpToolCall(let id, let server, let tool, let status, let arguments, let result, let error, let durationMs, let media, let visual):
            try write("mcpToolCall", id, Payload.McpToolCall(server: server, tool: tool, status: status, arguments: arguments,
                result: result, error: error, durationMs: durationMs, rcMedia: media.isEmpty ? nil : media, rcVisual: visual))
        case .dynamicToolCall(let id, let namespace, let tool, let status, let arguments, let success, let contentItems, let durationMs, let media, let visual):
            try write("dynamicToolCall", id, Payload.DynamicToolCall(namespace: namespace, tool: tool, status: status,
                arguments: arguments, success: success, contentItems: contentItems, durationMs: durationMs,
                rcMedia: media.isEmpty ? nil : media, rcVisual: visual))
        case .subAgentActivity(let id, let kind, let agentThreadId, let agentPath):
            try write("subAgentActivity", id, Payload.SubAgentActivity(kind: kind, agentThreadId: agentThreadId, agentPath: agentPath))
        case .collabAgentToolCall(let id, let tool, let status, let receiverThreadIds, let prompt):
            try write("collabAgentToolCall", id, Payload.CollabAgentToolCall(tool: tool, status: status,
                receiverThreadIds: receiverThreadIds, prompt: prompt))
        case .webSearch(let id, let query, let action):
            try write("webSearch", id, Payload.WebSearch(query: query, action: action))
        case .imageView(let id, let path):
            try write("imageView", id, Payload.ImageView(path: path))
        case .imageGeneration(let id, let status, let result, let revisedPrompt, let savedPath):
            try write("imageGeneration", id, Payload.ImageGeneration(status: status, result: result,
                revisedPrompt: revisedPrompt, savedPath: savedPath))
        case .enteredReviewMode(let id, let review):
            try write("enteredReviewMode", id, Payload.Review(review: review))
        case .exitedReviewMode(let id, let review):
            try write("exitedReviewMode", id, Payload.Review(review: review))
        case .contextCompaction(let id):
            try write("contextCompaction", id, Payload.Empty())
        case .unknown(let id, let type, let payload):
            var merged: [String: JSONValue]
            if case .object(let object) = payload {
                merged = object
            } else {
                merged = [:]
            }
            merged["id"] = .string(id)
            merged["type"] = .string(type)
            var dynamicContainer = encoder.container(keyedBy: CodexAppServerV2.DynamicCodingKey.self)
            for (key, value) in merged {
                try dynamicContainer.encode(value, forKey: CodexAppServerV2.DynamicCodingKey(key))
            }
        }
    }
}

extension CodexAppServerV2.ThreadItem {
    /// The questions of a `request_user_input_async` item; nil for every other item.
    var asyncQuestions: [CodexAppServerV2.AsyncUserInputQuestion]? {
        guard case .agentMessage(_, _, _, let delivery, let questions) = self,
              delivery == .async, let questions, !questions.isEmpty else { return nil }
        return questions
    }

    var publishedVisual: HTMLVisualPublication? {
        switch self {
        case .mcpToolCall(_, _, _, _, _, _, _, _, _, let visual),
             .dynamicToolCall(_, _, _, _, _, _, _, _, _, let visual): visual
        default: nil
        }
    }

    var toolMedia: (tool: String, media: [CodexAppServerV2.ToolMedia])? {
        switch self {
        case .mcpToolCall(_, _, let tool, _, _, _, _, _, let media, _), .dynamicToolCall(_, _, let tool, _, _, _, _, _, let media, _):
            media.isEmpty ? nil : (tool, media)
        default: nil
        }
    }

    var id: String {
        switch self {
        case .userMessage(let id, _, _), .hookPrompt(let id, _), .agentMessage(let id, _, _, _, _),
             .plan(let id, _), .imageView(let id, _), .enteredReviewMode(let id, _),
             .exitedReviewMode(let id, _), .contextCompaction(let id): id
        case .reasoning(let id, _, _), .fileChange(let id, _, _),
             .webSearch(let id, _, _), .unknown(let id, _, _): id
        case .commandExecution(let id, _, _, _, _, _, _, _): id
        case .mcpToolCall(let id, _, _, _, _, _, _, _, _, _): id
        case .dynamicToolCall(let id, _, _, _, _, _, _, _, _, _): id
        case .subAgentActivity(let id, _, _, _): id
        case .collabAgentToolCall(let id, _, _, _, _): id
        case .imageGeneration(let id, _, _, _, _): id
        }
    }
}
