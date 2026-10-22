import SwiftUI

/// The catalog drives suggestions, so another command needs no new composer layout.
struct ComposerCommandSuggestions: View {
    let commands: [ComposerSlashCommand]
    let unavailableReason: String?
    let select: (ComposerSlashCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(commands) { command in
                Button { select(command) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: command.systemImage)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(command.invocation).scaledFont(.subheadline.monospaced().weight(.semibold))
                            Text(command.summary).scaledFont(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: ControlMetrics.minimumTarget, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(ResponsiveButtonStyle())
                .accessibilityLabel("\(command.invocation), \(command.title)")
                .accessibilityHint("Insert command. Send to run it.")
                .accessibilityIdentifier("composer-command-\(command.rawValue)")
            }
            if let unavailableReason {
                Text(unavailableReason)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(.primary.opacity(0.05), in: .rect(cornerRadius: 12))
    }
}
