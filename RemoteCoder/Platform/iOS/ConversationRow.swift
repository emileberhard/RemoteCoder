import Foundation
import SwiftUI

struct ConversationRow: View, Equatable {
    let row: ConversationSidebarRow
    let actions: ConversationHistoryActions
    let contextMenu: ScrollItemContextMenu<ConversationAddress>
    let selection: Bool?
    let toggleSelection: () -> Void
    @Environment(AppThemeStore.self) private var themeStore
    @ScaledMetric(relativeTo: .caption2) private var markSize: CGFloat = 13

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.row == rhs.row && lhs.selection == rhs.selection }

    var body: some View {
        let menuItems = self.menuItems
        let isHighlighted = selection ?? row.isSelected
        Button(action: tap) {
            HStack(spacing: 10) {
                if let selection {
                    selectionGlyph(isChosen: selection)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if row.showsHostLabel {
                            // With several gateways in one list, the machine is the
                            // first thing you need to know about a row.
                            Text(row.hostName)
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundStyle(row.availabilityLabel == nil ? themeStore.theme.drawerHostForeground : .secondary)
                                .lineLimit(1)
                                .accessibilityLabel("On \(row.hostName)")

                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if let availability = row.availabilityLabel {
                            Text(availability)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .layoutPriority(1)

                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Text(row.workingDirectory)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)

                        Spacer(minLength: 6)

                        status
                    }

                    HStack(alignment: .lastTextBaseline, spacing: 8) {
                        Text(row.title)
                            .font(.subheadline)
                            .fontWeight(row.isSelected || row.isUnread ? .semibold : .medium)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(.primary)

                        Spacer(minLength: 0)

                        if row.isLoading {
                            ProgressView()
                                .controlSize(.mini)
                        }

                        Text(row.ageLabel)
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .accessibilityLabel(Text(.currentDate, format: .reference(to: row.sidebarDate)))
                    }
                }
            }
            .contentTransition(.identity)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassTapTarget(cornerRadius: DrawerListMetrics.cardCornerRadius)
        }
        .buttonStyle(ResponsiveButtonStyle(feedback: selection == nil && row.isSelected ? .buttonPress : nil,
                                          pressedScale: 0.985, pressedOpacity: 0.94))
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .accessibilityActions {
            ForEach(menuItems) { item in
                Button(item.title, systemImage: item.systemImage, action: item.perform)
            }
        }
        .background(isHighlighted ? Color.appSelectedFill : .clear, in: .rect(cornerRadius: DrawerListMetrics.cardCornerRadius))
        .overlay(alignment: .leading) {
            if row.activity == .working {
                Capsule()
                    .fill(themeStore.theme.colors.accentTint)
                    .frame(width: 3)
                    .padding(.vertical, 14)
                    .padding(.leading, 1)
            }
        }
        .scrollItemMenu(
            contextMenu,
            content: ScrollItemMenuContent(
                id: row.address,
                items: menuItems,
                preview: ControlPeekPreview(symbol: "text.bubble", title: row.title,
                                            subtitle: row.hostName + " · " + row.workingDirectory,
                                            detail: row.preview),
                cornerRadius: DrawerListMetrics.cardCornerRadius
            )
        )
    }

    private var status: some View {
        HStack(spacing: 6) {
            if row.isAutomation {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Automation")
            }
            if row.forkSource != nil {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Forked conversation")
            }
            if row.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Pinned")
            }
            if row.isMuted {
                Image(systemName: "bell.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Muted")
            }
            if let route = row.inferenceProvider {
                ConversationProviderMark(route: route)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let count = row.questionCount, count > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "questionmark.bubble")
                    if count > 1 {
                        Text(count, format: .number)
                    }
                }
                .font(.caption2.weight(.semibold))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(count == 1 ? "Has a question" : "\(count) questions")
                .accessibilityIdentifier("conversation-questions-\(row.address.id)")
            }
            if let activity = row.activity, activity != .idle {
                ConversationActivityIndicator(state: activity, style: .compact)
                    .frame(height: markSize)
            }
            if row.isUnread {
                Circle()
                    .fill(themeStore.theme.colors.accentTint)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("Unread")
            }
            if row.isProbablyDone {
                Image(systemName: ConversationSettlementSymbol.settle)
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Probably done")
            }
            let provider = AgentProvider.provider(forThreadID: row.address.threadID)
            Image(provider.markImage)
                .resizable()
                .scaledToFit()
                .frame(width: markSize, height: markSize)
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(provider.displayName) conversation")
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func selectionGlyph(isChosen: Bool) -> some View {
        Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(isChosen ? AnyShapeStyle(themeStore.theme.colors.accentTint) : AnyShapeStyle(.tertiary))
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }

    private func tap() {
        guard selection != nil else {
            open()
            return
        }
        HapticService.shared.play(.selection)
        toggleSelection()
    }

    private func open() {
        _ = actions.open(row.address)
    }

    private var menuItems: [ContextMenuItem] {
        [ContextMenuItem(title: "Open conversation", systemImage: "text.bubble", perform: open)]
            + actions.rowMenuItems(for: row)
    }
}
