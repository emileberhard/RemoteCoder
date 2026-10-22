import Foundation

struct BenchPlan: Decodable, Sendable {
    enum Appearance: String, Decodable, Sendable { case light, dark }
    enum Fixture: String, Decodable, Sendable {
        case coldTable = "cold-table"
        case horizontalOverflow = "horizontal-overflow"
    }
    struct Display: Decodable, Sendable {
        let width: Double
        let height: Double
        let scale: Double
        let maximumFramesPerSecond: Int
    }
    enum Interaction: String, Decodable, Sendable {
        case tracking
        case readingGrowth = "reading-growth"
        case narrowZoom = "narrow-zoom"
        case tableSelection = "table-selection"
        case cancelledMomentum = "cancelled-momentum"
        case composerTyping = "composer-typing"
        case composerEditing = "composer-editing"
        case horizontalDisplacement = "horizontal-displacement"
    }
    enum Capture: String, Decodable, Sendable {
        case none, frames, video
    }

    enum Delivery: String, Decodable, Sendable {
        case app, send, queue
    }

    let label: String
    let host: UUID
    let thread: String
    let account: UUID?
    let fixture: Fixture?
    let appearance: Appearance?
    let width: Double
    let height: Double
    let expectedDisplay: Display
    let pointerX: Double
    let pointerY: Double
    let settleSeconds: Double
    let tailSeconds: Double
    let warmup: [BenchGesture]
    let gestures: [BenchGesture]
    let stream: BenchStreamPlan?
    let capture: Capture
    let delivery: Delivery
    let quit: Bool
    let checkInteraction: Interaction?
    let switches: Bool?
    let persistence: Bool?

    static func validateLaunch(_ arguments: [String]) throws {
        for (key, required) in [("-ApplePersistenceIgnoreState", "YES"), ("-NSQuitAlwaysKeepsWindows", "NO")] {
            let occurrences = arguments.indices.filter { arguments[$0] == key }
            guard occurrences.count == 1, let index = occurrences.first, arguments.indices.contains(index + 1),
                  arguments[index + 1] == required else {
                throw ValidationFailure("benchmark launches require \(key) \(required)")
            }
        }
    }

    func validate() throws {
        guard !label.isEmpty, label != ".", label != "..", !label.contains("/"), !label.contains("\\"), label.rangeOfCharacter(from: .controlCharacters) == nil,
              !thread.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationFailure("benchmark label must be one path component and thread must be nonempty")
        }
        guard width.isFinite, height.isFinite, (1...16_384).contains(width), (1...16_384).contains(height),
              pointerX.isFinite, pointerY.isFinite, (0...1).contains(pointerX), (0...1).contains(pointerY),
              settleSeconds.isFinite, tailSeconds.isFinite,
              (0...120).contains(settleSeconds), (0...120).contains(tailSeconds) else {
            throw ValidationFailure("benchmark dimensions, pointer fractions or durations are invalid")
        }
        guard expectedDisplay.width.isFinite, expectedDisplay.height.isFinite, expectedDisplay.scale.isFinite,
              expectedDisplay.width > 0, expectedDisplay.height > 0, expectedDisplay.scale > 0,
              expectedDisplay.maximumFramesPerSecond > 0 else {
            throw ValidationFailure("benchmark display dimensions, scale and refresh rate must be positive")
        }
        if switches == true {
            guard stream == nil, checkInteraction == nil, warmup.isEmpty, gestures.isEmpty, account == nil else {
                throw ValidationFailure("switch fixtures require the default account and no stream, gestures or interaction check")
            }
        }
        if persistence == true {
            guard switches != true, stream == nil, checkInteraction == nil, warmup.isEmpty, gestures.isEmpty, account == nil else {
                throw ValidationFailure("persistence fixtures require the default account and no stream, gestures or interaction check")
            }
        }
        let allGestures = warmup + gestures
        guard allGestures.count <= 64, allGestures.allSatisfy({
            $0.velocity.isFinite && abs($0.velocity) <= 1_000_000 && $0.dragSeconds.isFinite && $0.pauseSeconds.isFinite
                && (0...120).contains($0.dragSeconds) && (0...120).contains($0.pauseSeconds)
        }) else { throw ValidationFailure("benchmark gestures must be finite, nonnegative in duration and bounded to 64") }
        if let interaction = checkInteraction, [.cancelledMomentum, .composerTyping, .composerEditing, .horizontalDisplacement].contains(interaction), stream != nil {
            throw ValidationFailure("\(interaction.rawValue) does not support streaming")
        }
        guard fixture != .coldTable || (stream == nil && checkInteraction == nil && !gestures.isEmpty) else {
            throw ValidationFailure("cold-table requires scrolling without streaming or an interaction check")
        }
        if fixture == .horizontalOverflow || checkInteraction == .horizontalDisplacement {
            guard fixture == .horizontalOverflow, checkInteraction == .horizontalDisplacement,
                  stream == nil, warmup.isEmpty, gestures.isEmpty, delivery == .app, height >= 500 else {
                throw ValidationFailure("horizontal-overflow requires horizontal-displacement, app delivery, a 500-point window and no stream or gestures")
            }
        }
        switch checkInteraction {
        case .tracking:
            guard stream != nil else { throw ValidationFailure("tracking requires streaming") }
        case .narrowZoom, .readingGrowth:
            guard stream?.kind == .paragraph, (stream?.seconds ?? 0) >= 8 else {
                throw ValidationFailure("reading-growth and narrow-zoom require a paragraph stream of at least eight seconds")
            }
        case .tableSelection:
            guard let stream, stream.kind == .wideTable || stream.kind == .wideTableThenProse, stream.seconds >= 8 else {
                throw ValidationFailure("table-selection requires a wide-table stream of at least eight seconds")
            }
        case .cancelledMomentum, .composerTyping, .composerEditing, .horizontalDisplacement, nil: break
        }
    }

    private struct ValidationFailure: LocalizedError {
        let errorDescription: String?
        init(_ description: String) { errorDescription = description }
    }
}

/// One trackpad gesture: fingers move at `velocity` points per second for
/// `dragSeconds` (positive scrolls toward older content), then lift, optionally
/// coasting with system-like momentum, then rest for `pauseSeconds`.
struct BenchGesture: Decodable, Sendable {
    let velocity: Double
    let dragSeconds: Double
    let eased: Bool
    let momentum: Bool
    let pauseSeconds: Double
}
