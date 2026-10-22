#if os(macOS)
import AppKit

@MainActor
final class AppKeyMonitor {
    private let zoom: InterfaceZoom
    private var monitor: Any?

    init(zoom: InterfaceZoom) {
        self.zoom = zoom
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.consume(event) ?? false }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func consume(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.contains(.command), modifiers.isDisjoint(with: [.control, .option]),
           let character = event.characters(byApplyingModifiers: modifiers.intersection(.shift)),
           character == "+" || character == "=" {
            zoom.zoomIn()
            return true
        }
        if let window = event.window, window.isKeyWindow,
           Self.belongsInComposer(event, modifiers: modifiers, responder: window.firstResponder) {
            ComposerTextInput.takeFocus(in: window)
        }
        return false
    }

    private static func belongsInComposer(_ event: NSEvent, modifiers: NSEvent.ModifierFlags,
                                          responder: NSResponder?) -> Bool {
        if let text = responder as? NSText, text.isEditable { return false }
        if modifiers == .command { return event.charactersIgnoringModifiers == "v" }
        guard modifiers.isDisjoint(with: [.command, .control]), !(responder is NSTableView),
              let scalar = event.characters?.unicodeScalars.first else { return false }
        return !CharacterSet.whitespacesAndNewlines.contains(scalar)
            && !CharacterSet.controlCharacters.contains(scalar)
            && !(0xF700...0xF8FF).contains(scalar.value)
    }
}
#endif
