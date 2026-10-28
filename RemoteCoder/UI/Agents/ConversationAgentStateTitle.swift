import Foundation

extension ConversationAgent.State {
    var title: String {
        switch self {
        case .working: "Working"
        case .waiting: "Needs attention"
        case .completed: "Completed"
        case .interrupted: "Stopped"
        case .failed: "Failed"
        case .unknown: "Status unavailable"
        case .removed: "Removed"
        }
    }
}
