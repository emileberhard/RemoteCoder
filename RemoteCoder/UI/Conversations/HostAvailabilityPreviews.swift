#if DEBUG
import SwiftUI

@MainActor
private enum AvailabilityFixture {
    static let host = UUID(uuidString: "0B6E1D52-9A43-4C7E-8F21-6C3D5E7A9B10") ?? UUID()
    static let lastSeen = Calendar.current.date(bySettingHour: 12, minute: 54, second: 0, of: .now) ?? .now

    static func presentation(_ reach: HostAvailability.Reach, host name: String, tasks: Int) -> HostPresentation {
        HostPresentation(HostAvailability(reach: reach, lastSeen: lastSeen, tasksRunningAtLoss: tasks), historyFailure: nil,
                         context: .current(hostName: name, device: ThisDevice.noun))
    }

    static let offlinePortable = presentation(.offline, host: "macbook", tasks: 0)
    static let unreachableStationary = presentation(.unreachable, host: "mac-mini", tasks: 1)

    static func rows(host name: String, label: String?) -> [ConversationSidebarRow] {
        [("Fix the drawer flicker", "RemoteCoder", "13:02", true),
         ("Offline hosts design", "RemoteCoder", "12:51", false),
         ("Mumla release notes", "mumla", "Yesterday", false)].enumerated().map { index, item in
            ConversationSidebarRow(id: "row-\(index)", address: ConversationAddress(hostID: host, threadID: "t\(index)"),
                                   hostName: name, showsHostLabel: true, availabilityLabel: label, title: item.0,
                                   preview: "", sidebarDate: .now, dateLabel: item.2, ageLabel: item.2,
                                   workingDirectory: "~/\(item.1)", isPinned: false, isUnread: item.3,
                                   isSelected: false, isLoading: false, activity: nil)
        }
    }

    static let messages = [
        "Can you check why the drawer flickers when a host goes away?",
        "The list reloads under the finger while the drawer slides open. I'll keep the cached rows and only swap the status line.",
    ]
}

private struct AvailabilityDrawerFixture: View {
    let presentation: HostPresentation
    let host: String
    @State private var theme = AppThemeStore()

    var body: some View {
        let rows = AvailabilityFixture.rows(host: host, label: presentation.rowLabel)
        #if os(iOS)
        ZStack {
            DrawerBackground()
            VStack(alignment: .leading, spacing: 0) {
                HostAvailabilityLineList(lines: presentation.strip, detail: { nil }, retry: {}).padding(.horizontal)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            ConversationRow(row: row, actions: .preview, contextMenu: ScrollItemContextMenu<ConversationAddress>(),
                                            selection: nil, toggleSelection: {})
                        }
                    }
                }
            }
        }
        .environment(theme)
        #else
        VStack(alignment: .leading, spacing: 0) {
            HostAvailabilityLineList(lines: presentation.strip, detail: { nil }, retry: {}).padding(.horizontal)
            List {
                Section("Chats") {
                    ForEach(rows) { row in ConversationSourceRow(row: row, hostName: host, settle: {}) }
                }
            }
            .listStyle(.sidebar)
        }
        .frame(width: 300, height: 420)
        .environment(theme)
        #endif
    }
}

private struct AvailabilityChatFixture: View {
    let presentation: HostPresentation
    @State private var theme = AppThemeStore()

    var body: some View {
        ZStack {
            ThemedAppBackground()
            VStack(alignment: .leading, spacing: 16) {
                HostAvailabilityLineList(lines: presentation.chat, detail: { nil }, retry: {})
                ForEach(Array(AvailabilityFixture.messages.enumerated()), id: \.offset) { index, text in
                    Text(text)
                        .scaledFont(.body)
                        .padding(12)
                        .background(index == 0 ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 18))
                        .frame(maxWidth: .infinity, alignment: index == 0 ? .trailing : .leading)
                }
                Spacer()
                if let reason = presentation.sendHeldReason {
                    Label(reason, systemImage: "exclamationmark.circle")
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
            ConnectionEdgeGlow(edge: presentation.edge)
        }
        .environment(theme)
        #if os(macOS)
        .frame(width: 560, height: 420)
        #endif
    }
}

#if os(iOS)
private extension ConversationHistoryActions {
    static var preview: Self {
        Self(open: { _ in .changed }, openSearch: { _ in .changed }, askSearch: {}, pin: { _ in }, rename: { _ in },
             regenerateName: { _ in }, unpin: { _ in }, fork: { _ in }, moveUnder: { _ in }, markRead: { _ in },
             markUnread: { _ in }, mute: { _ in }, unmute: { _ in }, settle: { _ in }, unsettle: { _ in }, openDraft: { _ in }, discardDraft: { _ in },
             startNew: { _ in }, showSettings: {}, focusComposer: {}, chooseInferenceProvider: { _ in })
    }
}
#endif

#Preview("Drawer · offline portable") {
    AvailabilityDrawerFixture(presentation: AvailabilityFixture.offlinePortable, host: "macbook")
}

#Preview("Drawer · unreachable stationary") {
    AvailabilityDrawerFixture(presentation: AvailabilityFixture.unreachableStationary, host: "mac-mini")
}

#Preview("Chat · offline portable") {
    AvailabilityChatFixture(presentation: AvailabilityFixture.offlinePortable)
}

#Preview("Chat · unreachable stationary") {
    AvailabilityChatFixture(presentation: AvailabilityFixture.unreachableStationary)
}
#endif
