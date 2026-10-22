import Foundation
import Testing

@testable import RemoteCoderCore

/// A row reports the gap between one agent output and the next — never the whole turn.
struct JobTimelineSpanTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(_ offset: TimeInterval?) -> JobTimelineEvent {
        let label: String = offset.map { "\($0)" } ?? "none"
        return JobTimelineEvent(
            id: "e-\(label)",
            sequence: 1,
            kind: .toolCall,
            title: "t",
            subtitle: nil,
            timestamp: offset.map { Self.base.addingTimeInterval($0) },
            details: []
        )
    }

    @Test(arguments: [
        (5, [90], 5),
        (nil, [90, 30], 30),
        (nil, [nil], nil),
    ] as [(TimeInterval?, [TimeInterval?], TimeInterval?)])
    func startPrefersThePrecedingMessageThenTheFirstEvent(
        preceding: TimeInterval?, events: [TimeInterval?], expected: TimeInterval?
    ) {
        #expect(JobTimelineSpan.startedAt(
            precedingMessageDate: preceding.map { Self.base.addingTimeInterval($0) },
            events: events.map(event)
        ) == expected.map { Self.base.addingTimeInterval($0) })
    }

    @Test(arguments: [
        (120, [90], false, 120),
        (nil, [30, 90], false, 90),
        (120, [90], true, nil),
    ] as [(TimeInterval?, [TimeInterval?], Bool, TimeInterval?)])
    func endPrefersTheFollowingMessageUnlessTheSegmentRuns(
        following: TimeInterval?, events: [TimeInterval?], isRunning: Bool, expected: TimeInterval?
    ) {
        #expect(JobTimelineSpan.completedAt(
            followingMessageDate: following.map { Self.base.addingTimeInterval($0) },
            events: events.map(event),
            isRunning: isRunning
        ) == expected.map { Self.base.addingTimeInterval($0) })
    }

    @Test(arguments: [
        (0, nil, nil),
        // Reconstructed messages can share a stamp; "0s" is noise, not information.
        (0, 0.4, nil),
        (0, 74, 74),
        (60, 0, nil),
    ] as [(TimeInterval, TimeInterval?, TimeInterval?)])
    func durationRequiresAnOrderedWholeSecondSpan(
        start: TimeInterval, end: TimeInterval?, expected: TimeInterval?
    ) {
        #expect(JobTimelineSpan.displayDuration(
            startedAt: Self.base.addingTimeInterval(start),
            completedAt: end.map { Self.base.addingTimeInterval($0) }
        ) == expected)
    }
}
