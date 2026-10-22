import AppIntents

/// Publishes the quick actions to every surface that consumes App Shortcuts:
/// Siri, Spotlight, the Shortcuts gallery, and the Action Button picker in
/// Settings. Declaring the provider is the whole of the work — none of those
/// surfaces has an API of its own, and without it the intents are reachable
/// only from inside the Shortcuts app.
///
/// Every phrase must interpolate `\(.applicationName)`; App Intents drops the
/// ones that omit it and the drop is silent — the shortcut still appears in the
/// Shortcuts app while Siri never matches a word of it. The token resolves to
/// `CFBundleDisplayName` ("RemoteCoder").
///
/// Voice Mode is first because the system gives the first entry priority
/// presentation.
struct RemoteCoderAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RemoteCoderVoiceChatIntent(),
            phrases: [
                "Talk to \(.applicationName)",
                "Start voice mode in \(.applicationName)",
                "Voice mode in \(.applicationName)",
            ],
            shortTitle: "Voice Mode",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: RemoteCoderNewChatIntent(),
            phrases: [
                "New chat in \(.applicationName)",
                "Start a new conversation in \(.applicationName)",
            ],
            shortTitle: "New Chat",
            systemImageName: "keyboard"
        )
    }
}
