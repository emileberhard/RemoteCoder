import OSLog

enum VoiceModeDiagnostics {
    private static let logger = Logger(subsystem: "RemoteCoder", category: "VoiceMode")

    nonisolated static func log(_ event: String) {
        logger.notice("\(event, privacy: .public)")
    }

}
