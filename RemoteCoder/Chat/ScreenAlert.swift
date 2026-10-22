enum ScreenAlert: Equatable {
    case conversation(String)
    case attachments(String)
    case draft(String)

    var message: String {
        switch self {
        case .conversation(let message), .attachments(let message), .draft(let message): message
        }
    }
}
