#if os(macOS)
import AppKit
import SwiftUI

@main
struct RemoteCoderMacApp: App {
    @NSApplicationDelegateAdaptor(RemoteCoderMacAppDelegate.self) private var delegate
    @State private var tabbing = WindowTabbing()
    private var app: RemoteCoderAppModel { delegate.app }

    var body: some Scene {
        WindowGroup("RemoteCoder", id: "main", for: ConversationWindowValue.self) { $value in
            WindowRoot(app: app, environment: environment, tabbing: tabbing, value: $value)
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            ChatCommands()
            WindowTabCommands(tabbing: tabbing)
            InterfaceZoomCommands(zoom: delegate.zoom)
        }

        Settings {
            SettingsView(workspace: app.workspace)
                .modifier(environment)
                .modifier(WindowOpeners(events: app.workspace.events))
        }
    }

    private var environment: AppEnvironment {
        AppEnvironment(app: app, theme: app.theme, zoom: delegate.zoom, quickEntry: delegate.quickEntry)
    }
}

private struct AppEnvironment: ViewModifier {
    let app: RemoteCoderAppModel
    let theme: AppThemeStore
    let zoom: InterfaceZoom
    let quickEntry: QuickEntry

    func body(content: Content) -> some View {
        content
            .disabled(app.workspace.isQuiescing)
            .defaultAppStorage(AppStorageScope.current.defaults)
            .environment(app.workspace.settings)
            .environment(app.workspace.modelPickerPreferences)
            .environment(theme)
            .environment(\.transcriptSurfaceRetention, app.workspace.retainedTranscripts)
            .environment(quickEntry)
            .environment(\.appEnergyPolicy, app.energy.policy)
            .environment(\.siteIcons, app.workspace.siteIcons)
            .modifier(InterfaceZoomEnvironment(zoom: zoom))
    }
}

private struct WindowRoot: View {
    let app: RemoteCoderAppModel
    let environment: AppEnvironment
    let tabbing: WindowTabbing
    @Binding var value: ConversationWindowValue?

    var body: some View {
        Group {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-html-visual-fixture") {
                HTMLVisualFixture()
            } else {
                ChatRootView(workspace: app.workspace, sceneValue: $value)
            }
            #else
            ChatRootView(workspace: app.workspace, sceneValue: $value)
            #endif
        }
            .modifier(environment)
            .modifier(SceneLifecycle(app: app))
            .background { HapticOutput() }
            .background { WindowTabAdoption(tabbing: tabbing, value: value) }
            .frame(minWidth: 720, minHeight: 520)
            .modifier(WindowOpeners(events: app.workspace.events))
    }
}

private struct WindowOpeners: ViewModifier {
    let events: ExternalEventRouter
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            events.attach(openWindow: { openWindow(value: $0) })
            events.attach(openMainWindow: { openWindow(id: "main") })
        }
    }
}

private struct SceneLifecycle: ViewModifier {
    let app: RemoteCoderAppModel
    @State private var sceneID = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { Task { await app.apply(.active, scene: sceneID) } }
            .onDisappear { Task { await app.detach(scene: sceneID) } }
    }
}
#endif
