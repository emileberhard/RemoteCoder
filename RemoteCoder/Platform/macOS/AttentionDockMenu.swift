#if os(macOS)
import AppKit

enum AttentionDockMenu {
    private static let titleLimit = 60

    @MainActor
    static func make(_ summary: AttentionSummary, target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu()
        let sections = [
            ("Needs You", summary.entries.filter(\.kind.needsYou)),
            ("Running", summary.entries.filter { !$0.kind.needsYou }),
        ]
        for (title, entries) in sections where !entries.isEmpty {
            menu.addItem(.sectionHeader(title: title))
            for entry in entries {
                menu.addItem(item(label(entry, showsHostName: summary.showsHostNames), performing: .open(entry.address),
                                  target: target, action: action))
            }
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        menu.addItem(item("New Chat", performing: .newChat, target: target, action: action))
        menu.addItem(item("New Window", performing: .newWindow, target: target, action: action))
        return menu
    }

    @MainActor
    private static func item(_ title: String, performing performed: AttentionCenter.Action,
                             target: AnyObject, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.representedObject = performed
        return item
    }

    private static func label(_ entry: AttentionSummary.Entry, showsHostName: Bool) -> String {
        let line = entry.title.split(whereSeparator: \.isNewline).first.map(String.init) ?? entry.title
        let title = line.count > titleLimit ? String(line.prefix(titleLimit - 1)) + "…" : line
        return showsHostName ? "\(title) — \(entry.hostName)" : title
    }
}
#endif
