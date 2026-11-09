import Foundation

/// Meaning, not a screen-specific vibration. This catalog owns every recipe.
enum HapticEvent: String, CaseIterable, Sendable {
    case buttonPress, iconPress, selection, toggleOn, toggleOff
    case lift, sliderGrab, sliderStep, sliderMinimum, sliderMaximum, sliderRelease, sliderSettle
    case commit, copied, disclosure, success, warning, error, refused, photoCapture

    var recipe: HapticRecipe {
        switch self {
        case .buttonPress: .impact(.light, intensity: 1)
        case .iconPress: .impact(.light, intensity: 0.95)
        case .selection: .selection
        case .sliderStep: .impact(.rigid, intensity: 0.5)
        case .toggleOn: .impact(.rigid, intensity: 0.85)
        case .toggleOff: .impact(.soft, intensity: 1)
        case .lift: .impact(.rigid, intensity: 1)
        case .sliderGrab: .impact(.soft, intensity: 0.75)
        case .sliderMinimum: .impact(.rigid, intensity: 0.7)
        case .sliderMaximum: .impact(.rigid, intensity: 0.95)
        case .sliderRelease: .impact(.soft, intensity: 0.8)
        case .sliderSettle: .impact(.soft, intensity: 0.9)
        case .commit: .impact(.medium, intensity: 0.8)
        case .copied: .impact(.soft, intensity: 1)
        case .disclosure: .impact(.soft, intensity: 0.85)
        case .success: .success
        case .warning: .warning
        case .error, .refused: .error
        case .photoCapture: .impact(.rigid, intensity: 0.9)
        }
    }

    var playsDuringCapture: Bool { self == .refused }

    var accent: HapticAccent? {
        switch self {
        case .lift: .lift
        case .sliderSettle: .seat
        default: nil
        }
    }
}

/// Ordinary and prepared gesture feedback share the same native recipe.
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
