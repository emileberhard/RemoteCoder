import Foundation

/// A file the gateway stored from an `/uploads/<id>` session, addressed by
/// the absolute host path the agent reads it from.
struct UploadedFile: Sendable, Equatable, Codable {
    let path: String
    let bytes: Int64
    let sha256: String

    /// The stored name; the gateway may have reduced the picked name to a
    /// safe subset.
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

/// A file the user attached from Files, either still staged locally or
/// already on the gateway host. Staged bytes live in the host's
/// `UploadStaging` directory under the attachment id; once uploaded, only
/// the host path remains and the staged copy is removed.
struct ComposerFileAttachment: Identifiable, Sendable, Equatable, Codable {
    enum Placement: Sendable, Equatable, Codable {
        case staged(fileName: String)
        case uploaded(UploadedFile)
    }

    let id: UUID
    /// The name the user picked, for display; `uploaded.name` is what the
    /// host kept.
    let name: String
    let byteCount: Int64
    var placement: Placement

    var uploaded: UploadedFile? {
        if case .uploaded(let file) = placement { return file }
        return nil
    }
}

/// The plain-text block appended after the typed message so both providers
/// receive the same handoff: absolute paths on the host and nothing else.
/// Codex `turn/start` has no document input and Claude's stream-json accepts
/// only image and PDF blocks, while both read any file on the host from a
/// path. Keep it byte-identical to `attached_files_block` in
/// `dev-tools/src/remotecoder_tools/probes.py`, which is what the live probe sends.
enum AttachedFilesPromptBlock {
    static func render(_ paths: [String]) -> String {
        (["Attached files (uploaded to this host; use these absolute paths):"] + paths.map { "- \($0)" })
            .joined(separator: "\n")
    }

    static func append(to body: String, paths: [String]) -> String {
        guard !paths.isEmpty else { return body }
        return body.isEmpty ? render(paths) : body + "\n\n" + render(paths)
    }
}

extension AttachedFilesPromptBlock {
    static func parse(_ text: String) -> (body: String, paths: [String])? {
        let header = render([]) + "\n"
        guard let range = PromptMarkerSearch.range(of: header, in: text, backwards: true) else { return nil }
        let prefix = text[..<range.lowerBound]
        guard prefix.isEmpty || prefix.unicodeScalars.suffix(2).elementsEqual("\n\n".unicodeScalars) else { return nil }
        let lines = text[range.upperBound...].split(separator: "\n", omittingEmptySubsequences: false)
        guard !lines.isEmpty, lines.allSatisfy({ $0.hasPrefix("- /") && $0.count > 3 }) else { return nil }
        return (prefix.isEmpty ? "" : String(prefix.unicodeScalars.dropLast(2)),
                lines.map { String($0.dropFirst(2)) })
    }
}
