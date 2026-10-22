import Foundation

struct ModelVisibility: RawRepresentable, Equatable, Sendable {
    static let defaultValue = Self(rawValue: "")

    static func key(for provider: AgentProvider) -> String {
        "\(provider.rawValue).modelVisibility"
    }

    private var overrides: [String: Bool]

    init(rawValue: String) {
        overrides = Dictionary(rawValue.split(separator: "\n").compactMap { line in
            guard let flag = line.first, flag == "+" || flag == "-", line.count > 1 else { return nil }
            return (String(line.dropFirst()), flag == "+")
        }, uniquingKeysWith: { _, latest in latest })
    }

    var rawValue: String {
        overrides.sorted { $0.key < $1.key }.map { ($0.value ? "+" : "-") + $0.key }.joined(separator: "\n")
    }

    static func load(for provider: AgentProvider, defaults: UserDefaults) -> Self {
        Self(rawValue: defaults.string(forKey: key(for: provider)) ?? defaultValue.rawValue)
    }

    func isVisible(id: String, defaultVisibility: Bool = true) -> Bool {
        overrides[id] ?? defaultVisibility
    }

    mutating func setVisible(_ isVisible: Bool, id: String, defaultVisibility: Bool = true) {
        overrides[id] = isVisible == defaultVisibility ? nil : isVisible
    }
}
