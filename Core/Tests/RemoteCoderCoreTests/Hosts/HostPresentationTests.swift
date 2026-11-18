import Foundation
import Testing
@testable import RemoteCoderCore

struct HostPresentationTests {
    typealias Line = HostPresentation.Line

    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let reach: HostAvailability.Reach
        var tasks = 0
        var seen: Bool = true
        var history: HistoryListFailure? = nil
        var rowLabel: String? = nil
        var strip: Line? = nil
        var status: HostPresentation.DrawerStatus? = nil
        var chat: [Line] = []
        let edge: HostPresentation.Edge
        let held: String
        var testDescription: String { name }
    }

    static let rows: [Row] = [
        Row(name: "connected", reach: .connected(.lan), edge: .connected(.lan), held: ""),
        Row(name: "connected with failed history", reach: .connected(.relay), history: .failed,
            status: .problem("Couldn't load the chats from mac-mini."), edge: .connected(.relay), held: ""),
        Row(name: "connected with partial history", reach: .connected(.configured), history: .partial,
            status: .problem("Some chats from mac-mini couldn't be loaded."), edge: .connected(.configured), held: ""),
        Row(name: "connecting", reach: .connecting, history: .failed, edge: .neutral, held: "Couldn't reach mac-mini"),
        Row(name: "restarting", reach: .restarting, history: .failed, status: .updating("Updating mac-mini…"), edge: .neutral,
            held: "mac-mini is updating"),
        Row(name: "offline", reach: .offline, rowLabel: "offline", chat: [Line(text: "offline · last seen 12:54", tone: .neutral)],
            edge: .neutral, held: "mac-mini is offline"),
        Row(name: "offline never seen", reach: .offline, seen: false, rowLabel: "offline",
            chat: [Line(text: "offline", tone: .neutral)], edge: .neutral, held: "mac-mini is offline"),
        Row(name: "offline with lost work", reach: .offline, tasks: 1, rowLabel: "offline",
            chat: [Line(text: "went offline at 12:54 with 1 task running", tone: .neutral)], edge: .neutral, held: "mac-mini is offline"),
        Row(name: "unreachable", reach: .unreachable, tasks: 2, rowLabel: "offline",
            strip: Line(text: "Can't reach mac-mini since 12:54", tone: .warning),
            chat: [Line(text: "Can't reach mac-mini since 12:54", tone: .warning),
                   Line(text: "went offline at 12:54 with 2 tasks running", tone: .neutral)],
            edge: .warning, held: "Can't reach mac-mini since 12:54"),
        Row(name: "unreachable from here", reach: .unreachableFromHere, rowLabel: "offline",
            strip: Line(text: "Can't reach mac-mini from this phone", tone: .warning),
            chat: [Line(text: "Can't reach mac-mini from this phone", tone: .warning)],
            edge: .warning, held: "Can't reach mac-mini from this phone"),
        Row(name: "credentials rejected", reach: .needsAttention(.credentialsRejected), rowLabel: "offline",
            strip: Line(text: "mac-mini didn't accept this phone's credentials. Add it again in Settings → Hosts.", tone: .warning),
            chat: [Line(text: "mac-mini didn't accept this phone's credentials. Add it again in Settings → Hosts.", tone: .warning)],
            edge: .neutral, held: "mac-mini didn't accept this phone's credentials. Add it again in Settings → Hosts."),
        Row(name: "refused", reach: .needsAttention(.refused), rowLabel: "offline",
            strip: Line(text: "mac-mini refused the connection.", tone: .warning),
            chat: [Line(text: "mac-mini refused the connection.", tone: .warning)],
            edge: .neutral, held: "mac-mini refused the connection."),
    ]

    static func context(now: Date) -> HostPresentation.Context {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return .init(hostName: "mac-mini", device: "phone", now: now, calendar: calendar, locale: Locale(identifier: "en_GB"))
    }

    static let seen = Date(timeIntervalSince1970: 1_763_470_440)

    @Test(arguments: rows) func presentation(_ row: Row) {
        let availability = HostAvailability(reach: row.reach, lastSeen: row.seen ? Self.seen : nil, tasksRunningAtLoss: row.tasks)
        let presentation = HostPresentation(availability, historyFailure: row.history, context: Self.context(now: Self.seen + 600))
        #expect(presentation.rowLabel == row.rowLabel)
        #expect(presentation.strip == row.strip)
        #expect(presentation.drawerStatus == row.status)
        #expect(presentation.chat == row.chat)
        #expect(presentation.edge == row.edge)
        #expect(presentation.sendHeldReason == row.held)
    }

    @Test func anOlderLastSeenNamesTheDay() {
        let availability = HostAvailability(reach: .unreachable, lastSeen: Self.seen, tasksRunningAtLoss: 0)
        let presentation = HostPresentation(availability, historyFailure: nil, context: Self.context(now: Self.seen + 2 * 86_400))
        #expect(presentation.strip?.text == "Can't reach mac-mini since 18 Nov 12:54")
    }
}
