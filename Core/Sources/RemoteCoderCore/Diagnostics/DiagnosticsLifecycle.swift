import Foundation

protocol DiagnosticsExporting: Actor {
    func setDestination(_ destination: DiagnosticsDestination?) async
    func startPumping()
    func stopPumping()
    func drain(reason: String) async
}

@MainActor
final class DiagnosticsLifecycle {
    private struct Request {
        let generation: UInt64
        let destination: DiagnosticsDestination?
        let phase: Phase
    }

    enum Phase {
        case foreground(String)
        case background
        case stopped
    }

    private let exporter: any DiagnosticsExporting
    private var generation: UInt64 = 0
    private var needsDrain = false
    private var phase: Phase = .stopped
    private var pending: Request?
    private var worker: Task<Void, Never>?

    init(exporter: any DiagnosticsExporting) {
        self.exporter = exporter
    }

    func update(destination: DiagnosticsDestination?, phase: Phase) {
        self.phase = phase
        switch phase {
        case .foreground, .background: needsDrain = true
        case .stopped: needsDrain = false
        }
        enqueue(destination: destination)
    }

    func setDestination(_ destination: DiagnosticsDestination?) {
        enqueue(destination: destination)
    }

    private func enqueue(destination: DiagnosticsDestination?) {
        generation &+= 1
        pending = Request(generation: generation, destination: destination, phase: phase)
        guard worker == nil else { return }
        worker = Task { await applyPending() }
    }

    func flush() async {
        await worker?.value
    }

    private func applyPending() async {
        defer { worker = nil }
        while let request = pending {
            pending = nil
            await exporter.setDestination(request.destination)
            guard request.generation == generation else { continue }
            switch request.phase {
            case .foreground(let reason):
                await exporter.startPumping()
                guard request.generation == generation else { continue }
                if needsDrain {
                    needsDrain = false
                    await exporter.drain(reason: reason)
                }
            case .background:
                if needsDrain {
                    needsDrain = false
                    await exporter.drain(reason: "background")
                }
                guard request.generation == generation else { continue }
                await exporter.stopPumping()
            case .stopped:
                await exporter.stopPumping()
            }
        }
    }
}
