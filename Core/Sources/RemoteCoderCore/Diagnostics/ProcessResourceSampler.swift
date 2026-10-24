import Foundation

@MainActor
final class ProcessResourceSampler {
    static let interval: Duration = .seconds(30)
    static let minimumSpacing: Duration = .seconds(1)

    private let recorder: TelemetryBuffer
    private let read: () -> ProcessResources?
    private let clock = ContinuousClock()
    private var context: UsageContext?
    private var lastSample: ContinuousClock.Instant?
    private var unsampledChange = false
    private var periodic: Task<Void, Never>?
    private var deferred: Task<Void, Never>?

    init(recorder: TelemetryBuffer, read: @escaping () -> ProcessResources? = ProcessResources.current) {
        self.recorder = recorder
        self.read = read
    }

    func update(_ next: UsageContext) {
        guard next != context else { return }
        let previous = context
        context = next
        let reason: ProcessSample.Reason = switch (previous?.scene, next.scene) {
        case (nil, _): .launch
        case (_, .background): .background
        case (.background?, _): .foreground
        default: .context
        }
        if next.scene == .background {
            stop()
            sample(.background)
            return
        }
        if periodic == nil { startPeriodic() }
        if reason == .context, let lastSample {
            let wait = Self.minimumSpacing - lastSample.duration(to: clock.now)
            if wait > .zero {
                unsampledChange = true
                guard deferred == nil else { return }
                deferred = Task { [weak self] in
                    do { try await Task.sleep(for: wait) } catch { return }
                    self?.sample(.context)
                }
                return
            }
        }
        sample(reason)
    }

    func stop() {
        periodic?.cancel()
        periodic = nil
        deferred?.cancel()
        deferred = nil
    }

    private func startPeriodic() {
        periodic = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.interval, tolerance: .seconds(5)) } catch { return }
                self?.sample(.interval)
            }
        }
    }

    private func sample(_ reason: ProcessSample.Reason) {
        deferred?.cancel()
        deferred = nil
        guard let context else { return }
        let started = clock.now
        guard let resources = read() else {
            if reason != .interval { unsampledChange = true }
            return
        }
        let readTime = started.duration(to: clock.now)
        lastSample = clock.now
        let mixed = unsampledChange
        unsampledChange = false
        recorder.record(.sample(ProcessSample(
            reason: reason, resources: resources,
            readNanoseconds: UInt64(readTime.components.seconds) * 1_000_000_000
                + UInt64(readTime.components.attoseconds / 1_000_000_000),
            persistence: PersistenceMetrics.shared.snapshot(), mixed: mixed, context: context
        )))
    }
}
