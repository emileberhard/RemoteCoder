struct TargetLifecycle: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case live, quiescing, retired
    }

    enum AppPhase: Equatable, Sendable {
        case active, inactive, background
    }

    enum ForegroundRefresh: Equatable, Sendable {
        case current, deferred
    }

    enum BackgroundHold: Equatable, Sendable {
        case none, assertion, grace, disconnected
    }

    enum Event: Equatable, Sendable {
        case hostPrepared
        case appPhase(AppPhase)
        case presentation(TargetPresentation)
        case activeWorkChanged(count: Int)
        case voiceCall(Bool)
        case graceExpired
        case quiesce, resume, retire
    }

    enum Effect: Equatable, Sendable {
        case startLoops
        case stopLoops
        case refreshForeground(generation: Int)
        case holdAssertion
        case beginGrace
        case endGrace
        case disconnect
        case syncLiveActivity(sticky: Bool)
        case flush
    }

    private(set) var phase = Phase.live
    private(set) var app = AppPhase.active
    private(set) var generation = 0
    private(set) var presentation = TargetPresentation()
    private(set) var activeWorkCount = 0
    private(set) var voiceCallActive = false
    private(set) var foreground = ForegroundRefresh.current
    private(set) var hold = BackgroundHold.none
    private(set) var isBackgrounded = false
    private(set) var backgroundSticky = false

    var isRetired: Bool { phase == .retired }
    var acceptsWork: Bool { phase == .live }
    var isSceneLive: Bool { phase == .live && app == .active }
    var isOnScreen: Bool { isSceneLive && presentation.presented }
    var allowsDisconnect: Bool { isBackgrounded && !voiceCallActive }
    var allowsActivityReads: Bool { phase == .live && !allowsDisconnect }
    var needsGatewayLoops: Bool {
        presentation.presented || presentation.drawerOpen || activeWorkCount > 0 || voiceCallActive
    }

    func isCurrent(_ generation: Int) -> Bool {
        phase == .live && self.generation == generation
    }

    mutating func handle(_ event: Event) -> [Effect] {
        if event == .resume, phase == .quiescing {
            phase = .live
            return enter(.active)
        }
        if event == .retire, phase == .quiescing { return retire() }
        guard phase == .live else { return [] }
        switch event {
        case .hostPrepared: return prepare()
        case .appPhase(let next): return enter(next)
        case .presentation(let next): return present(next)
        case .activeWorkChanged(let count): return changeActiveWork(to: count)
        case .voiceCall(let active): return changeVoiceCall(to: active)
        case .graceExpired: return expireGrace()
        case .quiesce:
            phase = .quiescing
            generation += 1
            isBackgrounded = false
            return [.stopLoops] + releaseHold()
        case .resume: return []
        case .retire: return retire()
        }
    }

    private mutating func prepare() -> [Effect] {
        foreground = needsGatewayLoops ? .current : .deferred
        return []
    }

    private mutating func enter(_ next: AppPhase) -> [Effect] {
        app = next
        generation += 1
        switch next {
        case .active: return activate()
        case .inactive: return deactivate()
        case .background: return background()
        }
    }

    private mutating func activate() -> [Effect] {
        isBackgrounded = false
        var effects: [Effect] = releaseHold()
        effects += [.startLoops, .syncLiveActivity(sticky: backgroundSticky)]
        if needsGatewayLoops {
            foreground = .current
            effects.append(.refreshForeground(generation: generation))
        } else {
            foreground = .deferred
        }
        return effects
    }

    private mutating func deactivate() -> [Effect] {
        var effects: [Effect] = [.stopLoops]
        guard activeWorkCount > 0 else {
            effects.append(.syncLiveActivity(sticky: false))
            return effects
        }
        isBackgrounded = true
        backgroundSticky = true
        if hold == .none {
            hold = .assertion
            effects.append(.holdAssertion)
        }
        effects.append(.syncLiveActivity(sticky: true))
        return effects
    }

    private mutating func background() -> [Effect] {
        isBackgrounded = true
        var effects: [Effect] = [.flush, .stopLoops]
        if voiceCallActive {
            effects += releaseHold()
            effects.append(.syncLiveActivity(sticky: backgroundSticky))
        } else if activeWorkCount > 0 {
            backgroundSticky = true
            effects += beginGraceIfNeeded()
            effects.append(.syncLiveActivity(sticky: true))
        } else {
            effects.append(.syncLiveActivity(sticky: backgroundSticky))
            effects += disconnectIfNeeded()
        }
        return effects
    }

    private mutating func present(_ next: TargetPresentation) -> [Effect] {
        let previous = presentation
        presentation = next
        guard next.presented, !previous.presented, foreground == .deferred, app == .active, !isBackgrounded else {
            return []
        }
        foreground = .current
        return [.refreshForeground(generation: generation)]
    }

    private mutating func changeActiveWork(to count: Int) -> [Effect] {
        precondition(count >= 0, "active work count cannot be negative")
        let previous = activeWorkCount
        activeWorkCount = count
        guard count != previous else { return [] }
        if count == 0 { backgroundSticky = false }
        var effects: [Effect] = [.syncLiveActivity(sticky: backgroundSticky)]
        guard allowsDisconnect else { return effects }
        effects += count == 0 ? disconnectIfNeeded() : beginGraceIfNeeded()
        return effects
    }

    private mutating func changeVoiceCall(to active: Bool) -> [Effect] {
        guard voiceCallActive != active else { return [] }
        voiceCallActive = active
        if active { return releaseHold() }
        return isBackgrounded ? disconnectIfNeeded() : []
    }

    private mutating func expireGrace() -> [Effect] {
        guard hold == .assertion || hold == .grace else { return [] }
        return allowsDisconnect ? disconnectIfNeeded() : releaseHold()
    }

    private mutating func retire() -> [Effect] {
        phase = .retired
        generation += 1
        isBackgrounded = false
        var effects: [Effect] = [.flush, .stopLoops]
        effects += releaseHold()
        return effects
    }

    private mutating func releaseHold() -> [Effect] {
        defer { hold = .none }
        return hold == .assertion || hold == .grace ? [.endGrace] : []
    }

    private mutating func beginGraceIfNeeded() -> [Effect] {
        guard hold != .grace else { return [] }
        hold = .grace
        return [.beginGrace]
    }

    private mutating func disconnectIfNeeded() -> [Effect] {
        guard hold != .disconnected else { return [] }
        hold = .disconnected
        return [.disconnect]
    }
}
