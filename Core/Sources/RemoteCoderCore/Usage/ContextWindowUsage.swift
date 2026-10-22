import Foundation

struct ContextWindowUsage: Equatable, Sendable {
    let usedTokens: Int64
    let availableTokens: Int64

    init?(_ usage: CodexAppServerV2.ThreadTokenUsage) {
        guard let window = usage.modelContextWindow, window > 0 else { return nil }
        availableTokens = window
        // `last` is the newest request's context; `total` is what the thread has
        // spent over its life, which re-counts cache reads every request and so
        // passes the window after a few turns and pins the gauge at 100% full.
        usedTokens = min(window, max(0, usage.last.totalTokens))
    }

    var usedFraction: Double {
        Double(usedTokens) / Double(availableTokens)
    }

    var usedPercent: Int {
        Int((usedFraction * 100).rounded())
    }

    var tokensText: String {
        "\(Self.format(usedTokens)) of \(Self.format(availableTokens)) tokens"
    }

    private static func format(_ value: Int64) -> String {
        value.formatted(.number.notation(.compactName))
    }
}
