import Foundation

struct RealtimeProbeOptions {
    let claudeMode: Bool
    let contextMode: Bool
    let handoffMode: Bool
    let mediaMode: Bool
    let silent: Bool
    let fixturePath: String?
    let cwd: String?

    init(arguments: [String]) throws {
        var flags: Set<String> = []
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--claude", "--resume-context", "--handoff", "--media", "--silent":
                flags.insert(argument)
            case "--fixture", "--cwd":
                guard values[argument] == nil, index + 1 < arguments.count,
                      !arguments[index + 1].hasPrefix("--") else {
                    throw Failure("\(argument) requires one value")
                }
                index += 1
                values[argument] = arguments[index]
            default:
                throw Failure("Unknown probe argument: \(argument)")
            }
            index += 1
        }
        claudeMode = flags.contains("--claude")
        contextMode = flags.contains("--resume-context")
        handoffMode = !contextMode && (flags.contains("--handoff") || claudeMode)
        mediaMode = flags.contains("--media") || handoffMode || contextMode
        silent = flags.contains("--silent")
        fixturePath = values["--fixture"]
        cwd = values["--cwd"]
        if mediaMode, fixturePath == nil {
            throw Failure("--fixture PATH is required for media validation")
        }
    }

    func workingDirectory(homeDirectory: String?) throws -> String {
        guard let path = cwd ?? homeDirectory, path.hasPrefix("/"),
              path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure("A valid absolute --cwd or host/info homeDirectory is required")
        }
        return path
    }

    func gatewayURL(port: String) throws -> URL {
        guard let number = Int(port), (1...65535).contains(number) else {
            throw Failure("Gateway port is invalid")
        }
        var components = URLComponents()
        components.scheme = "ws"
        components.host = "127.0.0.1"
        components.port = number
        components.path = "/ws"
        guard let url = components.url else { throw Failure("Gateway URL is invalid") }
        return url
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
