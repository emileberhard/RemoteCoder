import Foundation

enum HapticStrength: String, CaseIterable, Identifiable, Sendable {
    case standard, strong
    var id: Self { self }
    var title: String { self == .strong ? "Strong" : "Standard" }
}

/// Meaning, not a screen-specific vibration. This catalog owns every recipe.
enum HapticEvent: String, CaseIterable, Sendable {
    case buttonPress, iconPress, selection, toggleOn, toggleOff
    case lift, sliderGrab, sliderStep, sliderMinimum, sliderMaximum, sliderRelease, sliderSettle
    case commit, copied, disclosure, success, warning, error, refused, photoCapture

    func recipe(for strength: HapticStrength) -> HapticRecipe {
        let strong = strength == .strong
        switch self {
        case .buttonPress: return .impact(.light, intensity: strong ? 1 : 0.8)
        case .iconPress: return .impact(.light, intensity: strong ? 0.95 : 0.65)
        case .selection: return .selection
        case .sliderStep: return strong ? .impact(.rigid, intensity: 0.5) : .selection
        case .toggleOn: return .impact(.rigid, intensity: strong ? 0.85 : 0.65)
        case .toggleOff: return .impact(.soft, intensity: strong ? 1 : 0.75)
        case .lift: return .impact(.rigid, intensity: strong ? 1 : 0.8)
        case .sliderGrab: return .impact(.soft, intensity: strong ? 0.75 : 0.55)
        case .sliderMinimum: return .impact(.rigid, intensity: strong ? 0.7 : 0.5)
        case .sliderMaximum: return .impact(.rigid, intensity: strong ? 0.95 : 0.7)
        case .sliderRelease: return .impact(.soft, intensity: strong ? 0.8 : 0.6)
        case .sliderSettle: return .impact(.soft, intensity: strong ? 0.9 : 0.65)
        case .commit: return strong ? .impact(.medium, intensity: 0.8) : .impact(.light, intensity: 0.75)
        case .copied: return .impact(.soft, intensity: strong ? 1 : 0.8)
        case .disclosure: return .impact(.soft, intensity: strong ? 0.85 : 0.6)
        case .success: return .success
        case .warning: return .warning
        case .error, .refused: return .error
        case .photoCapture: return .impact(.rigid, intensity: strong ? 0.9 : 0.7)
        }
    }

    var playsDuringCapture: Bool { self == .refused }

    func accent(for strength: HapticStrength) -> HapticAccent? {
        guard strength == .strong else { return nil }
        switch self {
        case .lift: return .lift
        case .sliderSettle: return .seat
        default: return nil
        }
    }
}

/// SwiftUI and the prepared gesture player interpret the same recipe.
enum HapticRecipe: Equatable {
    enum Impact: Hashable {
        case light, medium, rigid, soft
    }

    case impact(Impact, intensity: Double)
    case selection, success, warning, error
}

/// Two short, haptics-only accents. Native impacts remain the cold/error fallback.
enum HapticAccent: CaseIterable, Hashable {
    case lift, seat
}

/// Remote occurrences are host-qualified; repeated explicit local actions have no key.
struct HapticOccurrence: Hashable {
    enum Kind: Hashable { case turn, question }
    let hostID: UUID
    let kind: Kind
    let id: String
}

struct HapticPulse: Equatable {
    let id = UUID()
    let event: HapticEvent
    let strength: HapticStrength
    let requestedAt: ContinuousClock.Instant

    func isFresh(at now: ContinuousClock.Instant) -> Bool {
        requestedAt.duration(to: now) < .milliseconds(200)
    }
}

/// Status is preserved all the way to presentation; an unknown result is not success.
enum TaskOutcome: String, Equatable {
    case completed, interrupted, failed, unknown

    init(status: String) {
        self = Self(rawValue: status) ?? .unknown
    }

    var haptic: HapticEvent? {
        switch self {
        case .completed: .success
        case .failed: .error
        case .interrupted, .unknown: nil
        }
    }
}
