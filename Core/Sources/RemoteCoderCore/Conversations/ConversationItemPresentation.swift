import Foundation

enum ConversationItemPresentation {
    static func event(
        jobID: String,
        sequence: Int,
        timestamp: Date?,
        item: CodexAppServerV2.ThreadItem,
        completed: Bool = true
    ) -> JobTimelineEvent? {
        func detail(_ label: String, _ value: String, limit: Int = 2400) -> JobTimelineEventDetail {
            JobTimelineEventDetail(id: "\(jobID)-\(sequence)-\(label)", label: label, value: clamp(value, limit: limit))
        }

        func prettyJSON(_ value: JSONValue) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
                return ""
            }
            return text
        }

        switch item {
        case .userMessage(let id, let content, let clientID):
            guard clientID == nil else { return nil }
            let transcripts = content.compactMap { input -> String? in
                guard case .text(let text, _) = input,
                      case .transcriptTail(let transcript) = RealtimeVoiceMessagePresentation.parse(text) else { return nil }
                return transcript
            }
            guard !transcripts.isEmpty else { return nil }
            let transcript = transcripts.joined(separator: "\n\n")
            return JobTimelineEvent(
                id: "\(jobID)-\(id)", sequence: sequence, kind: .status,
                title: "Voice conversation ended", subtitle: nil, timestamp: timestamp,
                details: transcript.isEmpty ? [] : [detail("Transcript", transcript, limit: 8192)]
            )

        case .agentMessage:
            return nil

        case .hookPrompt(let id, let fragments):
            let text = fragments.map(\.text).joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.isEmpty == false else { return nil }
            return JobTimelineEvent(
                id: "\(jobID)-\(id)",
                sequence: sequence,
                kind: .status,
                title: "Hook prompt",
                subtitle: clamp(text, limit: 140),
                timestamp: timestamp,
                details: [detail("prompt", text, limit: 2400)]
            )

        case .plan(let id, let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let subtitle = trimmed.isEmpty ? nil : clamp(trimmed, limit: 140)
            return JobTimelineEvent(
                id: "\(jobID)-\(id)",
                sequence: sequence,
                kind: .progress,
                title: "Plan",
                subtitle: subtitle,
                timestamp: timestamp,
                details: trimmed.isEmpty ? [] : [detail("plan", trimmed, limit: 2400)]
            )

        case .reasoning(let id, let summary, let content):
            let summaryParts = summary.compactMap(ThoughtPart.init)
            let contentText = content
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }
                .joined(separator: "\n\n")

            // Codex sends `item/started(reasoning)` with empty summary/content. Only surface the row once
            // there's something meaningful to show (typically on `item/completed`).
            let parts = summaryParts.isEmpty ? [ThoughtPart(contentText)].compactMap { $0 } : summaryParts
            guard let thought = ThoughtPresentation(parts) else { return nil }

            var details = thought.remainder.map { [detail("thought", $0, limit: 4000)] } ?? []
            if summaryParts.isEmpty == false, contentText.isEmpty == false {
                details.append(detail("content", contentText, limit: 2400))
            }
            return JobTimelineEvent(
                id: "\(jobID)-\(id)",
                sequence: sequence,
                kind: .progress,
                title: "Thinking",
                subtitle: thought.preview,
                timestamp: timestamp,
                details: details
            )

        case .commandExecution(let id, let command, let cwd, let status, let actions, let output, let exitCode, let durationMs):
            let isFinished = status != .inProgress
            let kind: JobTimelineEventKind = {
                if status == .inProgress { return .toolCall }
                if status == .failed || status == .declined { return .toolError }
                if let exitCode, exitCode != 0 { return .toolError }
                return .toolResult
            }()

            var subtitle = command.trimmingCharacters(in: .whitespacesAndNewlines)
            if subtitle.isEmpty { subtitle = "command" }
            if isFinished, let exitCode {
                subtitle = "\(clamp(subtitle, limit: 120)) (exit \(exitCode))"
            } else {
                subtitle = clamp(subtitle, limit: 120)
            }

            var details: [JobTimelineEventDetail] = []
            let trimmedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedCwd.isEmpty == false { details.append(detail("cwd", trimmedCwd, limit: 400)) }
            details.append(detail("status", status.rawValue, limit: 50))
            if let exitCode { details.append(detail("exit_code", "\(exitCode)", limit: 50)) }
            if let durationMs { details.append(detail("duration_ms", "\(durationMs)", limit: 50)) }
            if actions.isEmpty == false {
                let rendered = actions.map(commandActionDescription).joined(separator: "\n")
                details.append(detail("actions", rendered, limit: 1200))
            }
            if let output, output.isEmpty == false { details.append(detail("output", output, limit: 2400)) }

            return JobTimelineEvent(
                id: "\(jobID)-\(id)",
                sequence: sequence,
                kind: kind,
                title: "Ran command",
                subtitle: subtitle,
                timestamp: timestamp,
                details: details
            )

        case .fileChange(let id, let changes, let status):
            let kind: JobTimelineEventKind = status == .failed || status == .declined ? .toolError : (status == .inProgress ? .toolCall : .toolResult)
            let subtitle: String? = switch changes.count {
            case 0: nil
            case 1: changes.first?.path
            default: clamp(changes.map { URL(fileURLWithPath: $0.path).lastPathComponent }.joined(separator: ", "), limit: 200)
            }
            let details = changes.prefix(20).enumerated().map { idx, change in
                detail("file_\(idx + 1)", "\(change.kind) \(change.path)", limit: 400)
            }
            return JobTimelineEvent(
                id: "\(jobID)-\(id)",
                sequence: sequence,
                kind: kind,
                title: changes.count == 1 ? "Edited file" : "Edited files",
                subtitle: subtitle,
                timestamp: timestamp,
                details: details
            )

        case .mcpToolCall(let id, let server, let tool, let status, let arguments, let result, let error, let durationMs, _, _):
            let kind: JobTimelineEventKind = {
                if status == .inProgress { return .toolCall }
                if status == .failed || error != nil { return .toolError }
                return .toolResult
            }()
            var details: [JobTimelineEventDetail] = []
            details.append(detail("server", server, limit: 200))
            details.append(detail("tool", tool, limit: 200))
            details.append(detail("status", status.rawValue, limit: 50))
            if let durationMs { details.append(detail("duration_ms", "\(durationMs)", limit: 50)) }
            details.append(detail("arguments", prettyJSON(arguments), limit: 2400))
            if let result {
                if let structured = result.structuredContent {
                    details.append(detail("result", prettyJSON(structured), limit: 2400))
                }
            }
            if let error { details.append(detail("error", error.message, limit: 800)) }
            return JobTimelineEvent(
                id: "\(jobID)-\(id)",
                sequence: sequence,
                kind: kind,
                title: "Tool call",
                subtitle: "\(server): \(tool)",
                timestamp: timestamp,
                details: details
            )

        case .dynamicToolCall(let id, let namespace, let tool, let status, let arguments, let success, let contentItems, let durationMs, _, _):
            let kind: JobTimelineEventKind = {
                if status == .inProgress { return .toolCall }
                if status == .failed || success == false { return .toolError }
                return .toolResult
            }()
            var details: [JobTimelineEventDetail] = []
            if let namespace, namespace.isEmpty == false {
                details.append(detail("namespace", namespace, limit: 200))
            }
            details.append(detail("tool", tool, limit: 200))
            details.append(detail("status", status.rawValue, limit: 50))
            if let durationMs { details.append(detail("duration_ms", "\(durationMs)", limit: 50)) }
            details.append(detail("arguments", prettyJSON(arguments), limit: 2400))
            if let contentItems, contentItems.isEmpty == false {
                let rendered = contentItems.compactMap { item in
                    switch item {
                    case .inputText(let text):
                        return text
                    case .inputImage(let imageUrl):
                        return imageUrl.isEmpty || imageUrl.hasPrefix("data:") ? "Image" : imageUrl
                    }
                }.joined(separator: "\n")
                if rendered.isEmpty == false {
                    details.append(detail("content", rendered, limit: 2400))
                }
            }
            return JobTimelineEvent(
                id: "\(jobID)-\(id)",
                sequence: sequence,
                kind: kind,
                title: "Tool call",
                subtitle: namespace.map { "\($0): \(tool)" } ?? tool,
                timestamp: timestamp,
                details: details
            )

        case .subAgentActivity(let id, let activity, let threadID, let path):
            return JobTimelineEvent(id: "\(jobID)-\(id)", sequence: sequence,
                kind: activity == "started" ? .toolCall : .toolResult,
                title: "Agent", subtitle: "\(path) · \(activity)", timestamp: timestamp,
                details: [detail("conversation", threadID, limit: 200)])

        case .collabAgentToolCall(let id, let tool, let status, let receiverThreadIds, let prompt):
            let kind: JobTimelineEventKind = status == .failed ? .toolError : (status == .inProgress ? .toolCall : .toolResult)
            let details: [JobTimelineEventDetail] = [
                detail("tool", tool, limit: 200),
                detail("status", status.rawValue, limit: 50),
                receiverThreadIds.isEmpty ? nil : detail("receivers", receiverThreadIds.joined(separator: ", "), limit: 800),
                prompt.map { detail("prompt", $0, limit: 2400) },
            ].compactMap { $0 }
            return JobTimelineEvent(
                id: "\(jobID)-\(id)",
                sequence: sequence,
                kind: kind,
                title: "Collaboration",
                subtitle: tool,
                timestamp: timestamp,
                details: details
            )

        case .webSearch(let id, let query, let action):
            let subtitle = clamp(query, limit: 140)
            var details: [JobTimelineEventDetail] = []
            if let action {
                details.append(detail("action", webSearchActionDescription(action), limit: 800))
            }
            return JobTimelineEvent(
                id: "\(jobID)-\(id)",
                sequence: sequence,
                kind: .toolResult,
                title: "Web search",
                subtitle: subtitle,
                timestamp: timestamp,
                details: details
            )

        case .imageView:
            return nil

        case .imageGeneration(let id, let status, let result, let revisedPrompt, let savedPath):
            let details: [JobTimelineEventDetail] = [
                detail("status", status, limit: 80),
                result.isEmpty ? nil : detail("result", result, limit: 1600),
                revisedPrompt.map { detail("revised_prompt", $0, limit: 1600) },
                savedPath.map { detail("saved_path", $0, limit: 400) },
            ].compactMap { $0 }
            return JobTimelineEvent(
                id: "\(jobID)-\(id)",
                sequence: sequence,
                kind: status == "failed" ? .toolError : .toolResult,
                title: "Generated image",
                subtitle: savedPath ?? clamp(result, limit: 140),
                timestamp: timestamp,
                details: details
            )

        case .enteredReviewMode(let id, let review):
            return JobTimelineEvent(
                id: "\(jobID)-\(id)",
                sequence: sequence,
                kind: .status,
                title: "Entered review mode",
                subtitle: clamp(review, limit: 140),
                timestamp: timestamp,
                details: [detail("review", review, limit: 2400)]
            )

        case .exitedReviewMode(let id, let review):
            return JobTimelineEvent(
                id: "\(jobID)-\(id)",
                sequence: sequence,
                kind: .status,
                title: "Exited review mode",
                subtitle: clamp(review, limit: 140),
                timestamp: timestamp,
                details: [detail("review", review, limit: 2400)]
            )

        case .contextCompaction:
            // Compaction is a persistent transcript boundary, not a tool activity.
            return nil

        case .unknown(let id, let type, let payload):
            return JobTimelineEvent(
                id: "\(jobID)-\(id)",
                sequence: sequence,
                kind: .unknown,
                title: type,
                subtitle: nil,
                timestamp: timestamp,
                details: [detail("payload", prettyJSON(payload), limit: 2400)]
            )
        }
    }


    private struct ThoughtPart {
        let heading: String?
        let body: String

        init?(_ raw: String) {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.hasPrefix("**") else {
                guard text.isEmpty == false else { return nil }
                heading = nil
                body = text
                return
            }
            let afterOpening = text.dropFirst(2)
            let closing = afterOpening.range(of: "**")
            let title = afterOpening[..<(closing?.lowerBound ?? afterOpening.endIndex)]
                .trimmingCharacters(in: .whitespaces)
            let rest = closing.map { afterOpening[$0.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            guard title.isEmpty == false || rest.isEmpty == false else { return nil }
            heading = title.isEmpty ? nil : title
            body = rest
        }
    }

    private struct ThoughtPresentation {
        let preview: String
        let remainder: String?

        init?(_ parts: [ThoughtPart]) {
            guard parts.isEmpty == false else { return nil }
            if parts.allSatisfy({ $0.body.isEmpty }) {
                preview = parts.compactMap(\.heading).joined(separator: "\n")
                remainder = nil
                return
            }
            let text = parts
                .map { part in [part.heading, part.body.isEmpty ? nil : part.body].compactMap { $0 }.joined(separator: "\n\n") }
                .joined(separator: "\n\n")
            guard let lineEnd = text.firstIndex(where: \.isNewline) else {
                preview = text
                remainder = nil
                return
            }
            let rest = text[lineEnd...].trimmingCharacters(in: .whitespacesAndNewlines)
            preview = String(text[..<lineEnd])
            remainder = rest.isEmpty ? nil : rest
        }
    }

    private static func commandActionDescription(_ action: JSONValue) -> String {
        let fields = action.objectValue ?? [:]
        let command = String(reflecting: fields["command"]?.stringValue ?? "")
        switch fields["type"]?.stringValue {
        case "read":
            let name = String(reflecting: fields["name"]?.stringValue ?? "")
            let path = String(reflecting: fields["path"]?.stringValue ?? "")
            return "read(command: \(command), name: \(name), path: \(path))"
        case "listFiles":
            let path = fields["path"]?.stringValue
            return "listFiles(command: \(command), path: \(String(describing: path)))"
        case "search":
            let query = fields["query"]?.stringValue
            let path = fields["path"]?.stringValue
            return "search(command: \(command), query: \(String(describing: query)), path: \(String(describing: path)))"
        default:
            return "unknown(command: \(command))"
        }
    }

    private static func webSearchActionDescription(_ action: JSONValue) -> String {
        let fields = action.objectValue ?? [:]
        switch fields["type"]?.stringValue {
        case "search":
            let query = fields["query"]?.stringValue
            let queries = fields["queries"]?.arrayValue?.compactMap(\.stringValue)
            return "search(query: \(String(describing: query)), queries: \(String(describing: queries)))"
        case "openPage":
            let url = fields["url"]?.stringValue
            return "openPage(url: \(String(describing: url)))"
        case "findInPage":
            let url = fields["url"]?.stringValue
            let pattern = fields["pattern"]?.stringValue
            return "findInPage(url: \(String(describing: url)), pattern: \(String(describing: pattern)))"
        default:
            return "other"
        }
    }

    private static func clamp(_ value: String, limit: Int) -> String {
        guard value.utf8.count > limit,
              let end = value.index(value.startIndex, offsetBy: limit, limitedBy: value.endIndex),
              end < value.endIndex else { return value }
        return String(value[..<end]) + "…"
    }
}
