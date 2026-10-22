import AVFoundation
import Foundation
@preconcurrency import LiveCommunicationKit
import Observation
import OSLog
@preconcurrency import WebRTC

@Observable
@MainActor
final class VoiceCall {
    typealias State = RealtimeVoiceLifecycle.State

    private enum VoiceError: LocalizedError {
        case emptyVoiceCatalog
        case remoteSDPTimedOut
        case audioActivationTimedOut
        case reconnectFailed

        var errorDescription: String? {
            switch self {
            case .emptyVoiceCatalog:
                "The gateway returned an empty realtime voice catalog."
            case .remoteSDPTimedOut:
                "OpenAI did not answer the realtime audio connection in time."
            case .audioActivationTimedOut:
                "iOS did not start the call audio. If Try Again fails too, force-quit RemoteCoder."
            case .reconnectFailed:
                "The voice connection could not be restored. Tap to reconnect."
            }
        }
    }

    private static let selectedVoiceKey = "realtimeVoice.selectedVoice"
    static let syncedPreferenceKeys: Set<String> = [selectedVoiceKey]
    private static let audioActivationDeadline: Duration = .seconds(5)
    private let logger = Logger(subsystem: "RemoteCoder", category: "RealtimeVoice")
    private let diagnosticID: String
    private let systemBridge: CallSystemBridge
    let audioRoute = CallAudioRoute()
    private weak var model: (any VoiceCallHost)?
    /// The host whose thread the live call is bound to. The voice surface, its
    /// settings and its retirement all follow the owner, not whichever host the
    /// sidebar selected while the call was already up.
    private(set) var callOwner: ExecutionTarget?
    /// Captured from the model that started the call: an existing call keeps
    /// writing to its own host's transcript store even after the sidebar
    /// selection moves to another host.
    private var voiceHistoryStore: RealtimeVoiceHistoryStore?
    private var gateway: GatewayClient?
    private var webRTCSession: RealtimeWebRTCSession?
    private var notificationTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var remoteSDPTimeoutTask: Task<Void, Never>?
    private var audioActivationDeadlineTask: Task<Void, Never>?
    private var realtimeThreadID: String?
    private var realtimeSessionID: String?
    private var conversationThreadID: String?
    private var provisionalConversationThreadID: String?
    private var lifecycle = RealtimeVoiceLifecycle()
    private var transcriptState = RealtimeVoiceTranscriptState()
    private var systemStartTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var teardownTask: Task<Void, Never>?
    private let orphanedLiveActivityCleanup: Task<Void, Never>
    private var liveActivity: VoiceCallLiveActivity?
    private var callEndWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var conversationContext: RealtimeVoiceConversationContext?
    private var acknowledgedSettings: ConversationSettingsUpdate?
    private var acknowledgedModelAndEffortSuperseded = false
    private var acknowledgedFastModeSuperseded = false
    private var incomingSettingsGeneration: UInt64 = 0

    func applyConversationSettings(_ settings: ConversationSettingsUpdate, hostID: UUID) {
        guard callOwner == ExecutionTarget(hostID: hostID),
              conversationContext?.threadID == settings.threadId ||
                (conversationContext == nil &&
                 (incomingCall == nil ? model?.activeSessionID : (conversationThreadID ?? model?.activeSessionID)) == settings.threadId) else { return }
        acknowledgedSettings = settings
        acknowledgedModelAndEffortSuperseded = false
        acknowledgedFastModeSuperseded = false
        if incomingCall != nil { incomingSettingsGeneration &+= 1 }
        if let context = conversationContext { conversationContext = context.applying(settings) }
    }

    func incomingSettingsRevision(for context: RealtimeVoiceConversationContext,
                                  hostID: UUID) -> UInt64? {
        guard ownsIncomingConversation(context, hostID: hostID),
              conversationThreadID == context.threadID else { return nil }
        return incomingSettingsGeneration
    }

    func publishConversationContext(_ context: RealtimeVoiceConversationContext) -> RealtimeVoiceConversationContext {
        var context = context
        if let acknowledgedSettings, acknowledgedSettings.threadId == context.threadID {
            context = context.applying(acknowledgedSettings,
                modelAndEffort: !acknowledgedModelAndEffortSuperseded,
                fastMode: !acknowledgedFastModeSuperseded)
        }
        conversationContext = context
        return context
    }

    func prepareIncomingConversationContext(
        _ context: RealtimeVoiceConversationContext, using model: any VoiceCallHost,
        gateway: GatewayClient,
        readThread: @escaping @Sendable (String) async throws -> CodexAppServerV2.ThreadReadResponse
    ) async -> RealtimeVoiceConversationContext {
        guard ownsIncomingConversation(context, hostID: model.hostID) else {
            return context
        }
        conversationThreadID = context.threadID
        let generation = incomingSettingsGeneration
        let result = await model.readIncomingVoiceSettings(context, using: gateway,
            ownsCall: { self.ownsIncomingConversation(context, hostID: model.hostID) },
            readThread: readThread)
        guard ownsIncomingConversation(context, hostID: model.hostID),
              conversationThreadID == context.threadID else { return context }
        supersedeIncomingAcknowledgement(threadID: context.threadID, generation: generation,
            modelAndEffort: result.readModelAndEffort, fastMode: result.readFastMode)
        return result.context
    }

    private func supersedeIncomingAcknowledgement(threadID: String, generation: UInt64,
                                                   modelAndEffort: Bool, fastMode: Bool) {
        guard incomingCall != nil, conversationThreadID == threadID,
              incomingSettingsGeneration == generation,
              acknowledgedSettings?.threadId == threadID else { return }
        acknowledgedModelAndEffortSuperseded = acknowledgedModelAndEffortSuperseded || modelAndEffort
        acknowledgedFastModeSuperseded = acknowledgedFastModeSuperseded || fastMode
        if acknowledgedModelAndEffortSuperseded && acknowledgedFastModeSuperseded {
            acknowledgedSettings = nil
        }
    }

    func publishIncomingAnswerContext(_ context: RealtimeVoiceConversationContext,
                                      model: String, effort: String?, settingsGeneration: UInt64)
        -> RealtimeVoiceConversationContext {
        var context = context
        context.model = model
        context.effort = effort
        supersedeIncomingAcknowledgement(threadID: context.threadID, generation: settingsGeneration,
            modelAndEffort: true, fastMode: false)
        return publishConversationContext(context)
    }

    func acceptConversationReadback(threadID: String, realtimeSessionID: String, hostID: UUID) {
        guard callOwner == ExecutionTarget(hostID: hostID),
              conversationContext?.threadID == threadID,
              conversationContext?.realtimeSessionID == realtimeSessionID,
              acknowledgedSettings?.threadId == threadID else { return }
        acknowledgedSettings = nil
        acknowledgedModelAndEffortSuperseded = false
        acknowledgedFastModeSuperseded = false
    }

    func ownsIncomingConversation(_ context: RealtimeVoiceConversationContext, hostID: UUID) -> Bool {
        callOwner == ExecutionTarget(hostID: hostID)
            && incomingCall?.push.callId.uuidString.lowercased() == context.realtimeSessionID
    }
    private var pendingRemoteSDP: [String: String] = [:]
    private var reconnectAttempts = 0
    private var reconnectRequiresReplacement = false
    private var hasReportedConnected = false
    private var systemAudioSessionIsActive = false
    private struct IncomingCall {
        let push: AgentCallPush
        let deviceID: String
        var answered = false
    }
    private var incomingCall: IncomingCall?
    private var incomingMonitorTask: Task<Void, Never>?
    private var incomingExpiryTask: Task<Void, Never>?
    private var incomingConnectedTask: Task<Void, Never>?
    private var hasReportedIncomingConnected = false
    private var greetingTask: Task<Void, Never>?

    var state: State { lifecycle.state }
    var transcript: [RealtimeVoiceTranscriptEntry] { transcriptState.entries }
    var liveUserText: String { transcriptState.liveUserText }
    var liveAssistantText: String { transcriptState.liveAssistantText }
    var voices: [String] = []
    private(set) var voiceCatalogError: String?
    private var chosenVoice: String?
    var selectedVoice: String? {
        get { chosenVoice }
        set {
            chosenVoice = newValue
            AppStorageScope.current.defaults.set(newValue, forKey: Self.selectedVoiceKey)
        }
    }
    var effectiveVoice: String? {
        selectedVoice.flatMap { voices.contains($0) ? $0 : nil } ?? voices.first
    }
    private(set) var isMuted = false

    var isActive: Bool { lifecycle.isActive }

    func isActive(for owner: ExecutionTarget) -> Bool {
        isActive && callOwner == owner
    }

    var liveCallID: UUID? { lifecycle.isActive ? lifecycle.callID : nil }

    private func updateLifecycle(_ state: State, connectionID: UUID) {
        guard lifecycle.state != state else { return }
        lifecycle.update(state, connectionID: connectionID)
    }

    func refreshVoiceCatalog(using model: any VoiceCallHost) async {
        do {
            let gateway = model.gatewayClient
            try await gateway.connectIfNeeded()
            try await loadVoiceCatalog(from: gateway)
        } catch {
            voiceCatalogError = error.localizedDescription
            logger.error("voice catalog refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    init() {
        let diagnosticID = String(UUID().uuidString.prefix(8))
        self.diagnosticID = diagnosticID
        systemBridge = CallSystemBridge(diagnosticID: diagnosticID)
        orphanedLiveActivityCleanup = Task { await VoiceCallLiveActivity.endOrphans() }
        chosenVoice = AppStorageScope.current.defaults.string(forKey: Self.selectedVoiceKey)
        systemBridge.delegate = self
    }

    func reloadSelectedVoice() {
        let stored = AppStorageScope.current.defaults.string(forKey: Self.selectedVoiceKey)
        if stored != chosenVoice { chosenVoice = stored }
    }

    func receiveIncoming(
        push: AgentCallPush?, model: (any VoiceCallHost)?, deviceID: String, mustReport: Bool
    ) async {
        let reportID = push?.callId ?? UUID()
        // Duplicate pushes may still carry a reporting obligation. Never end the live UUID.
        if lifecycle.callID == reportID {
            if mustReport { try? await systemBridge.reportIncoming(callID: reportID) }
            return
        }
        guard let push, push.isCurrent(at: .now), let model,
              AVAudioApplication.shared.recordPermission == .granted,
              lifecycle.receiveIncoming(callID: push.callId) else {
            AgentCallDiagnostics.record(
                "incomingRejected", callID: push?.callId, hostID: push?.hostId,
                detail: "current=\(push?.isCurrent(at: .now) == true) hostFound=\(model != nil) microphone=\(AVAudioApplication.shared.recordPermission.rawValue) occupied=\(lifecycle.callID != nil)", error: nil
            )
            if let push, let model {
                Task { @MainActor [logger] in
                    do {
                        try await model.gatewayClient.endIncomingCall(
                            callID: push.callId, deviceID: deviceID, reason: "failed"
                        )
                    } catch {
                        logger.notice("Rejected call could not reach its gateway: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            guard mustReport else { return }
            do {
                try await systemBridge.reportIncoming(callID: reportID)
                systemBridge.reportEnded(callID: reportID, reason: .failed)
            } catch {
                logger.notice("Unusable incoming call report rejected: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        bindIncomingSettingsOwner(push: push, model: model, deviceID: deviceID)
        voiceHistoryStore = model.voiceHistoryStore
        transcriptState.reset()
        hasReportedConnected = false
        hasReportedIncomingConnected = false
        model.setVoiceModeActive(true)
        AgentCallDiagnostics.record("reportIncomingStarted", callID: push.callId, hostID: push.hostId, detail: "", error: nil)
        do {
            // Audio is armed but disabled before iOS can deliver an answer/activation callback.
            try configureWebRTCAudioSession()
            audioRoute.startListening()
            try await systemBridge.reportIncoming(callID: push.callId)
            AgentCallDiagnostics.record("reportIncomingAccepted", callID: push.callId, hostID: push.hostId, detail: "", error: nil)
            guard lifecycle.isCurrentCall(push.callId) else {
                systemBridge.reportEnded(callID: push.callId, reason: .failed)
                return
            }
            startIncomingMonitor(push: push, deviceID: deviceID, gateway: model.gatewayClient)
            incomingExpiryTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(max(0, push.expiresAt - Date().timeIntervalSince1970))) }
                catch { return }
                guard let self, self.lifecycle.isCurrentCall(push.callId),
                      self.incomingCall?.answered == false else { return }
                await self.failSession(AgentIncomingCallError.unavailable)
            }
        } catch {
            guard lifecycle.isCurrentCall(push.callId) else { return }
            AgentCallDiagnostics.record("reportIncomingFailed", callID: push.callId, hostID: push.hostId, detail: "", error: error)
            Task { @MainActor [weak self] in
                guard let self, self.lifecycle.isCurrentCall(push.callId) else { return }
                await self.failSession(error)
            }
        }
    }

    func bindIncomingSettingsOwner(push: AgentCallPush, model: any VoiceCallHost, deviceID: String) {
        incomingCall = IncomingCall(push: push, deviceID: deviceID)
        self.model = model
        callOwner = ExecutionTarget(hostID: model.hostID)
        gateway = model.gatewayClient
        conversationThreadID = nil
        conversationContext = nil
        acknowledgedSettings = nil
        acknowledgedModelAndEffortSuperseded = false
        acknowledgedFastModeSuperseded = false
        incomingSettingsGeneration = 0
    }

    func clearIncomingSettingsOwner(callID: UUID) {
        guard incomingCall?.push.callId == callID else { return }
        incomingCall = nil
        conversationThreadID = nil
        conversationContext = nil
        acknowledgedSettings = nil
        acknowledgedModelAndEffortSuperseded = false
        acknowledgedFastModeSuperseded = false
        callOwner = nil
        model = nil
        gateway = nil
    }

    private func startIncomingMonitor(push: AgentCallPush, deviceID: String, gateway: GatewayClient) {
        incomingMonitorTask = Task { @MainActor [weak self] in
            do {
                try await gateway.connectIfNeeded()
                guard let self, self.lifecycle.isCurrentCall(push.callId) else { return }
                let stream = await gateway.notifications()
                guard !Task.isCancelled, self.lifecycle.isCurrentCall(push.callId) else { return }
                if self.incomingCall?.answered == false {
                    try await gateway.reportIncomingCallRinging(callID: push.callId, deviceID: deviceID)
                    AgentCallDiagnostics.record("gatewayRingingAcknowledged", callID: push.callId, hostID: push.hostId, detail: "", error: nil)
                }
                let status = try await gateway.incomingCallStatus(callID: push.callId)
                guard self.lifecycle.isCurrentCall(push.callId) else { return }
                if status.state.isTerminal || status.state == .ending { await self.endAsAgentEnded(); return }
                for await notification in stream {
                    guard !Task.isCancelled, self.lifecycle.isCurrentCall(push.callId) else { return }
                    guard case .callChanged(let change) = notification.server else { continue }
                    if change.callId == push.callId && (change.state.isTerminal || change.state == .ending) {
                        await self.endAsAgentEnded()
                        return
                    }
                }
                guard !Task.isCancelled, self.lifecycle.isCurrentCall(push.callId) else { return }
                await self.failSession(AgentIncomingCallError.unavailable)
            } catch {
                guard !Task.isCancelled, let self, self.lifecycle.isCurrentCall(push.callId) else { return }
                await self.failSession(error)
            }
        }
    }

    func start(
        using model: any VoiceCallHost,
        resuming context: RealtimeVoiceConversationContext? = nil
    ) async {
        if let teardownTask { await teardownTask.value }
        let callID = UUID()
        guard lifecycle.start(callID: callID) else { return }
        await begin(callID, using: model, resuming: context)
    }

    func startWithLiveActivity(using model: any VoiceCallHost, hostName: String) async throws {
        await orphanedLiveActivityCleanup.value
        while let teardownTask { await teardownTask.value }
        let callID = lifecycle.callID ?? UUID()
        if liveActivity?.isOngoing != true { liveActivity = try .request(callID: callID, hostName: hostName) }
        guard lifecycle.start(callID: callID) else { return }
        await begin(callID, using: model, resuming: nil)
    }

    private func begin(_ callID: UUID, using model: any VoiceCallHost, resuming context: RealtimeVoiceConversationContext?) async {
        diagnostic("start requested call=\(callID)")
        self.model = model
        callOwner = ExecutionTarget(hostID: model.hostID)
        gateway = model.gatewayClient
        voiceHistoryStore = model.voiceHistoryStore
        conversationContext = context
        acknowledgedSettings = nil
        acknowledgedModelAndEffortSuperseded = false
        acknowledgedFastModeSuperseded = false
        reconnectAttempts = 0
        hasReportedConnected = false
        transcriptState.reset()
        model.setVoiceModeActive(true)

        // Startup belongs to the call, so minimizing the SwiftUI cover cannot cancel it.
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.startSystemConversation(callID: callID)
        }
        systemStartTask = task
        await task.value
    }

    private func startSystemConversation(callID: UUID) async {
        do {
            try await VoiceInputPermissions.requestMicrophoneAccess()
            guard lifecycle.isCurrentCall(callID) else { return }
            try Task.checkCancellation()
            try configureWebRTCAudioSession()
            audioRoute.startListening()

            diagnostic("performing outgoing system conversation action")
            try await systemBridge.startOutgoing(callID: callID)
            guard lifecycle.isCurrentCall(callID) else { return }
            diagnostic("outgoing system conversation action accepted")
        } catch {
            guard lifecycle.isCurrentCall(callID) else { return }
            await failSession(error)
        }
    }

    func stop() async {
        if let teardownTask {
            await teardownTask.value
            return
        }
        guard let callID = lifecycle.callID else { return }
        // Permission may still be pending and no system conversation exists yet.
        guard systemBridge.hasConversation(callID) else {
            await tearDown()
            return
        }
        do {
            try await systemBridge.requestEnd(callID: callID)
        } catch {
            guard lifecycle.callID == callID else { return }
            await failSession(error)
        }
        // perform() accepts an action; the delegate completes the actual teardown.
        if lifecycle.callID == callID {
            await withCheckedContinuation { callEndWaiters.append($0) }
        }
    }

    func retry() async {
        guard let model else { return }
        let context = model.gatewayClient === gateway ? conversationContext : nil
        await stop()
        await start(using: model, resuming: context)
    }

    func toggleMute() async {
        guard isActive, let conversationUUID = lifecycle.callID else { return }
        do {
            try await systemBridge.requestMute(!isMuted, callID: conversationUUID)
        } catch {
            guard lifecycle.isCurrentCall(conversationUUID) else { return }
            logger.error("system mute action failed: \(error.localizedDescription, privacy: .public)")
            await failSession(error)
        }
    }

    private func handleStartAction(_ action: StartConversationAction) async {
        diagnostic("received system start action")
        guard lifecycle.isCurrentCall(action.conversationUUID) else {
            action.fail()
            return
        }

        systemBridge.reportStartedConnecting(callID: action.conversationUUID)
        action.fulfill(dateStarted: .now)
        scheduleAudioActivationDeadline(callID: action.conversationUUID)
        guard connectionTask == nil else { return }
        connectionTask = Task { @MainActor [weak self] in
            await self?.connect(callID: action.conversationUUID)
        }
    }

    private func handleEndAction(_ action: EndConversationAction) async {
        guard action.conversationUUID == lifecycle.callID else {
            action.fulfill(dateEnded: .now)
            return
        }

        // Fulfill before the teardown: tearDown awaits a gateway RPC, and
        // holding the system action across a stalled link gets it timed out
        // and reported as a failed hang-up. The gateway drains on client
        // disconnect regardless.
        action.fulfill(dateEnded: .now)
        await tearDown()
    }

    private func handleJoinAction(_ action: JoinConversationAction) async {
        guard lifecycle.isCurrentCall(action.conversationUUID),
              let incomingCall, incomingCall.push.isCurrent(at: .now),
              AVAudioApplication.shared.recordPermission == .granted else {
            action.fail()
            if lifecycle.isCurrentCall(action.conversationUUID) { await failSession(AgentIncomingCallError.unavailable) }
            return
        }
        guard !incomingCall.answered else { action.fulfill(dateConnected: .now); return }
        self.incomingCall?.answered = true
        incomingExpiryTask?.cancel()
        incomingExpiryTask = nil
        // Fulfilling lets the system activate audio; media readiness is acknowledged separately.
        action.fulfill(dateConnected: .now)
        scheduleAudioActivationDeadline(callID: action.conversationUUID)
        guard connectionTask == nil else { return }
        connectionTask = Task { @MainActor [weak self] in
            await self?.connect(callID: action.conversationUUID)
        }
    }

    private func handleMuteAction(_ action: MuteConversationAction) {
        guard lifecycle.isCurrentCall(action.conversationUUID) else {
            action.fail()
            return
        }

        isMuted = action.isMuted
        webRTCSession?.setInputEnabled(!action.isMuted && systemAudioSessionIsActive)
        action.fulfill()
    }

    private func connect(callID: UUID) async {
        guard let model, let gateway,
              let connectionID = lifecycle.beginConnection(
                callID: callID, reconnecting: reconnectAttempts > 0
              )
        else { return }
        defer {
            if lifecycle.ownsConnection(connectionID) { connectionTask = nil }
        }

        reconnectRequiresReplacement = false
        diagnostic("connecting call=\(callID) connection=\(connectionID)")
        do {
            try await gateway.connectIfNeeded()
            guard lifecycle.isCurrentConnection(connectionID) else { return }
            await startNotificationListener(gateway: gateway, connectionID: connectionID)
            guard lifecycle.isCurrentConnection(connectionID) else { return }

            let session = RealtimeWebRTCSession()
            session.onICEConnectionStateChange = { [weak self] state in
                guard let self, self.lifecycle.isCurrentConnection(connectionID) else { return }
                VoiceModeDiagnostics.log("realtime ICE connection state=\(state.rawValue)")
                switch state {
                case .connected, .completed:
                    self.markConnected(connectionID: connectionID)
                case .failed:
                    self.scheduleReconnect(connectionID: connectionID)
                case .disconnected:
                    self.scheduleReconnect(connectionID: connectionID, allowsMediaRecovery: true)
                default:
                    break
                }
            }
            webRTCSession = session
            async let voiceCatalog: Void = loadVoiceCatalog(from: gateway)
            let inputEnabled = !isMuted && systemAudioSessionIsActive
            async let pendingOffer = session.createOffer(
                inputEnabled: inputEnabled
            )
            diagnostic("preparing conversation context")
            var context: RealtimeVoiceConversationContext
            if let incomingCall {
                let status = try await gateway.incomingCallStatus(callID: incomingCall.push.callId)
                context = try status.voiceContext(for: incomingCall.push, at: .now)
                context = await prepareIncomingConversationContext(context, using: model, gateway: gateway,
                    readThread: { try await gateway.readThreadForIncomingCall(threadID: $0) })
            } else if let conversationContext {
                context = try await model.refreshRealtimeVoiceConversation(
                    conversationContext, using: gateway
                )
            } else {
                context = try await model.prepareRealtimeVoiceConversation()
            }
            guard lifecycle.isCurrentConnection(connectionID) else { return }
            context = publishConversationContext(context)
            realtimeSessionID = context.realtimeSessionID
            provisionalConversationThreadID = context.isProvisionalThread ? context.threadID : nil
            conversationThreadID = context.threadID
            let offer = try await pendingOffer
            try await voiceCatalog
            guard lifecycle.isCurrentConnection(connectionID) else { return }
            try Task.checkCancellation()
            context = publishConversationContext(context)
            diagnostic("starting realtime thread=\(context.threadID) model=\(context.model) effort=\(context.effort ?? "automatic")")
            let response: RealtimeVoiceStartResponse
            let answerSettingsGeneration = incomingSettingsGeneration
            if let incomingCall {
                response = try await gateway.answerIncomingCall(
                    callID: incomingCall.push.callId, deviceID: incomingCall.deviceID,
                    sdp: offer, voice: effectiveVoice
                )
            } else {
                response = try await gateway.startRealtimeVoiceSession(
                    conversationThreadID: context.threadID,
                    realtimeSessionID: context.realtimeSessionID,
                    replaceExistingSession: reconnectAttempts == 0,
                    model: context.model,
                    effort: context.effort,
                    cwd: context.cwd,
                    sdp: offer,
                    voice: effectiveVoice,
                    initialItems: context.initialItems
                )
            }
            guard lifecycle.isCurrentConnection(connectionID) else { return }
            if incomingCall != nil {
                context = publishIncomingAnswerContext(context, model: response.model,
                    effort: response.effort, settingsGeneration: answerSettingsGeneration)
            } else {
                context.model = response.model
                context.effort = response.effort
                context = publishConversationContext(context)
            }
            let threadID = response.realtimeThreadID
            realtimeThreadID = threadID
            diagnostic("realtime session started; waiting for remote SDP")
            scheduleRemoteSDPTimeout(for: connectionID)
            if let sdp = pendingRemoteSDP.removeValue(forKey: threadID) {
                try await applyRemoteSDP(sdp, connectionID: connectionID)
            }
        } catch {
            guard lifecycle.isCurrentConnection(connectionID) else { return }
            if let failure = error as? GatewayRPCFailure, failure.kind == .voiceCallEnded {
                await endAsAgentEnded()
            } else {
                await failSession(error)
            }
        }
    }

    private func startNotificationListener(
        gateway: GatewayClient, connectionID: UUID
    ) async {
        notificationTask?.cancel()
        let stream = await gateway.notifications()
        guard lifecycle.isCurrentConnection(connectionID) else { return }
        let target = WeakController(value: self)
        notificationTask = Task(name: "Realtime voice gateway notifications") {
            await Self.pumpNotifications(stream, target: target, connectionID: connectionID)
        }
    }

    private struct WeakController: Sendable {
        weak var value: VoiceCall?
    }

    @concurrent
    private nonisolated static func pumpNotifications(
        _ stream: AsyncStream<CodexGatewayNotification>, target: WeakController, connectionID: UUID
    ) async {
        for await notification in stream {
            guard !Task.isCancelled else { return }
            let decoded: Result<RealtimeVoiceNotification, any Error>
            do {
                guard let realtime = try RealtimeVoiceNotification(notification) else { continue }
                decoded = .success(realtime)
            } catch {
                decoded = .failure(error)
            }
            guard let controller = target.value,
                  await controller.receive(decoded, connectionID: connectionID) else { return }
        }
        guard !Task.isCancelled else { return }
        await target.value?.scheduleReconnect(connectionID: connectionID)
    }

    private func receive(
        _ decoded: Result<RealtimeVoiceNotification, any Error>, connectionID: UUID
    ) async -> Bool {
        guard lifecycle.ownsConnection(connectionID) else { return false }
        switch decoded {
        case .success(let notification):
            await handle(notification, connectionID: connectionID)
        case .failure(let error):
            if lifecycle.isCurrentConnection(connectionID) { await failSession(error) }
        }
        return true
    }

    private func loadVoiceCatalog(from gateway: GatewayClient) async throws {
        let availableVoices = try await gateway.listRealtimeVoices()
        try Task.checkCancellation()
        guard !availableVoices.isEmpty else {
            throw VoiceError.emptyVoiceCatalog
        }
        voices = availableVoices
        voiceCatalogError = nil
        diagnostic("voice catalog loaded count=\(availableVoices.count)")
    }

    private func scheduleReconnect(connectionID: UUID, allowsMediaRecovery: Bool = false) {
        guard lifecycle.isCurrentConnection(connectionID) else { return }
        if incomingCall != nil {
            Task { @MainActor [weak self] in
                guard let self, self.lifecycle.isCurrentConnection(connectionID) else { return }
                await self.failSession(AgentIncomingCallError.unavailable)
            }
            return
        }
        reconnectRequiresReplacement = reconnectRequiresReplacement || !allowsMediaRecovery
        guard reconnectTask == nil else { return }
        updateLifecycle(.reconnecting, connectionID: connectionID)
        reconnectTask = Task(name: "Realtime voice reconnect") { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, self.lifecycle.isCurrentConnection(connectionID),
                  let callID = self.lifecycle.callID
            else { return }
            self.reconnectTask = nil
            guard self.reconnectAttempts == 0 else {
                await self.failSession(VoiceError.reconnectFailed)
                return
            }
            self.reconnectAttempts += 1
            self.connectionTask?.cancel()
            self.closePeerConnection()
            self.realtimeThreadID = nil
            self.pendingRemoteSDP.removeAll(keepingCapacity: true)
            self.connectionTask = Task { @MainActor [weak self] in
                await self?.connect(callID: callID)
            }
        }
    }

    private func handle(_ realtimeNotification: RealtimeVoiceNotification, connectionID: UUID) async {
        switch realtimeNotification {
        case .sdp(let event):
            guard lifecycle.isCurrentConnection(connectionID) else { return }
            if event.threadID == realtimeThreadID {
                do {
                    try await applyRemoteSDP(event.sdp, connectionID: connectionID)
                } catch {
                    if lifecycle.isCurrentConnection(connectionID) { await failSession(error) }
                }
            } else {
                pendingRemoteSDP[event.threadID] = event.sdp
            }

        case .transcriptDelta(let event):
            guard event.threadID == realtimeThreadID else { return }
            guard transcriptState.append(delta: event.delta, role: event.role) else { return }
            updateLifecycle(event.role == .user ? .listening : .speaking, connectionID: connectionID)

        case .transcriptDone(let event):
            guard event.threadID == realtimeThreadID else { return }
            let entry = transcriptState.complete(text: event.text, role: event.role)
            updateLifecycle(.listening, connectionID: connectionID)
            await persistTranscriptEntry(entry)

        case .error(let event):
            guard lifecycle.isCurrentConnection(connectionID),
                  event.threadID == realtimeThreadID else { return }
            guard event.isTerminal else {
                diagnostic("nonterminal provider error: \(event.message)")
                let entry = transcriptState.interruptAssistant()
                updateLifecycle(.listening, connectionID: connectionID)
                await persistTranscriptEntry(entry)
                return
            }
            await failSession(
                NSError(
                    domain: "RemoteCoder.RealtimeVoice",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: event.message]
                )
            )

        case .closed(let event):
            guard lifecycle.isCurrentConnection(connectionID),
                  event.threadID == realtimeThreadID else { return }
            diagnostic("realtime closed reason=\(event.reason ?? "unspecified") providerClosed=\(event.providerClosed == true)")
            let nextState = RealtimeVoiceLifecycle.stateAfterClosure(
                reason: event.reason, providerClosed: event.providerClosed == true
            )
            if nextState == .reconnecting {
                scheduleReconnect(connectionID: connectionID)
            } else {
                if let conversationUUID = lifecycle.callID {
                    systemBridge.reportEnded(
                        callID: conversationUUID,
                        reason: nextState == .idle ? .remoteEnded : .failed
                    )
                }
                await tearDown(finalState: nextState, stopRemoteSession: false)
            }

        case .preempted(let event):
            guard event.realtimeSessionID == realtimeSessionID else { return }
            // End the system conversation too: tearing down only WebRTC
            // leaves iOS convinced a call is still live (green pill, voip
            // background mode) with no way left to end it.
            if let conversationUUID = lifecycle.callID {
                systemBridge.reportEnded(callID: conversationUUID, reason: .joinedElsewhere)
            }
            await tearDown(
                finalState: .failed("Voice Mode was opened in another call."),
                stopRemoteSession: false
            )

        case .agentEnded(let event):
            guard event.realtimeSessionID == realtimeSessionID else { return }
            await endAsAgentEnded()
        }
    }

    private func persistTranscriptEntry(_ entry: RealtimeVoiceTranscriptEntry?) async {
        guard let entry, let conversationThreadID, let voiceHistoryStore else { return }
        await voiceHistoryStore.append(
            role: entry.role, text: entry.text, date: Date(), threadID: conversationThreadID
        )
    }

    /// The agent hung up with its `end_voice_call` tool: the close is final,
    /// so the call ends like the far side hanging up instead of reconnecting.
    private func endAsAgentEnded() async {
        diagnostic("call ended by the agent")
        if let conversationUUID = lifecycle.callID {
            systemBridge.reportEnded(callID: conversationUUID, reason: .remoteEnded)
        }
        await tearDown(stopRemoteSession: false)
    }

    private func configureWebRTCAudioSession() throws {
        try RealtimeVoiceAudioSession.configureForSystemCall()
        let session = RTCAudioSession.sharedInstance()
        AgentCallDiagnostics.record("audioConfigured", callID: lifecycle.callID, hostID: incomingCall?.push.hostId,
            detail: "category=\(session.category) mode=\(session.mode) active=\(session.isActive) enabled=\(session.isAudioEnabled)", error: nil)
    }

    private func applyRemoteSDP(_ sdp: String, connectionID: UUID) async throws {
        guard lifecycle.isCurrentConnection(connectionID), let session = webRTCSession else { return }
        remoteSDPTimeoutTask?.cancel()
        remoteSDPTimeoutTask = nil
        let entry = transcriptState.beginProviderSession(connectionID: connectionID)
        await persistTranscriptEntry(entry)
        guard lifecycle.isCurrentConnection(connectionID) else { return }
        try await session.applyAnswer(sdp)
        guard lifecycle.isCurrentConnection(connectionID) else { return }
        diagnostic("remote SDP applied")
        remoteSDPTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await session.waitUntilConnected(timeout: .seconds(30))
            } catch {
                guard !Task.isCancelled, let self,
                      self.lifecycle.isCurrentConnection(connectionID)
                else { return }
                self.scheduleReconnect(connectionID: connectionID)
            }
        }
    }

    private func scheduleAudioActivationDeadline(callID: UUID) {
        audioActivationDeadlineTask?.cancel()
        audioActivationDeadlineTask = Task(name: "Voice audio activation deadline") { @MainActor [weak self] in
            do { try await Task.sleep(for: Self.audioActivationDeadline) } catch { return }
            guard let self, self.lifecycle.isCurrentCall(callID), !self.systemAudioSessionIsActive else { return }
            self.diagnostic("system audio not activated within \(Self.audioActivationDeadline)")
            await self.failSession(VoiceError.audioActivationTimedOut)
        }
    }

    private func scheduleRemoteSDPTimeout(for connectionID: UUID) {
        remoteSDPTimeoutTask?.cancel()
        remoteSDPTimeoutTask = Task(name: "Realtime voice remote SDP timeout") {
            @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            guard let self, self.lifecycle.isCurrentConnection(connectionID),
                  self.webRTCSession?.hasRemoteDescription == false
            else { return }
            await self.failSession(VoiceError.remoteSDPTimedOut)
        }
    }

    private func markConnected(connectionID: UUID) {
        guard lifecycle.isCurrentConnection(connectionID), !reconnectRequiresReplacement else { return }
        diagnostic("WebRTC connected")
        AgentCallDiagnostics.record("iceConnected", callID: lifecycle.callID, hostID: incomingCall?.push.hostId,
            detail: "systemAudioActive=\(systemAudioSessionIsActive) muted=\(isMuted)", error: nil)
        updateLifecycle(.listening, connectionID: connectionID)
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempts = 0

        guard !hasReportedConnected,
              let conversationUUID = lifecycle.callID,
              systemBridge.hasConversation(conversationUUID)
        else { return }

        hasReportedConnected = true
        conversationContext?.isProvisionalThread = false
        provisionalConversationThreadID = nil
        // Incoming conversations were connected by JoinConversationAction.
        // This event maps to CallKit's outgoing-call-connected report.
        if incomingCall == nil {
            systemBridge.reportConnected(callID: conversationUUID)
        }
        reportIncomingConnectedIfReady()
        requestGreetingIfReady()
    }

    private func reportIncomingConnectedIfReady() {
        guard hasReportedConnected, systemAudioSessionIsActive, !hasReportedIncomingConnected,
              incomingConnectedTask == nil, let incomingCall, incomingCall.answered,
              let gateway else { return }
        incomingConnectedTask = Task { @MainActor [weak self] in
            do {
                try await gateway.reportIncomingCallConnected(
                    callID: incomingCall.push.callId, deviceID: incomingCall.deviceID
                )
                guard let self, self.lifecycle.isCurrentCall(incomingCall.push.callId) else { return }
                self.hasReportedIncomingConnected = true
                self.incomingConnectedTask = nil
                AgentCallDiagnostics.record("audioConnectedAcknowledged", callID: incomingCall.push.callId, hostID: incomingCall.push.hostId, detail: "systemAudioActive=true", error: nil)
            } catch {
                guard !Task.isCancelled, let self,
                      self.lifecycle.isCurrentCall(incomingCall.push.callId) else { return }
                await self.failSession(error)
            }
        }
    }

    private func requestGreetingIfReady() {
        guard hasReportedConnected, systemAudioSessionIsActive, greetingTask == nil,
              incomingCall == nil, let realtimeSessionID, let gateway else { return }
        greetingTask = Task { @MainActor [weak self] in
            do {
                try await gateway.reportVoiceSessionConnected(realtimeSessionID: realtimeSessionID)
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.diagnostic("greeting request failed error=\(error.localizedDescription)")
            }
        }
    }

    private func failSession(_ error: Error) async {
        AgentCallDiagnostics.record("voiceFailed", callID: lifecycle.callID, hostID: incomingCall?.push.hostId, detail: "state=\(lifecycle.state)", error: error)
        logger.error("realtime voice failed: \(error.localizedDescription, privacy: .public)")
        VoiceModeDiagnostics.log("realtime voice failed error=\(error.localizedDescription)")
        let message = error.localizedDescription
        if let conversationUUID = lifecycle.callID {
            systemBridge.reportEnded(callID: conversationUUID, reason: .failed)
        }
        await tearDown(finalState: incomingCall == nil ? .failed(message) : .idle, incomingEndReason: "failed")
    }

    private func closePeerConnection() {
        remoteSDPTimeoutTask?.cancel()
        remoteSDPTimeoutTask = nil
        webRTCSession?.onICEConnectionStateChange = nil
        webRTCSession?.onICEGatheringStateChange = nil
        webRTCSession?.close()
        webRTCSession = nil
    }

    private func diagnostic(_ event: String) {
        logger.notice("controller=\(self.diagnosticID, privacy: .public) \(event, privacy: .public)")
        VoiceModeDiagnostics.log("realtime controller=\(self.diagnosticID) \(event)")
    }

    private func tearDown(
        finalState: State = .idle,
        stopRemoteSession: Bool = true,
        incomingEndReason: String? = nil
    ) async {
        if let teardownTask {
            await teardownTask.value
            return
        }
        guard let callID = lifecycle.beginStop() else { return }
        diagnostic("tearing down call=\(callID)")
        AgentCallDiagnostics.record("teardownStarted", callID: callID, hostID: incomingCall?.push.hostId, detail: "reason=\(incomingEndReason ?? "ended")", error: nil)
        let failedBeforeActivation = !hasReportedConnected
        let provisionalThreadID = provisionalConversationThreadID
        let endingModel = model
        let endingGateway = gateway
        let endingIncomingCall = incomingCall
        let endingVoiceHistory = voiceHistoryStore
        let endingLiveActivity = liveActivity
        liveActivity = nil
        incomingMonitorTask?.cancel()
        incomingMonitorTask = nil
        incomingExpiryTask?.cancel()
        incomingExpiryTask = nil
        incomingConnectedTask?.cancel()
        incomingConnectedTask = nil
        greetingTask?.cancel()
        greetingTask = nil
        systemStartTask?.cancel()
        systemStartTask = nil
        connectionTask?.cancel()
        connectionTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        audioActivationDeadlineTask?.cancel()
        audioActivationDeadlineTask = nil
        closePeerConnection()
        RTCAudioSession.sharedInstance().isAudioEnabled = false
        systemAudioSessionIsActive = false

        let task = Task { @MainActor [self] in
            if stopRemoteSession, let endingGateway {
                // Preserve transcript-tail delivery without allowing it to change call state.
                do {
                    if let endingIncomingCall {
                        try await endingGateway.endIncomingCall(
                            callID: endingIncomingCall.push.callId, deviceID: endingIncomingCall.deviceID,
                            reason: incomingEndReason ?? (endingIncomingCall.answered ? "ended" : "declined")
                        )
                    } else {
                        try await endingGateway.stopRealtimeVoiceSession()
                    }
                } catch {
                    logger.error("Voice cleanup could not reach its gateway: \(error.localizedDescription, privacy: .public)")
                    AgentCallDiagnostics.record("gatewayCleanupFailed", callID: callID, hostID: endingIncomingCall?.push.hostId, detail: "", error: error)
                }
                await Task.yield()
            }
            notificationTask?.cancel()
            notificationTask = nil
            audioRoute.stopListening()
            realtimeThreadID = nil
            realtimeSessionID = nil
            conversationThreadID = nil
            provisionalConversationThreadID = nil
            pendingRemoteSDP.removeAll()
            hasReportedConnected = false
            incomingCall = nil
            hasReportedIncomingConnected = false
            reconnectAttempts = 0
            isMuted = false
            audioRoute.refresh()
            if failedBeforeActivation {
                conversationContext = nil
                await endingModel?.discardProvisionalRealtimeVoiceConversation(threadID: provisionalThreadID)
            }
            await endingVoiceHistory?.flush()
            await endingLiveActivity?.end()
            endingModel?.setVoiceModeActive(false)
            callOwner = nil
            teardownTask = nil
            lifecycle.finishStop(callID: callID, finalState: finalState)
            diagnostic("call stopped call=\(callID) state=\(finalState)")
            AgentCallDiagnostics.record("teardownCompleted", callID: callID, hostID: endingIncomingCall?.push.hostId, detail: "state=\(finalState)", error: nil)
            let waiters = callEndWaiters
            callEndWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        teardownTask = task
        await task.value
    }
}

extension VoiceCall: CallSystemBridgeDelegate {
    func callSystemDidReset() async {
        guard isActive else { return }
        await failSession(
            NSError(
                domain: "RemoteCoder.RealtimeVoice",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "The system reset the voice conversation."]
            )
        )
    }

    func callSystem(perform action: ConversationAction) async {
        diagnostic("received system action type=\(String(describing: type(of: action)))")
        AgentCallDiagnostics.record("systemAction", callID: action.conversationUUID, hostID: incomingCall?.push.hostId, detail: String(describing: type(of: action)), error: nil)

        switch action {
        case let action as StartConversationAction:
            await handleStartAction(action)
        case let action as JoinConversationAction:
            await handleJoinAction(action)
        case let action as EndConversationAction:
            await handleEndAction(action)
        case let action as MuteConversationAction:
            handleMuteAction(action)
        default:
            action.fail()
        }
    }

    func callSystemTimedOut(callID: UUID) async {
        guard callID == lifecycle.callID else { return }
        await failSession(
            NSError(
                domain: "RemoteCoder.RealtimeVoice",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "The system voice action timed out."]
            )
        )
    }

    func callSystemDidActivateAudio(category: String, mode: String) {
        guard isActive, incomingCall?.answered != false else {
            RTCAudioSession.sharedInstance().isAudioEnabled = false
            return
        }
        audioActivationDeadlineTask?.cancel()
        audioActivationDeadlineTask = nil
        RTCAudioSession.sharedInstance().isAudioEnabled = true
        systemAudioSessionIsActive = true
        AgentCallDiagnostics.record("systemAudioActivated", callID: lifecycle.callID, hostID: incomingCall?.push.hostId,
            detail: "category=\(category) mode=\(mode)", error: nil)
        webRTCSession?.setInputEnabled(!isMuted)
        audioRoute.refresh()
        reportIncomingConnectedIfReady()
        requestGreetingIfReady()
    }

    func callSystemDidDeactivateAudio() {
        systemAudioSessionIsActive = false
        webRTCSession?.setInputEnabled(false)
    }
}
