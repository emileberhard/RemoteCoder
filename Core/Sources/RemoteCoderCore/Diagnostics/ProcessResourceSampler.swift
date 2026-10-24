import Foundation

protocol TelemetryRecording: Actor {
    func record(_ record: TelemetryRecord)
}

actor ProcessResourceSampler {
    static let interval: Duration = .seconds(30)
    static let minimumSpacing: Duration = .seconds(1)

    private let recorder: any TelemetryRecording
    private let read: @Sendable () -> ProcessResources?
    private let clock = ContinuousClock()
    private var context: UsageContext?
    private var lastSample: ContinuousClock.Instant?
    private var periodic: Task<Void, Never>?
    private var deferred: Task<Void, Never>?

    init(recorder: any TelemetryRecording, read: @escaping @Sendable () -> ProcessResources? = ProcessResources.current) {
        self.recorder = recorder
        self.read = read
    }

    func update(_ next: UsageContext) async {
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
            await sample(.background)
            return
        }
        if periodic == nil { startPeriodic() }
        if reason == .context, let lastSample {
            let wait = Self.minimumSpacing - lastSample.duration(to: clock.now)
            if wait > .zero {
                guard deferred == nil else { return }
                deferred = Task { [weak self] in
                    do { try await Task.sleep(for: wait) } catch { return }
                    await self?.takeDeferredSample()
                }
                return
            }
        }
        deferred?.cancel()
        deferred = nil
        await sample(reason)
    }

    private func takeDeferredSample() async {
        deferred = nil
        await sample(.deferredContext)
    }

    private func startPeriodic() {
        periodic = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.interval, tolerance: .seconds(5)) } catch { return }
                await self?.sample(.interval)
            }
        }
    }

    private func sample(_ reason: ProcessSample.Reason) async {
        guard let context else { return }
        let started = clock.now
        guard let resources = read() else { return }
        let readTime = started.duration(to: clock.now)
        lastSample = clock.now
        let persistence = PersistenceMetrics.shared.snapshot()
        await recorder.record(.sample(ProcessSample(
            reason: reason, resources: resources,
            readNanoseconds: UInt64(readTime.components.seconds) * 1_000_000_000
                + UInt64(readTime.components.attoseconds / 1_000_000_000),
            persistence: persistence, context: context
        )))
    }

    func stop() {
        periodic?.cancel()
        periodic = nil
        deferred?.cancel()
        deferred = nil
    }
}
