import Foundation
import SwiftUI

#if os(iOS)
struct StreamingHapticHandle: Equatable {
    let store: RenderedMessageStore
    let messageID: UUID
    let row: TranscriptRowVisibility?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.store === rhs.store && lhs.messageID == rhs.messageID && lhs.row == rhs.row
    }

    @MainActor func frame(at time: TimeInterval) {
        guard store.hasPendingWordHaptics(for: messageID) else { return }
        let service = HapticService.shared
        let eligible = row?.isVisible == true && service.canPlayStreaming
        guard eligible else {
            store.dropPendingWordHaptics(for: messageID)
            return
        }
        guard service.admitsStreamingFrame(at: time) else { return }
        if let punch = store.nextStreamingHaptic(for: messageID, at: time) {
            service.playStreaming(punch: punch, at: time)
        }
    }
}

extension EnvironmentValues {
    @Entry var streamingHaptics: StreamingHapticHandle?
}
#endif
