import Foundation
import MetricKit
import OSLog
import StateReporting
import Synchronization

/// Process-lifetime ownership of Apple's report streams and the StateReporting
/// domains. Apple reports are delayed/sampled; silence is not a health check.
actor AppPerformanceDiagnostics {
    static let shared = AppPerformanceDiagnostics()
    nonisolated static let historyLog = MetricManager.logHandle(category: "History")
    nonisolated static let transcriptLog = MetricManager.logHandle(category: "Transcript")
    nonisolated static let signposter = OSSignposter(logHandle: historyLog)
    nonisolated static let pointsOfInterest = OSSignposter(subsystem: "RemoteCoder", category: .pointsOfInterest)

    @ReportableMetadata
    fileprivate struct StableMetadata: Sendable {
        let provider: String
    }

    @ReportableMetadata
    fileprivate struct VolatileMetadata: Sendable {
        let operationID: String
    }

    private static let historyDomain = "emileberhard.RemoteCoder.history"
    private static let connectionDomain = "emileberhard.RemoteCoder.connection"
    private static let surfaceDomain = "emileberhard.RemoteCoder.surface"
    private static let turnDomain = "emileberhard.RemoteCoder.turn"
    private static let voiceDomain = "emileberhard.RemoteCoder.voice"
    private static let energyDomain = "emileberhard.RemoteCoder.energy"
    private let manager: MetricManager
    private let historyReporter: StateReporter<StableMetadata, VolatileMetadata>
    private let connectionReporter: StateReporter<StableMetadata, VolatileMetadata>
    private let surfaceReporter: StateReporter<StableMetadata, VolatileMetadata>
    private let turnReporter: StateReporter<StableMetadata, VolatileMetadata>
    private let voiceReporter: StateReporter<StableMetadata, VolatileMetadata>
    private let energyReporter: StateReporter<StableMetadata, VolatileMetadata>
    private let history = Mutex(HistoryOperations())
    private let logger = Logger(subsystem: "RemoteCoder", category: "PerformanceDiagnostics")
    private var metricsConsumer: Task<Void, Never>?
    private var diagnosticsConsumer: Task<Void, Never>?

    private init() {
        let domains = [
            Self.historyDomain, Self.connectionDomain, Self.surfaceDomain, Self.turnDomain, Self.voiceDomain,
            Self.energyDomain
        ]
        manager = MetricManager(enabledStateReportingDomains: Set(domains.map(StateReportingDomain.init(rawValue:))))
        func reporter(_ domain: String) -> StateReporter<StableMetadata, VolatileMetadata> {
            StateReporter.reporter(for: domain, stableMetadata: StableMetadata.self, volatileMetadata: VolatileMetadata.self)
        }
        historyReporter = reporter(Self.historyDomain)
        connectionReporter = reporter(Self.connectionDomain)
        surfaceReporter = reporter(Self.surfaceDomain)
        turnReporter = reporter(Self.turnDomain)
        voiceReporter = reporter(Self.voiceDomain)
        energyReporter = reporter(Self.energyDomain)
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
    nonisolated func beginHistory(_ activity: HistoryActivity, threadID: String) -> UUID {
        history.withLock { operations in
            let id = operations.begin(activity, provider: AgentProvider.provider(forThreadID: threadID))
            reportHistory(operations)
            return id
        }
    }

    nonisolated func finishHistory(operationID id: UUID) {
        history.withLock { operations in
            operations.finish(id)
            reportHistory(operations)
        }
    }

    nonisolated func clearHistory() {
        history.withLock { operations in
            operations.clear()
            reportHistory(operations)
        }
    }

    nonisolated func usageChanged(_ context: UsageContext, conservesEnergy: Bool) {
        let labels = UsageStateLabels(context, conservesEnergy: conservesEnergy)
        surfaceReporter.reportTransition(to: labels.surface)
        turnReporter.reportTransition(to: labels.turn)
        connectionReporter.reportTransition(to: labels.connection)
        voiceReporter.reportTransition(to: labels.voice)
        energyReporter.reportTransition(to: labels.energy)
        history.withLock { operations in
            operations.sceneChanged(active: context.scene == .active)
            reportHistory(operations)
        }
    }

    private nonisolated func reportHistory(_ operations: HistoryOperations) {
        guard let current = operations.current else { return historyReporter.reportTransition(to: nil) }
        historyReporter.reportTransition(
            to: current.activity.rawValue, stableMetadata: StableMetadata(provider: current.provider.rawValue),
            volatileMetadata: VolatileMetadata(operationID: current.id.uuidString)
        )
    }
}

/// Tap-to-visible-content timing for one chat open. MetricKit aggregates an
/// interval by name alone, so only opens that reach visible content end it;
/// every other outcome is a separate event.
struct HistoryOpenSignpost {
    enum Abandonment: String { case superseded, cancelled, empty, failed }

    private static let name: StaticString = "HistorySelectionToFirstContent"
    private var interval: OSSignpostID?

    mutating func begin() {
        abandon(.superseded)
        let id = OSSignpostID(log: AppPerformanceDiagnostics.historyLog)
        mxSignpost(.begin, log: AppPerformanceDiagnostics.historyLog, name: Self.name, signpostID: id)
        interval = id
    }

    mutating func contentVisible() {
        guard let interval else { return }
        mxSignpost(.end, log: AppPerformanceDiagnostics.historyLog, name: Self.name, signpostID: interval)
        self.interval = nil
    }

    mutating func abandon(_ reason: Abandonment) {
        guard interval != nil else { return }
        AppPerformanceDiagnostics.signposter.emitEvent("HistoryOpenAbandoned", "outcome=\(reason.rawValue, privacy: .public)")
        interval = nil
    }
}

struct TranscriptScrollSignpost {
    private static let name: StaticString = "TranscriptScroll"
    private let pointOfInterest: OSSignpostIntervalState
    private let animation: OSSignpostID

    init() {
        let signposter = AppPerformanceDiagnostics.pointsOfInterest
        pointOfInterest = signposter.beginInterval(Self.name, id: signposter.makeSignpostID())
        animation = OSSignpostID(log: AppPerformanceDiagnostics.transcriptLog)
        mxSignpostAnimationIntervalBegin(log: AppPerformanceDiagnostics.transcriptLog, name: Self.name, signpostID: animation)
    }

    func end() {
        mxSignpost(.end, log: AppPerformanceDiagnostics.transcriptLog, name: Self.name, signpostID: animation)
        AppPerformanceDiagnostics.pointsOfInterest.endInterval(Self.name, pointOfInterest)
    }
}
