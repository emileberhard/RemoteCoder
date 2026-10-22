import Foundation

struct HTMLVisualTheme: Codable, Hashable, Sendable {
    let fontSize: Double
    let text: String
    let secondaryText: String
    let background: String
    let surface: String
    let accent: String
    let isDark: Bool
}

struct HTMLVisualLayoutKey: Codable, Hashable, Sendable {
    let rendererVersion: Int
    let digest: String
    let width: Int
    let theme: HTMLVisualTheme

    init(digest: String, width: Int, theme: HTMLVisualTheme) {
        rendererVersion = 1
        self.digest = digest
        self.width = width
        self.theme = theme
    }
}

enum HTMLVisualInlineHeight {
    static let maximumPoints = 6_000.0

    static func limit(interfaceScale: Double) -> Double {
        maximumPoints * interfaceScale
    }
}
