import SwiftUI

enum AppThemeID: String, CaseIterable, Identifiable {
    case caribbeanSunset
    case midnightOcean
    case forestDusk
    case orchidNight
    case paperLight
    case night

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .caribbeanSunset:
            return "Caribbean Sunset"
        case .midnightOcean:
            return "Midnight Ocean"
        case .forestDusk:
            return "Forest Dusk"
        case .orchidNight:
            return "Orchid Night"
        case .paperLight:
            return "Paper"
        case .night:
            return "Neutral"
        }
    }
}

struct AppTheme: Identifiable {
    struct Colors {
        let accentTint: Color
    }

    let id: AppThemeID
    let colors: Colors

    var displayName: String { id.displayName }
}

extension AppTheme {
    func surfaceTint(for colorScheme: ColorScheme) -> Color {
        let isLight = colorScheme == .light
        let accent: Color = switch (id, colorScheme) {
        case (.night, .light): .black
        case (.paperLight, .dark): .white
        default: colors.accentTint
        }
        return accent.mix(with: isLight ? .white : .black, by: isLight ? 0.60 : 0.70)
            .opacity(isLight ? 0.66 : 0.70)
    }

    var drawerHostForeground: Color {
        Color.secondary.mix(with: colors.accentTint, by: 0.50)
    }

    func filledAccentForeground(for colorScheme: ColorScheme) -> Color {
        switch id {
        case .paperLight:
            return .white
        case .night:
            return .black.opacity(colorScheme == .light ? 0.84 : 0.90)
        case .caribbeanSunset, .midnightOcean, .forestDusk, .orchidNight:
            return colorScheme == .light ? .black.opacity(0.84) : .white
        }
    }
}

extension AppTheme {
    static func theme(for id: AppThemeID) -> AppTheme {
        switch id {
        case .caribbeanSunset:
            return .caribbeanSunset
        case .midnightOcean:
            return .midnightOcean
        case .forestDusk:
            return .forestDusk
        case .orchidNight:
            return .orchidNight
        case .paperLight:
            return .paperLight
        case .night:
            return .night
        }
    }

    // MARK: - Theme Presets

    static let caribbeanSunset = AppTheme(
        id: .caribbeanSunset,
        colors: .init(
            accentTint: Color(red: 0.86, green: 0.35, blue: 0.18) // bright blood orange
        )
    )

    static let midnightOcean = AppTheme(
        id: .midnightOcean,
        colors: .init(
            accentTint: Color(red: 0.20, green: 0.80, blue: 0.90) // aqua
        )
    )

    static let forestDusk = AppTheme(
        id: .forestDusk,
        colors: .init(
            accentTint: Color(red: 0.30, green: 0.90, blue: 0.55) // bright mint
        )
    )

    static let orchidNight = AppTheme(
        id: .orchidNight,
        colors: .init(
            accentTint: Color(red: 0.95, green: 0.35, blue: 0.78) // bright pink
        )
    )

    static let paperLight = AppTheme(
        id: .paperLight,
        colors: .init(
            accentTint: Color(red: 0.18, green: 0.20, blue: 0.24) // graphite
        )
    )

    static let night = AppTheme(
        id: .night,
        colors: .init(
            accentTint: Color(red: 0.92, green: 0.93, blue: 0.95) // almost-white
        )
    )
}

extension Color {
    static var appSubtleFill: Color { .primary.opacity(0.065) }
    static var appSelectedFill: Color { .primary.opacity(0.13) }
    static var appHairline: Color { .primary.opacity(0.12) }
}
