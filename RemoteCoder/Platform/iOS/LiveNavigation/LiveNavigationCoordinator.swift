import CoreLocation
import GoogleNavigation
import OSLog
import UIKit
import notify

@MainActor
final class LiveNavigationCoordinator: NSObject {
    static let shared = LiveNavigationCoordinator()

    private let logger = Logger(subsystem: "RemoteCoder", category: "LiveNavigation")
    private var serviceSession: CLServiceSession?
    private var backgroundSession: CLBackgroundActivitySession?
    private var rawLocationTask: Task<Void, Never>?
    private var googleConfigured = false
    private var navigationSession: GMSNavigationSession?
    private var eventSink: LiveNavigationEventSink?
    private var activeSessionID: String?
    private var latestRawLocation: LiveNavigationLocation?
    private var lastLocationEventAt = Date.distantPast
    private var commandNotificationToken: Int32 = 0

    private override init() {
        super.init()
        let status = notify_register_dispatch(
            LiveNavigationConstants.commandChangedNotification,
            &commandNotificationToken,
            .main
        ) { _ in
            Task { @MainActor in
                LiveNavigationCoordinator.shared.restoreIfNeeded()
            }
        }
        if status != NOTIFY_STATUS_OK {
            logger.error("Could not observe live-navigation commands: notify status \(status)")
        }
    }

    func configureGoogle(googleMapsAPIKey: String) {
        guard googleMapsAPIKey.isEmpty == false else {
            return
        }
        googleConfigured = GMSServices.provideAPIKey(googleMapsAPIKey)
    }

    func restoreIfNeeded() {
        guard googleConfigured, UserDefaults.standard.bool(forKey: LiveNavigationSetupController.setupEnabledKey) else {
            return
        }
        guard let stored = try? LiveNavigationCommandStore.load() else { return }
        guard stored.command.isExpired == false else {
            try? LiveNavigationCommandStore.clear(sessionID: stored.command.sessionId)
            return
        }
        start(stored)
    }

    func start(_ stored: LiveNavigationStoredState) {
        guard googleConfigured else { return }
        guard stored.command.isExpired == false else {
            try? LiveNavigationCommandStore.clear(sessionID: stored.command.sessionId)
            return
        }
        if activeSessionID == stored.command.sessionId { return }
        stop(clearCommand: false)

        let command = stored.command
        activeSessionID = command.sessionId
        serviceSession = CLServiceSession(
            authorization: .always,
            fullAccuracyPurposeKey: LiveNavigationConstants.fullAccuracyPurposeKey
        )
        backgroundSession = CLBackgroundActivitySession()
        let sink = LiveNavigationEventSink(
            command: command,
            // Sequence 1 belongs to the location-push extension's bootstrap fix.
            startingSequence: max(stored.lastSequence, 1)
        )
        eventSink = sink

        rawLocationTask = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(command.profile.liveUpdateConfiguration) {
                    guard Task.isCancelled == false else { return }
                    if let location = update.location {
                        let rawLocation = LiveNavigationLocation(location)
                        self?.latestRawLocation = rawLocation
                        if self?.navigationSession == nil,
                           self?.shouldEmitLocationEvent() == true {
                            await sink.send(kind: .location, rawLocation: rawLocation)
                        }
                    }
                }
            } catch {
                await sink.send(kind: .error, message: error.localizedDescription)
                guard let self, self.eventSink === sink else { return }
                self.stop(clearCommand: false)
            }
        }

        guard let navigationSession = GMSNavigationServices.createNavigationSession() else {
            Task {
                await sink.send(
                    kind: .error,
                    message: "Google Navigation terms are not accepted: run Settings → Location → Prepare live location on the iPhone."
                )
            }
            return
        }
        self.navigationSession = navigationSession
        navigationSession.travelMode = command.profile.mode.googleTravelMode
        navigationSession.isStarted = true

        guard let navigator = navigationSession.navigator,
              let locationProvider = navigationSession.roadSnappedLocationProvider else {
            Task { await sink.send(kind: .error, message: "Google Navigation services are unavailable.") }
            return
        }
        navigator.add(self)
        navigator.voiceGuidance = .silent
        navigator.sendsBackgroundNotifications = false
        navigator.avoidsHighways = command.profile.avoidHighways
        navigator.avoidsTolls = command.profile.avoidTolls
        locationProvider.add(self)
        locationProvider.allowsBackgroundLocationUpdates = true
        locationProvider.startUpdatingLocation()

        if let destination = command.destination {
            let waypoint: GMSNavigationWaypoint?
            if let placeID = destination.placeId, placeID.isEmpty == false {
                waypoint = GMSNavigationWaypoint(
                    location: CLLocationCoordinate2D(
                        latitude: destination.latitude,
                        longitude: destination.longitude
                    ),
                    placeID: placeID,
                    title: destination.title
                )
            } else {
                waypoint = GMSNavigationWaypoint(
                    location: CLLocationCoordinate2D(
                        latitude: destination.latitude,
                        longitude: destination.longitude
                    ),
                    title: destination.title
                )
            }
            guard let waypoint else {
                Task { await sink.send(kind: .error, message: "Destination could not be converted to a waypoint.") }
                return
            }
            navigator.setDestinations([waypoint]) { status in
                if status == .OK {
                    navigator.isGuidanceActive = true
                } else {
                    Task {
                        await sink.send(
                            kind: .error,
                            message: "Google route request failed with status \(status.rawValue)."
                        )
                    }
                }
            }
        }
        logger.notice("Started live-navigation session \(command.sessionId, privacy: .public)")
    }

    func stop(clearCommand: Bool = true) {
        let stoppedSessionID = activeSessionID
        rawLocationTask?.cancel()
        rawLocationTask = nil
        if let navigationSession {
            navigationSession.roadSnappedLocationProvider?.stopUpdatingLocation()
            navigationSession.roadSnappedLocationProvider?.remove(self)
            navigationSession.navigator?.remove(self)
            navigationSession.navigator?.isGuidanceActive = false
            navigationSession.navigator?.clearDestinations()
            navigationSession.isStarted = false
        }
        navigationSession = nil
        backgroundSession?.invalidate()
        backgroundSession = nil
        serviceSession = nil
        eventSink = nil
        activeSessionID = nil
        latestRawLocation = nil
        lastLocationEventAt = .distantPast
        if clearCommand, let stoppedSessionID {
            try? LiveNavigationCommandStore.clear(sessionID: stoppedSessionID)
        }
    }

    func stopIfActive(sessionID: String) {
        guard activeSessionID == sessionID else { return }
        stop(clearCommand: false)
    }

    private func shouldEmitLocationEvent(now: Date = Date()) -> Bool {
        guard now.timeIntervalSince(lastLocationEventAt) >= 1 else { return false }
        lastLocationEventAt = now
        return true
    }
}

extension LiveNavigationCoordinator: GMSRoadSnappedLocationProviderListener {
    func locationProvider(
        _ locationProvider: GMSRoadSnappedLocationProvider,
        didUpdate location: CLLocation
    ) {
        guard let eventSink, shouldEmitLocationEvent() else { return }
        let rawLocation = latestRawLocation
        let roadLocation = LiveNavigationLocation(location)
        Task {
            await eventSink.send(
                kind: .location,
                rawLocation: rawLocation,
                roadSnappedLocation: roadLocation
            )
        }
    }
}

extension LiveNavigationCoordinator: GMSNavigatorListener {
    func navigator(_ navigator: GMSNavigator, didUpdate navInfo: GMSNavigationNavInfo) {
        guard let eventSink else { return }
        let guidance = LiveNavigationGuidance(
            state: String(describing: navInfo.navState),
            instruction: navInfo.currentStep?.fullInstructionText,
            routeChanged: navInfo.routeChanged,
            distanceToNextStepMeters: finite(navInfo.distanceToCurrentStepMeters),
            timeToNextStepSeconds: finite(navInfo.timeToCurrentStepSeconds),
            distanceToDestinationMeters: finite(navInfo.distanceToFinalDestinationMeters),
            timeToDestinationSeconds: finite(navInfo.timeToFinalDestinationSeconds)
        )
        Task {
            await eventSink.send(
                kind: navInfo.routeChanged ? .routeChanged : .guidance,
                guidance: guidance
            )
        }
    }

    func navigatorDidChangeRoute(_ navigator: GMSNavigator) {
        guard let eventSink else { return }
        Task { await eventSink.send(kind: .routeChanged, message: "Google recalculated the route.") }
    }

    func navigator(_ navigator: GMSNavigator, didArriveAt waypoint: GMSNavigationWaypoint) {
        guard let eventSink else { return }
        Task { await eventSink.send(kind: .arrived, message: "Arrived at \(waypoint.title).") }
    }
}

private actor LiveNavigationEventSink {
    private struct PendingEvent {
        let kind: LiveNavigationEvent.Kind
        let sentAtUnixSeconds: Double
        let rawLocation: LiveNavigationLocation?
        let roadSnappedLocation: LiveNavigationLocation?
        let guidance: LiveNavigationGuidance?
        let message: String?
    }

    private static let maximumPendingEvents = 256

    private let command: LiveNavigationCommand
    private var sequence: UInt64
    private var stopped = false
    private var isDraining = false
    private var pendingEvents: [PendingEvent] = []

    init(command: LiveNavigationCommand, startingSequence: UInt64) {
        self.command = command
        sequence = startingSequence
    }

    func send(
        kind: LiveNavigationEvent.Kind,
        rawLocation: LiveNavigationLocation? = nil,
        roadSnappedLocation: LiveNavigationLocation? = nil,
        guidance: LiveNavigationGuidance? = nil,
        message: String? = nil
    ) async {
        guard stopped == false else { return }
        pendingEvents.append(
            PendingEvent(
                kind: kind,
                sentAtUnixSeconds: Date().timeIntervalSince1970,
                rawLocation: rawLocation,
                roadSnappedLocation: roadSnappedLocation,
                guidance: guidance,
                message: message
            )
        )
        if pendingEvents.count > Self.maximumPendingEvents {
            pendingEvents.removeFirst(pendingEvents.count - Self.maximumPendingEvents)
        }
        guard isDraining == false else { return }
        isDraining = true
        await drain()
    }

    private func drain() async {
        while stopped == false, pendingEvents.isEmpty == false {
            let pending = pendingEvents.removeFirst()
            let nextSequence = sequence + 1
            let event = LiveNavigationEvent(
                schemaVersion: 1,
                sessionId: command.sessionId,
                sequence: nextSequence,
                kind: pending.kind,
                sentAtUnixSeconds: pending.sentAtUnixSeconds,
                rawLocation: pending.rawLocation,
                roadSnappedLocation: pending.roadSnappedLocation,
                guidance: pending.guidance,
                message: pending.message
            )
            do {
                let response = try await LiveNavigationUploader.upload(event, using: command)
                guard response.acceptedSequence == nextSequence else {
                    throw LiveNavigationError.unexpectedAcceptedSequence(
                        expected: nextSequence,
                        actual: response.acceptedSequence
                    )
                }
                sequence = response.acceptedSequence
                guard try LiveNavigationCommandStore.saveProgress(
                    command: command,
                    acceptedSequence: sequence
                ) else {
                    stopped = true
                    pendingEvents.removeAll()
                    await MainActor.run {
                        LiveNavigationCoordinator.shared.stopIfActive(sessionID: command.sessionId)
                    }
                    continue
                }
                if response.command?.type == "stop" {
                    stopped = true
                    pendingEvents.removeAll()
                    try LiveNavigationCommandStore.clear(sessionID: command.sessionId)
                    await MainActor.run {
                        LiveNavigationCoordinator.shared.stopIfActive(sessionID: command.sessionId)
                    }
                }
            } catch {
                pendingEvents.insert(pending, at: 0)
                if pendingEvents.count > Self.maximumPendingEvents {
                    pendingEvents.removeLast(pendingEvents.count - Self.maximumPendingEvents)
                }
                isDraining = false
                return
            }
        }
        isDraining = false
    }
}

private extension LiveNavigationProfile.Mode {
    var googleTravelMode: GMSNavigationTravelMode {
        switch self {
        case .driving:
            return .driving
        case .cycling:
            return .cycling
        case .walking:
            return .walking
        case .taxi:
            return .taxicab
        }
    }
}

private func finite(_ value: Double) -> Double? {
    value.isFinite && value >= 0 ? value : nil
}
