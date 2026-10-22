import Foundation
import MetricKit
import OSLog
import StateReporting

/// Process-lifetime ownership of Apple's report streams and the two foreground
/// state domains. Apple reports are delayed/sampled; silence is not a health check.
actor AppPerformanceDiagnostics {
    static let shared = AppPerformanceDiagnostics()
    nonisolated static let signposter = OSSignposter(logHandle: MetricManager.logHandle(category: "History"))
    nonisolated static let pointsOfInterest = OSSignposter(subsystem: "RemoteCoder", category: .pointsOfInterest)

    enum Provider: String, Sendable { case codex, claude }
    enum LoadingMode: String, Sendable { case cache, network, mixed }
    enum HistoryState: String, Sendable { case opening, paging }

    @ReportableMetadata
    fileprivate struct StableMetadata: Sendable {
        let provider: String
        let loadingMode: String
    }

    @ReportableMetadata
    fileprivate struct VolatileMetadata: Sendable {
        let operationID: String
    }

    private static let historyDomain = "emileberhard.RemoteCoder.history"
    private static let connectionDomain = "emileberhard.RemoteCoder.connection"
    private let manager: MetricManager
    private let historyReporter: StateReporter<StableMetadata, VolatileMetadata>
    private let connectionReporter: StateReporter<StableMetadata, VolatileMetadata>
    private let logger = Logger(subsystem: "RemoteCoder", category: "PerformanceDiagnostics")
    private var metricsConsumer: Task<Void, Never>?
    private var diagnosticsConsumer: Task<Void, Never>?
    private var operationID: UUID?

    private init() {
        manager = MetricManager(enabledStateReportingDomains: [
            StateReportingDomain(rawValue: Self.historyDomain),
            StateReportingDomain(rawValue: Self.connectionDomain)
        ])
        historyReporter = StateReporter.reporter(
            for: Self.historyDomain, stableMetadata: StableMetadata.self, volatileMetadata: VolatileMetadata.self
        )
        connectionReporter = StateReporter.reporter(
            for: Self.connectionDomain, stableMetadata: StableMetadata.self, volatileMetadata: VolatileMetadata.self
        )
    }

    func start() {
        guard metricsConsumer == nil else { return }
        let manager = manager
        metricsConsumer = Task {
            for await report in manager.metricReports {
                guard !Task.isCancelled else { return }
                await persist(report, kind: .metrics, timeRange: report.timeRange)
            }
        }
        diagnosticsConsumer = Task {
            for await report in manager.diagnosticReports {
                guard !Task.isCancelled else { return }
                // Encode the complete enum, including memory exceptions and any
                // future cases; a switch here would silently narrow coverage.
                await persist(report, kind: .diagnostic, timeRange: report.timeRange)
            }
        }
        logger.notice("MetricKit consumers started; metrics are delayed and diagnostics sampled, coverage is unknown until reports arrive")
    }

    private func persist<Report: Encodable & Sendable>(
        _ report: Report, kind: AppPerformanceReportKind, timeRange: DateInterval
    ) async {
        do {
            let stored = try await DiagnosticsOutbox.shared.enqueuePerformanceReport(
                report, kind: kind, timeRange: timeRange
            )
            logger.notice("MetricKit report received kind=\(kind.rawValue, privacy: .public) queued=\(stored, privacy: .public) coverageStart=\(timeRange.start, privacy: .public) coverageEnd=\(timeRange.end, privacy: .public)")
        } catch {
            logger.error("MetricKit report persistence failed kind=\(kind.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Only foreground operations enter this domain; prefetch uses request logs.
    func beginHistory(_ state: HistoryState, provider: Provider, mode: LoadingMode) -> UUID {
        let id = UUID()
        operationID = id
        historyReporter.reportTransition(
            to: state.rawValue, stableMetadata: StableMetadata(provider: provider.rawValue, loadingMode: mode.rawValue),
            volatileMetadata: VolatileMetadata(operationID: id.uuidString)
        )
        return id
    }

    func finishHistory(operationID id: UUID) {
        guard operationID == id else { return }
        clearHistory()
    }

    func clearHistory() {
        operationID = nil
        historyReporter.reportTransition(to: nil)
    }

    func connectionChanged(_ state: GatewayEventPump.Link, provider: Provider) {
        connectionReporter.reportTransition(
            to: state.rawValue,
            stableMetadata: StableMetadata(provider: provider.rawValue, loadingMode: "network")
        )
    }

    func clearConnection() {
        connectionReporter.reportTransition(to: nil)
    }
}

/// Tap-to-visible-content timing for one chat open. MetricKit aggregates an
/// interval by name alone, so only opens that reach visible content end it;
/// every other outcome is a separate event.
struct HistoryOpenSignpost {
    enum Abandonment: String { case superseded, cancelled, empty, failed }

    private static let name: StaticString = "HistorySelectionToFirstContent"
    private var interval: OSSignpostIntervalState?

    mutating func begin() {
        abandon(.superseded)
        let signposter = AppPerformanceDiagnostics.signposter
        interval = signposter.beginInterval(Self.name, id: signposter.makeSignpostID())
    }

    mutating func contentVisible() {
        guard let interval else { return }
        AppPerformanceDiagnostics.signposter.endInterval(Self.name, interval)
        self.interval = nil
    }

    mutating func abandon(_ reason: Abandonment) {
        guard interval != nil else { return }
        AppPerformanceDiagnostics.signposter.emitEvent("HistoryOpenAbandoned", "outcome=\(reason.rawValue, privacy: .public)")
        interval = nil
    }
}
