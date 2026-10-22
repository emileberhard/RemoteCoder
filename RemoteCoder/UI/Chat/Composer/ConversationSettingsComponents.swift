import SwiftUI

struct ReasoningGaugePosition {
    let fraction: Double
    let isAutomatic: Bool

    init(efforts: [ReasoningEffort], selection: ReasoningSelection) {
        if case let .effort(effort) = selection,
           let index = efforts.firstIndex(of: effort) {
            // Even the lowest enabled effort is nonzero; one available effort is also the maximum.
            fraction = efforts.count == 1 ? 1 : 0.25 + 0.75 * Double(index) / Double(efforts.count - 1)
            isAutomatic = false
        } else {
            fraction = 1
            isAutomatic = true
        }
    }
}

struct ReasoningEffortIndicator: View {
    let position: ReasoningGaugePosition
    let height: CGFloat
    @Environment(AppThemeStore.self) private var themeStore

    var body: some View {
        // The 240° arc occupies 3/4 of the circle's height, plus its stroke.
        let diameter = height / 0.85
        let lineWidth = diameter * 0.1
        ZStack {
            Circle()
                .trim(from: 1.0 / 6, to: 5.0 / 6)
                .stroke(Color.appSystemGray3, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(90))
            Circle()
                .trim(from: 1.0 / 6, to: 1.0 / 6 + (2.0 / 3) * position.fraction)
                .stroke(themeStore.theme.colors.accentTint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(90))
            if !position.isAutomatic {
                Capsule()
                    .fill(.foreground)
                    .frame(width: diameter * 0.11, height: diameter * 0.25)
                    .offset(y: -diameter * 0.25)
                    .rotationEffect(.degrees(-120 + 240 * position.fraction))
                Circle()
                    .stroke(.foreground, lineWidth: lineWidth)
                    .frame(width: diameter * 0.22, height: diameter * 0.22)
            } else {
                Text("A").scaledFont(.system(size: diameter * 0.45, weight: .semibold))
            }
        }
        .frame(width: diameter, height: diameter)
        .offset(y: diameter / 8)
        .frame(width: diameter + lineWidth, height: height)
        // Explicit foreground styling keeps the pointer out of material vibrancy.
        .foregroundStyle(Color.appLabel)
    }
}

struct ConversationModelMenu: View {
    let models: [ModelOption]
    @Binding var selection: ModelOption

    var body: some View {
        AppMenu {
            Picker("Model", selection: $selection.nativeSelectionFeedback()) {
                ForEach(models) { option in
                    modelLabel(option).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            ConversationSettingLabel(title: selection.displayName, daybreakBlue: selection.supportsDaybreakBlue)
                .scaledFont(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.primary)
        #if os(macOS)
        .accessibilityElement(children: .combine)
        #endif
        .accessibilityLabel("Model")
        .accessibilityValue(selection.supportsDaybreakBlue ? "\(selection.displayName), Daybreak Blue" : selection.displayName)
        .accessibilityIdentifier("conversation-model-menu")
    }

    @ViewBuilder private func modelLabel(_ option: ModelOption) -> some View {
        if option.supportsDaybreakBlue {
            Label("\(option.displayName) · Daybreak Blue", systemImage: "shield")
        } else {
            Text(option.displayName)
        }
    }
}

struct UnresolvedModelControls: View {
    let reason: String
    let models: [ModelOption]
    @Binding var selection: ModelOption?
    let retry: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if !models.isEmpty {
                AppMenu {
                    Picker("Model", selection: $selection.nativeSelectionFeedback()) {
                        ForEach(models) { option in
                            Text(option.displayName).tag(Optional(option))
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    ConversationSettingLabel(title: "Model")
                        .scaledFont(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.primary)
                .accessibilityLabel("Model")
                .accessibilityIdentifier("conversation-model-menu")
                .composerControlHitRegion()
            }
            Text(reason)
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let retry {
                Button("Retry", action: retry)
                    .buttonStyle(ResponsiveButtonStyle())
                    .frame(minHeight: ControlMetrics.minimumTarget)
                    .composerControlHitRegion()
            }
        }
        .frame(minHeight: ControlMetrics.minimumTarget)
        .accessibilityIdentifier("conversation-model-unavailable")
    }
}

struct ConversationFastModeToggle: View {
    @Environment(AppThemeStore.self) private var themeStore

    let isAvailable: Bool
    @Binding var isOn: Bool?
    let symbolHeight: CGFloat

    private var isEffectivelyOn: Bool { isOn == true && isAvailable }

    private var label: String {
        guard isAvailable else { return "Fast unavailable" }
        guard let isOn else { return "Fast status unavailable" }
        return isOn ? "Fast on" : "Fast off"
    }

    var body: some View {
        Toggle(isOn: Binding(get: { isOn == true }, set: { value in
            guard isAvailable, value != isOn else { return }
            isOn = value
            HapticService.shared.play(value ? .toggleOn : .toggleOff)
        })) {
            Image(systemName: "bolt.fill")
                .resizable()
                .symbolRenderingMode(.monochrome)
                .scaledToFit()
                .frame(width: symbolHeight, height: symbolHeight)
                .overlay(alignment: .topTrailing) {
                    if isAvailable, isOn == nil {
                        Text("?").scaledFont(.caption2.bold()).offset(x: 8, y: -3)
                    }
                }
                .frame(minWidth: ControlMetrics.minimumTarget, minHeight: ControlMetrics.minimumTarget)
                .contentShape(.rect)
        }
        .toggleStyle(.button)
        .buttonStyle(ResponsiveButtonStyle(feedback: nil))
        .foregroundStyle(isEffectivelyOn ? themeStore.theme.colors.accentTint : Color.secondary)
        .opacity(isAvailable ? 1 : 0.35)
        .disabled(!isAvailable)
        .accessibilityLabel("Fast mode")
        .accessibilityValue(label)
        .accessibilityIdentifier("conversation-fast-mode-toggle")
    }
}

struct ConversationSettingLabel: View {
    let title: String
    var daybreakBlue = false

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
            if daybreakBlue {
                Image(systemName: "shield")
                    .scaledFont(.caption2)
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)
            }
            Image(systemName: "chevron.down")
                .scaledFont(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: ControlMetrics.minimumTarget)
        .contentShape(.rect)
    }
}

struct ConversationSettingsStatus: View {
    let screen: ChatScreenModel
    let threadID: String?

    var body: some View {
        if let error = screen.settingsUpdateError(for: threadID) {
            Text(error).scaledFont(.caption).foregroundStyle(.red)
        } else if let warning = screen.settingsUpdateWarning(for: threadID) {
            Text(warning).scaledFont(.caption).foregroundStyle(.secondary)
        } else if let notice = screen.settingsNotice(for: threadID) {
            Text(notice).scaledFont(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Reads only metadata synchronization state, not the streaming transcript.
struct ConversationMetadataStatus: View {
    let screen: ChatScreenModel

    var body: some View {
        if let threadID = screen.activeSessionID, screen.target.metadataStatus.conflicts.contains(threadID) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Saved preferences changed on another device. Your local choice has been preserved.")
                    .scaledFont(.footnote)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { decisions(threadID) }
                    VStack(alignment: .leading, spacing: 8) { decisions(threadID) }
                }
                .disabled(screen.target.isResolvingMetadata)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("metadata-conflict")
        } else if let error = screen.target.metadataStatus.error {
            VStack(alignment: .leading, spacing: 4) {
                Text(error).scaledFont(.footnote)
                Button("Retry settings sync") { screen.target.retryMetadataSynchronization() }
                    .buttonStyle(ResponsiveButtonStyle())
                    .composerControlHitRegion()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("metadata-sync-error")
        }
    }

    @ViewBuilder private func decisions(_ threadID: String) -> some View {
        Button("Keep local preference") { screen.target.resolveMetadataConflict(threadID: threadID, keepLocal: true) }
            .buttonStyle(ResponsiveButtonStyle())
            .composerControlHitRegion()
        Button("Use saved preference") { screen.target.resolveMetadataConflict(threadID: threadID, keepLocal: false) }
            .buttonStyle(ResponsiveButtonStyle())
            .composerControlHitRegion()
    }
}
