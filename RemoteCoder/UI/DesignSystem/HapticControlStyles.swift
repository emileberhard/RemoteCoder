import SwiftUI

enum AppControlHaptics {
    static let standardEvent: HapticEvent = .buttonPress
    static let iconEvent: HapticEvent = .iconPress

    static var standard: ResponsiveButtonStyle { ResponsiveButtonStyle(feedback: standardEvent) }
    static var icon: ResponsiveButtonStyle { ResponsiveButtonStyle(feedback: iconEvent) }
}

enum AppControlMotion {
    static func press(_ isPressed: Bool) -> Animation {
        isPressed ? .easeOut(duration: 0.075) : .spring(duration: 0.26, bounce: 0.2)
    }
}

/// A snapshot of the accepted travel through visible detents, including Automatic.
/// The gauge motion and its finite, slowing tick cadence share this timing.
struct ReasoningGaugeFeedback: Equatable {
    let tickCount: Int

    init?(from initial: ReasoningSelection, to selection: ReasoningSelection,
          efforts: [ReasoningEffort]) {
        let choices = [.automatic] + efforts.map(ReasoningSelection.effort)
        guard initial != selection, let start = choices.firstIndex(of: initial),
              let end = choices.firstIndex(of: selection) else { return nil }
        tickCount = max(2, 2 * abs(end - start))
    }

    // Large changes get a little more travel time instead of squeezing distinct
    // clicks into a buzz. Small changes retain the existing 300 ms animation.
    private var tickSpan: TimeInterval { max(0.18, Double(tickCount - 1) * 0.07) }
    var animationDuration: TimeInterval { max(0.3, tickSpan + 0.08) }

    var tickOffsets: [Duration] {
        (0..<tickCount).map { index in
            let progress = Double(index) / Double(tickCount - 1)
            return .seconds(tickSpan * progress * (0.9 + 0.1 * progress))
        }
    }

    /// waitForTick uses offsets from animation start and returns false for a missed deadline.
    /// Abandon late or cancelled sequences rather than replaying ticks in a burst.
    @MainActor
    func play(
        isCurrent: () -> Bool,
        waitForTick: (Duration) async throws -> Bool,
        feedback: (HapticEvent) -> Void
    ) async {
        guard !Task.isCancelled, isCurrent() else { return }
        feedback(.sliderStep)
        do {
            for offset in tickOffsets.dropFirst() {
                let onTime = try await waitForTick(offset)
                guard !Task.isCancelled, isCurrent(), onTime else { return }
                feedback(.sliderStep)
            }
        } catch {
            // Cancellation ends this effect; it never changes the accepted selection.
            return
        }
    }
}

extension View {
    func appGestureFeedback<Trigger: Equatable>(_ event: HapticEvent, trigger: Trigger) -> some View {
        sensoryFeedback(trigger: trigger) { _, _ in
            HapticService.shared.feedbackForInteraction(event)
        }
    }

    func appPressFeedback(_ event: HapticEvent?, isPressed: Bool) -> some View {
        modifier(AppPressFeedback(event: event, isPressed: isPressed))
    }

    func appButtonFeedback() -> some View {
        buttonStyle(AppControlHaptics.standard)
    }

    func appIconButtonFeedback() -> some View {
        buttonStyle(AppControlHaptics.icon)
    }
}

extension Binding where Value: Equatable {
    /// Attach only at a native control's input, not at the model or an onChange.
    /// Preserve SwiftUI's transaction and acknowledge only a write the owner accepts.
    @MainActor
    func nativeSelectionFeedback(using haptics: HapticService = .shared) -> Binding<Value> {
        Binding(get: { wrappedValue }, set: { value, transaction in
            let previous = wrappedValue
            guard previous != value else { return }
            self.transaction(transaction).wrappedValue = value
            guard wrappedValue == value else { return }
            haptics.nativeSelectionChanged()
        })
    }
}

private struct AppPressFeedback: ViewModifier {
    let event: HapticEvent?
    let isPressed: Bool
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.sensoryFeedback(trigger: isPressed) { old, pressed in
            guard pressed, !old, isEnabled, let event else { return nil }
            return HapticService.shared.feedbackForInteraction(event)
        }
    }
}
