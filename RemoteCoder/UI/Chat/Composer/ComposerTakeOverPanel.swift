import SwiftUI

struct ComposerTakeOverPanel: View {
    let activity: CodexGatewayDaemon.ActivityState?
    let isTakingOver: Bool
    let takeOver: () -> Void

    private static let cornerRadius: CGFloat = 20

    @State private var isConfirming = false
    @State private var lockAttention = false
    @InterfaceScaledMetric(relativeTo: .title3) private var lockDiameter: CGFloat = 52
    @Environment(AppThemeStore.self) private var themeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appEnergyPolicy) private var energyPolicy
    @Environment(\.visualsVisible) private var visualsVisible

    var body: some View {
        Button {
            isConfirming = true
        } label: {
            HStack(spacing: 12) {
                status
                Spacer(minLength: 0)
                lock
            }
            .padding(.leading, 18)
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity, minHeight: 84)
            .background(pane)
            .contentShape(.rect(cornerRadius: Self.cornerRadius))
            .environment(\.colorScheme, .dark)
        }
        .buttonStyle(ResponsiveButtonStyle(feedback: .buttonPress, pressedScale: 0.98, pressedOpacity: 0.9))
        .disabled(isTakingOver)
        .animation(animates ? .smooth : nil, value: activity)
        .animation(animates ? .smooth : nil, value: isTakingOver)
        .task {
            try? await Task.sleep(for: .milliseconds(350))
            if animates { lockAttention.toggle() }
        }
        .confirmationDialog("Take over this conversation?", isPresented: $isConfirming, titleVisibility: .visible) {
            Button("Take Over", role: .destructive, action: takeOver)
        } message: {
            Text(activity == .working || activity == .waiting ? "Its current turn in the other client will stop." : "It will be closed in the other client.")
        }
        .accessibilityLabel(title)
        .accessibilityHint("Take over this conversation here")
        .accessibilityIdentifier("composer-take-over")
    }

    private var status: some View {
        HStack(spacing: 12) {
            WorkingSymbol(systemName: activity == .waiting ? "hand.raised.fill" : "ellipsis",
                tint: themeStore.theme.colors.accentTint, isAnimating: animates && activity == .working)
                .scaledFont(.title2.weight(.bold))
                .contentTransition(animates ? .symbolEffect(.replace) : .identity)
                .frame(minWidth: 32)
            Text(title)
                .scaledFont(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .contentTransition(.opacity)
        }
    }

    private var title: String {
        if isTakingOver { return "Taking over…" }
        switch activity {
        case .working: return "Working in another client"
        case .waiting: return "Needs input in another client"
        case .idle, .unknown, nil: return "Open in another client"
        }
    }

    private var lock: some View {
        WorkingSymbol(systemName: isTakingOver ? "lock.open.fill" : "lock.fill",
                      tint: themeStore.theme.filledAccentForeground(for: .dark),
                      isAnimating: isTakingOver && animates)
            .scaledFont(.title3.weight(.semibold))
            .foregroundStyle(themeStore.theme.filledAccentForeground(for: .dark))
            .contentTransition(animates ? .symbolEffect(.replace) : .identity)
            .symbolEffect(.wiggle.left, value: lockAttention)
            .frame(width: lockDiameter, height: lockDiameter)
            .background(themeStore.theme.colors.accentTint, in: .circle)
    }

    private var pane: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius)
        return shape
            .fill(.black.opacity(colorScheme == .dark ? 0.55 : 0.88))
            .overlay { shape.strokeBorder(.white.opacity(0.08), lineWidth: 0.6) }
    }

    private var animates: Bool {
        energyPolicy.animatesDecorations(sceneActive: scenePhase == .active, visible: visualsVisible, reduceMotion: reduceMotion)
    }
}
