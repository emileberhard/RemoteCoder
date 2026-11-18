import Foundation

struct HostPresentation: Sendable, Equatable {
    enum Tone: Sendable, Equatable {
        case neutral
        case warning
    }

    struct Line: Sendable, Equatable {
        let text: String
        let tone: Tone
    }

    enum Edge: Sendable, Equatable {
        case connected(GatewayRoute.Kind)
        case neutral
        case warning

        var route: GatewayRoute.Kind? {
            if case .connected(let route) = self { route } else { nil }
        }
    }

    enum DrawerStatus: Sendable, Equatable {
        case updating(String)
        case problem(String)
    }

    let rowLabel: String?
    let strip: Line?
    let drawerStatus: DrawerStatus?
    let chat: [Line]
    let edge: Edge
    let sendHeldReason: String

    struct Context: Sendable {
        let hostName: String
        let device: String
        let now: Date
        let calendar: Calendar
        let locale: Locale

        static func current(hostName: String, device: String) -> Self {
            Self(hostName: hostName, device: device, now: .now, calendar: .current, locale: .current)
        }
    }

    init(_ availability: HostAvailability, historyFailure: HistoryListFailure?, context: Context) {
        let host = context.hostName
        let seen = availability.lastSeen.map { Self.time($0, context: context) }
        let lostWork: String? = if availability.tasksRunningAtLoss > 0 {
            "went offline\(seen.map { " at \($0)" } ?? "") with \(availability.tasksRunningAtLoss) task\(availability.tasksRunningAtLoss == 1 ? "" : "s") running"
        } else { nil }
        let offline = seen.map { "offline · last seen \($0)" } ?? "offline"

        switch availability.reach {
        case .connected(let route):
            rowLabel = nil
            strip = nil
            drawerStatus = historyFailure.map { .problem(Self.words(for: $0, host: host)) }
            chat = []
            edge = .connected(route)
            sendHeldReason = ""
        case .connecting:
            rowLabel = nil
            strip = nil
            drawerStatus = nil
            chat = []
            edge = .neutral
            sendHeldReason = "Couldn't reach \(host)"
        case .restarting:
            rowLabel = nil
            strip = nil
            drawerStatus = .updating("Updating \(host)…")
            chat = []
            edge = .neutral
            sendHeldReason = "\(host) is updating"
        case .offline:
            rowLabel = "offline"
            strip = nil
            drawerStatus = nil
            chat = [Line(text: lostWork ?? offline, tone: .neutral)]
            edge = .neutral
            sendHeldReason = "\(host) is offline"
        case .unreachable:
            let words = seen.map { "Can't reach \(host) since \($0)" } ?? "Can't reach \(host)"
            rowLabel = "offline"
            strip = Line(text: words, tone: .warning)
            drawerStatus = nil
            chat = [Line(text: words, tone: .warning)] + (lostWork.map { [Line(text: $0, tone: .neutral)] } ?? [])
            edge = .warning
            sendHeldReason = words
        case .unreachableFromHere:
            let words = "Can't reach \(host) from this \(context.device)"
            rowLabel = "offline"
            strip = Line(text: words, tone: .warning)
            drawerStatus = nil
            chat = [Line(text: words, tone: .warning)] + (lostWork.map { [Line(text: $0, tone: .neutral)] } ?? [])
            edge = .warning
            sendHeldReason = words
        case .needsAttention(let cause):
            let words = switch cause {
            case .credentialsRejected: "\(host) didn't accept this \(context.device)'s credentials. Add it again in Settings → Hosts."
            case .refused: "\(host) refused the connection."
            }
            rowLabel = "offline"
            strip = Line(text: words, tone: .warning)
            drawerStatus = nil
            chat = [Line(text: words, tone: .warning)]
            edge = .neutral
            sendHeldReason = words
        }
    }

    private static func words(for failure: HistoryListFailure, host: String) -> String {
        switch failure {
        case .partial: "Some chats from \(host) couldn't be loaded."
        case .failed: "Couldn't load the chats from \(host)."
        }
    }

    private static func time(_ date: Date, context: Context) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: context.locale, calendar: context.calendar)
        style.timeZone = context.calendar.timeZone
        guard !context.calendar.isDate(date, inSameDayAs: context.now) else { return date.formatted(style) }
        var day = Date.FormatStyle(locale: context.locale, calendar: context.calendar).day().month(.abbreviated)
        day.timeZone = context.calendar.timeZone
        return "\(date.formatted(day)) \(date.formatted(style))"
    }
}
