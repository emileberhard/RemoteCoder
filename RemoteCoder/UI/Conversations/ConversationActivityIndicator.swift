import SwiftUI

struct ConversationActivityIndicator: View {
    enum Style {
        case labeled
        case compact
    }

    let state: CodexGatewayDaemon.ActivityState
    let style: Style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appEnergyPolicy) private var energyPolicy
    @Environment(\.visualsVisible) private var visualsVisible

    var body: some View {
        HStack(spacing: 5) {
            WorkingSymbol(systemName: symbol, tint: .primary, isAnimating: state == .working && animates)
                .scaledFont(.system(size: style == .labeled ? 13 : 11, weight: .bold))
            if style == .labeled {
                Text(title)
                    .scaledFont(.caption2.weight(.semibold))
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, style == .labeled ? 8 : 6)
        .padding(.vertical, style == .labeled ? 4 : 2)
        .background(.primary.opacity(0.07), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    private var animates: Bool {
        energyPolicy.animatesDecorations(sceneActive: scenePhase == .active, visible: visualsVisible, reduceMotion: reduceMotion)
    }

    private var title: String {
        switch state {
        case .working: "Working"
        case .waiting: "Needs input"
        case .idle: "Ready"
        case .unknown: "Checking status"
        }
    }

    private var symbol: String {
        switch state {
        case .working: "ellipsis"
        case .waiting: "hand.raised"
        case .idle: "checkmark"
        case .unknown: "questionmark.circle"
        }
    }
}
