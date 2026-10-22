import Foundation

enum WorkingDirectoryPathFormatter {
    static func displayPath(_ path: String, remoteHomePath: String?) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "(unknown)" }
        return normalizePath(trimmed, remoteHomePath: remoteHomePath)
    }

    static func condensedPath(_ path: String, remoteHomePath: String?) -> String {
        let normalized = displayPath(path, remoteHomePath: remoteHomePath)
        if normalized == "~" { return "~" }

        if normalized.hasPrefix("~/") {
            let remainder = normalized.dropFirst(2)
            guard !remainder.isEmpty else { return "~" }
            let components = remainder.split(separator: "/")
            let tail = components.suffix(2).joined(separator: "/")
            return "~/" + tail
        }

        let components = normalized.split(separator: "/")
        guard components.count > 2 else { return normalized }
        return components.suffix(2).joined(separator: "/")
    }

    private static func normalizePath(_ raw: String, remoteHomePath: String?) -> String {
        let collapsed = pathByCollapsingDuplicateSlashes(raw)
        guard let remoteHomePath else { return collapsed }

        let home = pathByCollapsingDuplicateSlashes(remoteHomePath)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedHome = home.isEmpty ? "/" : "/" + home

        if collapsed == normalizedHome { return "~" }

        let homePrefix = normalizedHome == "/" ? "/" : normalizedHome + "/"
        if collapsed.hasPrefix(homePrefix) {
            var suffix = collapsed.dropFirst(homePrefix.count)
            while suffix.first == "/" { suffix = suffix.dropFirst() }
            return suffix.isEmpty ? "~" : "~/" + suffix
        }

        return collapsed
    }

    private static func pathByCollapsingDuplicateSlashes(_ path: String) -> String {
        var collapsed = path
        while collapsed.contains("//") {
            collapsed = collapsed.replacingOccurrences(of: "//", with: "/")
        }
        return collapsed
    }
}
