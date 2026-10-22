import SwiftUI
import WebKit

struct HTMLVisualPreparationHost: View {
    @Environment(\.htmlVisualSource) private var source
    @Environment(\.htmlVisualTheme) private var theme
    @Environment(\.appEnergyPolicy) private var energyPolicy
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.visualsVisible) private var visible
    @State private var id = UUID()
    @State private var claimed: HTMLVisualPreparation?
    #if DEBUG
    private static let revealsSurface = ProcessInfo.processInfo.arguments.contains("-html-visual-fixture-show-preparation")
    #else
    private static let revealsSurface = false
    #endif

    private struct Configuration: Equatable {
        let preparation: ObjectIdentifier?
        let claimable: Bool
        let theme: HTMLVisualTheme?
        let displayScale: Double
        let inlineHeightLimit: Double
        let active: Bool
        let energyPolicy: AppEnergyPolicy
    }

    private var preparation: HTMLVisualPreparation? { source?.preparation }

    private var configuration: Configuration {
        Configuration(preparation: preparation.map(ObjectIdentifier.init),
            claimable: preparation.map { $0.surface.host == nil || $0.surface.host == id } ?? false,
            theme: theme, displayScale: displayScale,
            inlineHeightLimit: HTMLVisualInlineHeight.limit(interfaceScale: interfaceScale),
            active: visible && scenePhase != .background, energyPolicy: energyPolicy)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let preparation, preparation.surface.host == id, let instance = preparation.surface.instance,
               let page = instance.page, let key = instance.key {
                WebView(page)
                    .webViewContentBackground(.hidden)
                    .webViewBackForwardNavigationGestures(.disabled)
                    .webViewMagnificationGestures(.disabled)
                    .webViewLinkPreviews(.disabled)
                    .frame(width: CGFloat(key.width), height: max(1, min(instance.height, instance.inlineHeightLimit)),
                           alignment: .topLeading)
                    .opacity(Self.revealsSurface ? 0.5 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 0, height: 0, alignment: .topLeading)
        .onChange(of: configuration, initial: true) { _, configuration in apply(configuration) }
        .onDisappear { release() }
    }

    private func apply(_ configuration: Configuration) {
        if claimed !== preparation { release() }
        guard let preparation, preparation.surface.claim(id) else { return }
        claimed = preparation
        source?.renderer.setEnergyPolicy(configuration.energyPolicy)
        preparation.updateLayoutContext {
            $0.theme = configuration.theme
            $0.displayScale = configuration.displayScale
            $0.inlineHeightLimit = configuration.inlineHeightLimit
        }
        preparation.setActive(configuration.active, conservesEnergy: configuration.energyPolicy.conservesEnergy)
    }

    private func release() {
        guard let claimed else { return }
        claimed.setActive(false, conservesEnergy: false)
        claimed.surface.release(id)
        self.claimed = nil
    }
}
