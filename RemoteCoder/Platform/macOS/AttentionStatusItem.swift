#if os(macOS)
import AppKit
import SwiftUI

@MainActor
final class AttentionStatusItem: NSObject {
    private let attention: AttentionCenter
    private var item: NSStatusItem?
    private var panel: FloatingPanel?
    private var observation: Task<Void, Never>?
    private var needsYou: Bool?

    init(attention: AttentionCenter) {
        self.attention = attention
    }

    func start() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(togglePanel(_:))
        item.button?.sendAction(on: [.leftMouseDown])
        self.item = item
        show(needsYou: attention.summary.needsYouCount > 0)
        observation = Task { [weak self, attention] in
            for await needsYou in Observations({ @MainActor in attention.summary.needsYouCount > 0 }) {
                self?.show(needsYou: needsYou)
            }
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
        closePanel()
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        needsYou = nil
    }

    private func show(needsYou: Bool) {
        guard needsYou != self.needsYou, let button = item?.button else { return }
        self.needsYou = needsYou
        button.image = NSImage(systemSymbolName: needsYou ? "exclamationmark.bubble.fill" : "apple.terminal",
                               accessibilityDescription: needsYou ? "RemoteCoder, needs you" : "RemoteCoder")
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        if panel != nil { return closePanel() }
        guard let window = sender.window, let screen = window.screen else { return }
        let anchor = window.convertToScreen(sender.convert(sender.bounds, to: nil))
        let content = AttentionPanel(attention: attention) { [weak self] action in
            self?.closePanel()
            self?.attention.perform(action)
        }
        let panel = FloatingPanel(content: content, becameKey: {}, dismiss: { [weak self] in self?.closePanel() })
        self.panel = panel
        panel.present { size in
            let visible = screen.visibleFrame
            let x = min(max(anchor.midX - size.width / 2, visible.minX), visible.maxX - size.width)
            return NSRect(x: x, y: anchor.minY - size.height - 4, width: size.width, height: size.height)
        }
    }

    private func closePanel() {
        guard let panel else { return }
        self.panel = nil
        panel.orderOut(nil)
    }
}

private struct AttentionPanel: View {
    let attention: AttentionCenter
    let perform: (AttentionCenter.Action) -> Void

    var body: some View {
        let summary = attention.summary
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                AttentionTally(title: "Needs you", count: summary.needsYouCount, isHighlighted: summary.needsYouCount > 0)
                AttentionTally(title: "Running", count: summary.runningCount, isHighlighted: false)
            }
            if !summary.hostsWithUnknownStatus.isEmpty {
                Label("Status unknown on \(summary.hostsWithUnknownStatus.formatted(.list(type: .and)))",
                      systemImage: "questionmark.circle")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
            if !summary.entries.isEmpty {
                VStack(spacing: 2) {
                    ForEach(summary.entries) { entry in
                        AttentionRow(entry: entry, showsHostName: summary.showsHostNames) {
                            perform(.open(entry.address))
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button("New Chat") { perform(.newChat) }
                Spacer()
                Button("Open RemoteCoder") { perform(.showApp) }
            }
        }
        .padding(12)
        .frame(width: 300)
        .appGlass(.standard, in: .rect(cornerRadius: 16, style: .continuous))
    }
}

private struct AttentionTally: View {
    let title: String
    let count: Int
    let isHighlighted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(count, format: .number)
                .scaledFont(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isHighlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            Text(title)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary, in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private struct AttentionRow: View {
    let entry: AttentionSummary.Entry
    let showsHostName: Bool
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(entry.kind.needsYou ? .primary : .secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .lineLimit(1)
                    if showsHostName {
                        Text(entry.hostName)
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(.rect)
            .background(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.clear), in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityValue(state)
    }

    private var symbol: String {
        switch entry.kind {
        case .question: "questionmark.bubble"
        case .input: "hand.raised"
        case .running: "ellipsis"
        }
    }

    private var state: String {
        switch entry.kind {
        case .question: "Has a question"
        case .input: "Needs input"
        case .running: "Working"
        }
    }
}
#endif
