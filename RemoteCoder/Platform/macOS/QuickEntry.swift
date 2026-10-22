#if os(macOS)
import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

@MainActor
@Observable
final class QuickEntry {
    static let shortcutLabel = "⌃⌥Space"
    private static let enabledKey = "quickEntry.hotKeyEnabled"
    private static let draftSlot = UUID(uuid: (0x52, 0x43, 0x51, 0x45, 0x00, 0x00, 0x40, 0x00,
                                               0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01))
    private static let recentLimit = 5

    private struct Presentation {
        let panel: FloatingPanel
        let session: QuickEntrySession
    }

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            applyRegistration()
        }
    }
    private(set) var registrationFailure: String?

    @ObservationIgnored private let workspace: ChatWorkspaceModel
    @ObservationIgnored private let theme: AppThemeStore
    @ObservationIgnored private let zoom: InterfaceZoom
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var hotKey: GlobalHotKey?
    @ObservationIgnored private var presentation: Presentation?

    init(workspace: ChatWorkspaceModel, theme: AppThemeStore, zoom: InterfaceZoom, defaults: UserDefaults) {
        self.workspace = workspace
        self.theme = theme
        self.zoom = zoom
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func start() {
        isRunning = true
        applyRegistration()
    }

    func stop() {
        isRunning = false
        applyRegistration()
    }

    private func applyRegistration() {
        guard isRunning, isEnabled else {
            close()
            hotKey = nil
            registrationFailure = nil
            return
        }
        guard hotKey == nil else { return }
        do {
            hotKey = try GlobalHotKey(keyCode: kVK_Space, modifiers: controlKey | optionKey) { [weak self] in
                self?.toggle()
            }
            registrationFailure = nil
        } catch {
            registrationFailure = "\(Self.shortcutLabel) is unavailable: \(error.localizedDescription)"
        }
    }

    private func toggle() {
        if presentation == nil { open() } else { close() }
    }

    private func open() {
        guard let display = NSScreen.main else { return }
        let front = workspace.selectedScreen
        let window = workspace.attachWindow(opening: .newChat(slot: Self.draftSlot))
        if let front, let screen = window.selectedScreen, screen.executionTarget == front.executionTarget,
           let folder = front.workingDirectory, screen.workingDirectory != folder {
            screen.suggestWorkingDirectory(folder)
        }
        let recents = workspace.quickEntryRecents(in: window, limit: Self.recentLimit)
        let session = QuickEntrySession(workspace: workspace, window: window, recents: recents)
        let content = QuickEntryView(
            session: session,
            close: { [weak self] in self?.close() },
            openInWindow: { [weak self] in self?.openInWindow($0) }
        )
            .defaultAppStorage(AppStorageScope.current.defaults)
            .environment(theme)
            .environment(workspace.settings)
            .environment(workspace.modelPickerPreferences)
            .modifier(InterfaceZoomEnvironment(zoom: zoom))
        let panel = FloatingPanel(
            content: content,
            becameKey: { [workspace] in workspace.setWindowKey(window) },
            dismiss: { [weak self] in self?.close() }
        )
        panel.isMovableByWindowBackground = true
        presentation = Presentation(panel: panel, session: session)
        panel.present { size in
            let visible = display.visibleFrame
            return NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                          width: size.width, height: size.height)
        }
    }

    private func close() {
        guard let presentation else { return }
        presentation.session.cancelNavigation()
        self.presentation = nil
        presentation.panel.orderOut(nil)
        workspace.detachWindow(presentation.session.window)
        workspace.setWindowActive(presentation.session.window, isActive: false)
    }

    private func openInWindow(_ address: ConversationAddress) {
        close()
        NSApp.activate()
        workspace.events.summon(.open(.conversation(address)))
    }
}
#endif
