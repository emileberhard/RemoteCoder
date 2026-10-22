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
    /// Glass prominence; the tint and stroke for each role live in `AppGlass.swift`.
    enum GlassRole {
        case standard
        case selected
    }

    struct Colors {
        let accentTint: Color
        let highlight: Color
        let highlightSecondary: Color
        let attention: Color
        let danger: Color
    }

    let id: AppThemeID
    let colors: Colors

    var displayName: String { id.displayName }
}

extension AppTheme {
    func sheetBackgroundTint(for colorScheme: ColorScheme) -> Color {
        colors.accentTint.opacity(colorScheme == .light ? 0.06 : 0.10)
    }

    func sheetListRowBackground(for colorScheme: ColorScheme) -> Color {
        colors.accentTint.opacity(colorScheme == .light ? 0.08 : 0.12)
    }

    var userBubbleBase: Color {
        Color.appSecondarySystemBackground
    }

    func userBubbleTint(for colorScheme: ColorScheme) -> Color {
        colors.accentTint.opacity(colorScheme == .light ? 0.15 : 0.22)
    }

    func selectedOptionTint(for colorScheme: ColorScheme) -> Color {
        colors.accentTint.opacity(colorScheme == .light ? 0.26 : 0.36)
    }

    func messageAttachmentTint(for colorScheme: ColorScheme) -> Color {
        colors.accentTint.opacity(colorScheme == .light ? 0.075 : 0.11)
    }

    func tintedSurfaceBase(for colorScheme: ColorScheme) -> Color {
        colorScheme == .light ? Color.appSecondarySystemBackground : Color.appTertiarySystemBackground
    }

    func tintedSurfaceStroke(for colorScheme: ColorScheme) -> Color {
        colors.accentTint.opacity(colorScheme == .light ? 0.18 : 0.26)
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
            accentTint: Color(red: 0.86, green: 0.35, blue: 0.18), // bright blood orange
            highlight: Color(red: 1.0, green: 0.60, blue: 0.25), // amber
            highlightSecondary: Color(red: 0.98, green: 0.50, blue: 0.45), // coral
            attention: Color(red: 0.88, green: 0.38, blue: 0.15), // burnt orange
            danger: Color(red: 0.80, green: 0.12, blue: 0.18) // blood red
        )
    )

    static let midnightOcean = AppTheme(
        id: .midnightOcean,
        colors: .init(
            accentTint: Color(red: 0.20, green: 0.80, blue: 0.90), // aqua
            highlight: Color(red: 0.70, green: 0.96, blue: 0.98), // pale cyan
            highlightSecondary: Color(red: 0.45, green: 0.72, blue: 0.98), // cornflower
            attention: Color(red: 0.24, green: 0.56, blue: 0.96), // electric blue
            danger: Color(red: 0.90, green: 0.18, blue: 0.25) // red
        )
    )

    static let forestDusk = AppTheme(
        id: .forestDusk,
        colors: .init(
            accentTint: Color(red: 0.30, green: 0.90, blue: 0.55), // bright mint
            highlight: Color(red: 0.68, green: 0.96, blue: 0.72), // light mint
            highlightSecondary: Color(red: 0.30, green: 0.82, blue: 0.62), // seafoam
            attention: Color(red: 0.50, green: 0.88, blue: 0.30), // chartreuse
            danger: Color(red: 0.90, green: 0.18, blue: 0.25) // red
        )
    )

    static let orchidNight = AppTheme(
        id: .orchidNight,
        colors: .init(
            accentTint: Color(red: 0.95, green: 0.35, blue: 0.78), // bright pink
            highlight: Color(red: 0.90, green: 0.80, blue: 0.98), // lavender
            highlightSecondary: Color(red: 0.72, green: 0.52, blue: 0.96), // violet
            attention: Color(red: 0.98, green: 0.45, blue: 0.82), // hot pink
            danger: Color(red: 0.90, green: 0.18, blue: 0.25) // red
        )
    )

    static let paperLight = AppTheme(
        id: .paperLight,
        colors: .init(
            accentTint: Color(red: 0.18, green: 0.20, blue: 0.24), // graphite
            highlight: Color(red: 0.22, green: 0.24, blue: 0.28), // dark gray
            highlightSecondary: Color(red: 0.34, green: 0.36, blue: 0.42), // slate
            attention: Color(red: 0.18, green: 0.20, blue: 0.24), // graphite
            danger: Color(red: 0.78, green: 0.16, blue: 0.22) // red
        )
    )

    static let night = AppTheme(
        id: .night,
        colors: .init(
            accentTint: Color(red: 0.92, green: 0.93, blue: 0.95), // almost-white
            highlight: Color(red: 0.75, green: 0.78, blue: 0.86), // cool silver
            highlightSecondary: Color(red: 0.60, green: 0.64, blue: 0.74), // muted steel
            attention: Color(red: 0.80, green: 0.82, blue: 0.88), // neutral
            danger: Color(red: 0.90, green: 0.18, blue: 0.25) // red
        )
    )
}
