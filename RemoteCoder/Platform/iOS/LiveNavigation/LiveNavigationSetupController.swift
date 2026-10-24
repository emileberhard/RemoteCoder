import CoreLocation
import GoogleNavigation
import Observation
import OSLog

@MainActor
@Observable
final class LiveNavigationSetupController {
    struct GoogleLicenses {
        let sdkVersion: String
        let openSourceLicenses: String

        @MainActor static func load() -> Self {
            // SDK initialization touches UserDefaults. Never do this while SwiftUI
            // holds its render lock: Google's initializer can wait on that same lock.
            Self(
                sdkVersion: GMSNavigationServices.navSDKVersion(),
                openSourceLicenses: GMSNavigationServices.openSourceLicenseInfo()
            )
        }
    }

    static let setupEnabledKey = "liveNavigation.setupEnabled"

    private let locationManager = CLLocationManager()
    private let logger = Logger(subsystem: "RemoteCoder", category: "LiveNavigationSetup")
    private var serviceSession: CLServiceSession?
    private var refreshTask: Task<Void, Never>?

    private(set) var progress: String?
    private(set) var errorMessage: String?

    init() {
        if UserDefaults.standard.bool(forKey: Self.setupEnabledKey) {
            serviceSession = CLServiceSession(authorization: .always)
        }
    }

    var isWorking: Bool { progress != nil }

    var status: String {
        if let progress { return progress }
        if errorMessage != nil { return "Setup incomplete" }
        guard UserDefaults.standard.bool(forKey: Self.setupEnabledKey) else { return "Not configured" }
        return isReady ? "Ready" : "Enable Always and Precise location to finish setup."
    }

    var authorization: String {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            return "Not requested"
        case .restricted:
            return "Restricted"
        case .denied:
            return "Denied"
        case .authorizedWhenInUse:
            return "While Using"
        case .authorizedAlways:
            return "Always"
        @unknown default:
            return "Unknown"
        }
    }

    var accuracy: String {
        locationManager.accuracyAuthorization == .fullAccuracy ? "Precise" : "Reduced"
    }

    private var isReady: Bool {
        locationManager.authorizationStatus == .authorizedAlways && locationManager.accuracyAuthorization == .fullAccuracy
    }

    func prepare(policy: SharedGatewayPolicy, googleMapsAPIKey: String, pushTokens: PushTokenSources) async {
        guard isWorking == false else { return }
        progress = "Waiting for Google terms…"
        errorMessage = nil
        defer { progress = nil }
        await refreshTask?.value

        do {
            guard policy.registersDevice else { throw SetupError.perfHarnessBuild }
            guard googleMapsAPIKey.isEmpty == false else {
                throw SetupError.missingGoogleMapsAPIKey
            }
            guard await acceptGoogleTerms() else {
                throw SetupError.googleTermsDeclined
            }

            progress = "Requesting location access…"
            serviceSession = CLServiceSession(
                authorization: .always,
                fullAccuracyPurposeKey: LiveNavigationConstants.fullAccuracyPurposeKey
            )
            try await waitForLocationDecision()
            try Task.checkCancellation()

            progress = "Preparing location…"
            let credentials = credentials(token: try await locationPushToken())
            try Task.checkCancellation()
            pushTokens.receiveLocation(credentials)
            UserDefaults.standard.set(true, forKey: Self.setupEnabledKey)
        } catch {
            logger.error("Live-location setup failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func refreshRegistration(pushTokens: PushTokenSources) {
        guard UserDefaults.standard.bool(forKey: Self.setupEnabledKey), isWorking == false, refreshTask == nil else {
            return
        }
        refreshTask = Task { [weak self] in
            await self?.reregister(pushTokens: pushTokens)
            self?.refreshTask = nil
        }
    }

    private func reregister(pushTokens: PushTokenSources) async {
        var refreshed: String?
        if locationManager.authorizationStatus == .authorizedAlways {
            do {
                refreshed = try await locationPushToken()
            } catch {
                logger.error("Location-push token refresh failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard let token = refreshed ?? pushTokens.location?.token else { return }
        pushTokens.receiveLocation(credentials(token: token))
    }

    private func locationPushToken() async throws -> String {
        logger.notice("Requesting the location-push token.")
        let token = try await locationManager.startMonitoringLocationPushes()
        logger.notice("Received location-push token (\(token.count, privacy: .public) bytes).")
        return token.map { String(format: "%02x", $0) }.joined()
    }

    private func credentials(token: String) -> DeviceLocationCredentials {
        DeviceLocationCredentials(
            token: token,
            setupReady: isReady,
            authorization: authorization,
            fullAccuracy: locationManager.accuracyAuthorization == .fullAccuracy,
            googleTermsAccepted: true
        )
    }

    private func acceptGoogleTerms() async -> Bool {
        let options = GMSNavigationTermsAndConditionsOptions(companyName: "RemoteCoder")
        return await withCheckedContinuation { continuation in
            GMSNavigationServices.showTermsAndConditionsDialogIfNeeded(with: options) { accepted in
                continuation.resume(returning: accepted)
            }
        }
    }

    private func waitForLocationDecision() async throws {
        for _ in 0 ..< 120 {
            let authorization = locationManager.authorizationStatus
            if authorization == .authorizedAlways || authorization == .denied || authorization == .restricted {
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
    }
}

private enum SetupError: LocalizedError {
    case googleTermsDeclined
    case missingGoogleMapsAPIKey
    case perfHarnessBuild

    var errorDescription: String? {
        switch self {
        case .googleTermsDeclined:
            return "Google Navigation terms must be accepted before setup can finish."
        case .missingGoogleMapsAPIKey:
            return "This build is missing its Google Maps key."
        case .perfHarnessBuild:
            return "Performance test builds never register a location device."
        }
    }
}
