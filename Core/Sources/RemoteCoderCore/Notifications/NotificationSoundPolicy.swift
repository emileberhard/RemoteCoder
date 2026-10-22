import Foundation

enum NotificationSoundPolicy {
    struct StoredSound {
        let filename: String
        let modifiedAt: Date?
        let byteCount: Int
    }

    static let maximumStoredSounds = 32
    static let maximumSoundBytes = 4 * 1024 * 1024
    static let maximumStoredBytes = 32 * 1024 * 1024

    static func acceptedFilename(_ filename: String) -> String? {
        guard !filename.isEmpty, !filename.hasPrefix("."), filename.utf8.count <= 128,
              filename.utf8.allSatisfy({ byte in
                  (65...90).contains(byte) || (97...122).contains(byte) ||
                  (48...57).contains(byte) || byte == 45 || byte == 95 || byte == 46
              }) else { return nil }
        guard ["aiff", "wav", "caf"].contains((filename as NSString).pathExtension.lowercased()) else { return nil }
        return filename
    }

    static func acceptsURL(_ url: URL, origins: [URL]) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil else { return false }
        return origins.contains { origin in
            origin.scheme?.lowercased() == "https" && origin.host?.lowercased() == host &&
                (origin.port ?? 443) == (url.port ?? 443) && origin.user == nil && origin.password == nil &&
                (origin.path.isEmpty || origin.path == "/") && origin.query == nil && origin.fragment == nil
        }
    }

    static func acceptsAudio(_ data: Data, filename: String) -> Bool {
        guard !data.isEmpty, data.count <= maximumSoundBytes else { return false }
        switch (filename as NSString).pathExtension.lowercased() {
        case "wav": return data.starts(with: Data("RIFF".utf8)) && data.dropFirst(8).starts(with: Data("WAVE".utf8))
        case "aiff": return data.starts(with: Data("FORM".utf8)) &&
            (data.dropFirst(8).starts(with: Data("AIFF".utf8)) || data.dropFirst(8).starts(with: Data("AIFC".utf8)))
        case "caf": return data.starts(with: Data("caff".utf8))
        default: return false
        }
    }

    static func filenamesToRemove(_ stored: [StoredSound], retaining filename: String) -> [String] {
        var count = stored.count
        var bytes = stored.reduce(0) { $0 + max(0, $1.byteCount) }
        var removed: [String] = []
        let oldest = stored.filter { $0.filename != filename }.sorted { left, right in
            switch (left.modifiedAt, right.modifiedAt) {
            case (nil, nil): left.filename < right.filename
            case (nil, _): true
            case (_, nil): false
            case (let a?, let b?): a == b ? left.filename < right.filename : a < b
            }
        }
        for sound in oldest {
            guard count > maximumStoredSounds || bytes > maximumStoredBytes else { break }
            removed.append(sound.filename)
            count -= 1
            bytes -= max(0, sound.byteCount)
        }
        return removed
    }
}
