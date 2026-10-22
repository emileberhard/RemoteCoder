import Foundation
import Testing
@testable import RemoteCoderCore

struct ActiveTasksLiveActivityScopeTests {
    private let mini = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!
    private let book = UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000002")!

    enum ActivityHost: CaseIterable, Sendable {
        case same, other, legacy
    }

    @Test(arguments: ActivityHost.allCases)
    func hostOwnershipAndLegacyRetirement(_ scenario: ActivityHost) {
        let activityHostID: UUID? = switch scenario {
        case .same: mini
        case .other: book
        case .legacy: nil
        }
        #expect(ActiveTasksLiveActivityScope.owns(activityHostID: activityHostID, serviceHostID: mini) == (scenario == .same))
        #expect(ActiveTasksLiveActivityScope.isLegacy(activityHostID: activityHostID) == (scenario == .legacy))
        #expect(ActiveTasksLiveActivityScope.mayEnd(activityHostID: activityHostID, serviceHostID: mini) == (scenario != .other))
        if scenario == .legacy {
            #expect(ActiveTasksLiveActivityScope.mayEnd(activityHostID: activityHostID, serviceHostID: book))
        }
    }
}


struct LiveActivityAttentionIdentityTests {
    @Test func retiredAccountAndHostAttentionShareOneRowIdentity() {
        typealias Attention = ActiveTasksLiveActivityContent.Attention
        let rows = [nil, UUID(uuidString: "E1741C43-3D9A-4448-9F4A-3C7E5906E852")].map { account in
            Attention(threadID: "same-thread", accountID: account, title: "Result", reason: .finishedUnread,
                      completedAtUnixSeconds: 20)
        }
        #expect(Set(rows.map(\.id)).count == 1)
        #expect(rows[0].id == rows[1].id)
    }
}
