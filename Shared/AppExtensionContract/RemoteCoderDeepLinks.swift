import Foundation

enum RemoteCoderQuickAction: String, Codable, Sendable {
    case newChat
    case voiceChat
    case camera
}

/// One request shape for every entry point. App Intents and `remotecoder://`
/// URLs both produce this and nothing else.
struct RemoteCoderQuickActionRequest: Codable, Equatable, Sendable {
    let action: RemoteCoderQuickAction
    /// Voice Mode only: clear the conversation and apply shortcut settings before
    /// the call. Entry points that promise a new conversation set this; the
    /// composer's voice button must not.
    let startsFreshVoiceChat: Bool
    let voiceConfiguration: RemoteCoderVoiceConfiguration?

    init(
        action: RemoteCoderQuickAction,
        startsFreshVoiceChat: Bool = false,
        voiceConfiguration: RemoteCoderVoiceConfiguration? = nil
    ) {
        self.action = action
        self.startsFreshVoiceChat = startsFreshVoiceChat
        self.voiceConfiguration = voiceConfiguration
    }
}

struct RemoteCoderVoiceConfiguration: Codable, Equatable, Sendable {
    let modelID: String?
    let reasoningSelectionID: String?
    let fastModeEnabled: Bool
}

struct RemoteCoderConversationLink: Equatable, Sendable {
    let hostID: UUID
    let threadID: String
}

/// The `remotecoder://` vocabulary the app accepts.
enum RemoteCoderDeepLinks {
    static let openApp: URL = {
        guard let url = URL(string: "remotecoder://chat") else {
            preconditionFailure("Invalid RemoteCoder app URL")
        }
        return url
    }()

    static func url(for link: RemoteCoderConversationLink) -> URL {
        var components = URLComponents()
        components.scheme = "remotecoder"
        components.host = "chat"
        components.path = "/conversation"
        components.queryItems = [
            URLQueryItem(name: "host", value: link.hostID.uuidString),
            URLQueryItem(name: "thread", value: link.threadID),
        ]
        guard let url = components.url else {
            preconditionFailure("Invalid RemoteCoder conversation URL")
        }
        return url
    }

    static func url(forSharedItems id: UUID) -> URL { url(path: "/share", id: id) }

    static func sharedItems(from url: URL) -> UUID? { id(in: url, path: "/share") }

    static func url(forVoiceCall id: UUID) -> URL { url(path: "/call", id: id) }

    static func voiceCall(from url: URL) -> UUID? { id(in: url, path: "/call") }

    private static func url(path: String, id: UUID) -> URL {
        var components = URLComponents()
        components.scheme = "remotecoder"
        components.host = "chat"
        components.path = path
        components.queryItems = [URLQueryItem(name: "id", value: id.uuidString)]
        guard let url = components.url else {
            preconditionFailure("Invalid RemoteCoder \(path) URL")
        }
        return url
    }

    private static func id(in url: URL, path: String) -> UUID? {
        guard url.scheme == "remotecoder", url.host == "chat", url.path == path else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "id" }?.value.flatMap(UUID.init(uuidString:))
    }

    static func conversation(from url: URL) -> RemoteCoderConversationLink? {
        guard url.scheme == "remotecoder", url.host == "chat", url.path == "/conversation",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let hostID = items.first(where: { $0.name == "host" })?.value.flatMap(UUID.init(uuidString:)),
              let threadID = items.first(where: { $0.name == "thread" })?.value, !threadID.isEmpty else { return nil }
        return RemoteCoderConversationLink(hostID: hostID, threadID: threadID)
    }

    static func request(from url: URL) -> RemoteCoderQuickActionRequest? {
        guard url.scheme == "remotecoder", url.host == "chat" else { return nil }

        switch url.path {
        case "/new":
            return RemoteCoderQuickActionRequest(action: .newChat)
        case "/voice":
            return RemoteCoderQuickActionRequest(
                action: .voiceChat,
                startsFreshVoiceChat: isFresh(url)
            )
        default:
            return nil
        }
    }

    private static func isFresh(_ url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .contains { $0.name == "fresh" && $0.value == "1" } ?? false
    }
}
