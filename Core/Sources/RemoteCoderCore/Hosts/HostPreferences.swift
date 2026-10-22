import Foundation

enum HostPreferences {
    private static let workingDirectoryKey = "codexWorkingDirectory"
    private static let remoteHomePathKeyPrefix = "gateway.remoteHomePath"

    /// Per-host so one gateway's selected repository can never become another's
    /// working directory. `hostID: nil` addresses the pre-multi-host key and
    /// exists only for migration and previews.
    ///
    /// There is deliberately no shared fallback: the bundled `codexWorkdir` is
    /// one machine's repository path, and handing it to a newly added host would
    /// point that gateway at a directory it may not have. A host without a
    /// scoped value resolves its own remote home instead
    /// (`ChatTargetModel.adoptRemoteHomeAsWorkingDirectoryIfUnset`).
    static func workingDirectory(hostID: UUID?, defaults: UserDefaults = AppStorageScope.current.defaults) -> String? {
        trimmedNonEmpty(defaults.string(forKey: workingDirectoryKey(hostID: hostID)))
    }

    static func setWorkingDirectory(_ path: String, hostID: UUID?, defaults: UserDefaults = AppStorageScope.current.defaults) {
        defaults.set(path, forKey: workingDirectoryKey(hostID: hostID))
    }

    static func remoteHomePath(
        hostID: UUID?,
        defaults: UserDefaults = AppStorageScope.current.defaults
    ) -> String? {
        let value = defaults.string(forKey: remoteHomePathKey(hostID: hostID))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    static func setRemoteHomePath(
        _ path: String,
        hostID: UUID?,
        defaults: UserDefaults = AppStorageScope.current.defaults
    ) {
        defaults.set(path, forKey: remoteHomePathKey(hostID: hostID))
    }

    static func remoteHomePathKey(hostID: UUID?) -> String {
        "\(remoteHomePathKeyPrefix).\(hostID?.uuidString ?? "default")"
    }

    static func workingDirectoryKey(hostID: UUID?) -> String {
        guard let hostID else { return workingDirectoryKey }
        return "\(workingDirectoryKey).\(hostID.uuidString)"
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
