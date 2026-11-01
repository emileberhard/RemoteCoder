#if RC_PERF_HARNESS
import Foundation
import Observation
import OSLog
import SwiftUI
import UIKit

@Observable @MainActor
final class HapticLatencyProbe {
    enum Kind: String { case press, semantic }
    enum Failure: Error { case unmounted, ineligible, invalidCount, contextChanged }

    static let shared = HapticLatencyProbe()
    var isPressed = false
    var isMounted = false
    @ObservationIgnored private let signposter = OSSignposter(subsystem: "RemoteCoder", category: "Haptics")

    func run(kind: Kind, count: Int) async throws -> [String: Any] {
        guard isMounted else { throw Failure.unmounted }
        guard (1...60).contains(count) else { throw Failure.invalidCount }
        let service = HapticService.shared
        let strength = service.strength
        let lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        let thermalState = ProcessInfo.processInfo.thermalState.rawValue
        guard service.canPlay else { throw Failure.ineligible }
        defer { isPressed = false }
        for index in 0..<count {
            try await Task.sleep(for: .milliseconds(250))
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            try Task.checkCancellation()
            guard isMounted, service.canPlay, service.strength == strength,
                  ProcessInfo.processInfo.isLowPowerModeEnabled == lowPowerMode,
                  ProcessInfo.processInfo.thermalState.rawValue == thermalState else { throw Failure.contextChanged }
            signposter.emitEvent("haptic-probe-input", "\(kind.rawValue, privacy: .public) index=\(index)")
            switch kind {
            case .press: isPressed = true
            case .semantic: service.play(.commit)
            }
            try await Task.sleep(for: .milliseconds(100))
            isPressed = false
        }
        try await Task.sleep(for: .milliseconds(250))
        return ["kind": kind.rawValue, "count": count, "strength": strength.rawValue,
                "input": "synthetic-downstream-probe",
                "signal": kind == .press ? "synthetic press-state rising edge" : "local semantic commit callback",
                "physicalTouch": false, "actuatorOnset": "unmeasured",
                "lowPowerMode": lowPowerMode, "thermalState": thermalState]
    }
}

struct HapticLatencyProbeSurface: View {
    private let probe = HapticLatencyProbe.shared

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .appPressFeedback(.buttonPress, isPressed: probe.isPressed)
            .onAppear { probe.isMounted = true }
            .onDisappear { probe.isMounted = false; probe.isPressed = false }
    }
}
#endif
