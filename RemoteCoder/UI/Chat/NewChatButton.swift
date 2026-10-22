import SwiftUI

struct NewChatButton: View {
    let onNewChat: () -> Void
    let onNewChatInHome: () -> Void
    @State private var isPressed = false
    @State private var homeStarts = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Image(systemName: "square.and.pencil")
            .scaledFont(.system(size: 19, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(colorScheme == .dark ? Color.white : Color.primary)
            .symbolEffectsRemoved(reduceMotion)
            .symbolEffect(.bounce, value: homeStarts)
            .frame(width: 44, height: 44)
            .appGlass(.standard, in: .circle)
            .scaleEffect(isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(isPressed ? 0.9 : 1)
            .animation(reduceMotion ? nil : AppControlMotion.press(isPressed), value: isPressed)
            .accessibilityHidden(true)
            .overlay {
                TapHoldButton(label: "New chat", value: nil, hint: "Hold to start in the home folder.",
                              identifier: "new-chat",
                              accessibilityActions: [.init(name: "New Chat in Home", perform: startInHome)],
                              onPress: { isPressed = $0 }, onContactEnded: {}, onTap: onNewChat, onHold: holdChanged)
                    .accessibilityShowsLargeContentViewer {
                        Label("New chat", systemImage: "square.and.pencil")
                    }
            }
            .appPressFeedback(.iconPress, isPressed: isPressed)
            .appGestureFeedback(.commit, trigger: homeStarts)
    }

    private func holdChanged(_ phase: TapHoldPhase, _: CGPoint, _: CGRect) {
        guard phase == .began, isEnabled, scenePhase == .active else { return }
        startInHome()
    }

    private func startInHome() {
        homeStarts += 1
        onNewChatInHome()
    }
}
