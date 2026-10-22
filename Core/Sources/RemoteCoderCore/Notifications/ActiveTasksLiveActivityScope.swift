import Foundation

/// Decides which "active tasks" Live Activities one host's service may touch.
///
/// Each host runs its own aggregate activity, so the previous
/// first-activity/end-all behaviour would let an idle laptop end the Mini's
/// activity while its turns were still running.
enum ActiveTasksLiveActivityScope {
    /// This host's own activity: the only one it may update.
    static func owns(activityHostID: UUID?, serviceHostID: UUID) -> Bool {
        activityHostID == serviceHostID
    }

    /// Activities requested before per-host attributes existed carry no host id.
    /// Any host may retire those, because a current activity always has one.
    static func isLegacy(activityHostID: UUID?) -> Bool {
        activityHostID == nil
    }

    static func mayEnd(activityHostID: UUID?, serviceHostID: UUID) -> Bool {
        owns(activityHostID: activityHostID, serviceHostID: serviceHostID)
            || isLegacy(activityHostID: activityHostID)
    }
}
