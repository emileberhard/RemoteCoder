import OSLog

enum VoiceModeDiagnostics {
    private static let logger = AppLogger(category: "VoiceMode")

    nonisolated static func log(_ event: String) {
        logger.notice("\(event)")
    }

}
