import Foundation

/// Resolves which gateway host owns a completion notification.
///
/// The daemon attributes every alert to its host. If that host is gone the
/// notification has no owner left: another gateway exposing the same thread id
/// is a different conversation, so no lookup by thread id is attempted.
enum TaskCompletionRouting {
    static func resolve(payloadHostID: UUID, targets: [ExecutionTarget]) -> ExecutionTarget? {
        let target = ExecutionTarget(hostID: payloadHostID)
        return targets.contains(target) ? target : nil
    }
}
