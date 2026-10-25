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

    private let locationManager: CLLocationManager
    private let logger = AppLogger(category: "LiveNavigationSetup")
    private var serviceSession: CLServiceSession?
    private var refreshTask: Task<Void, Never>?

    private var authorizationStatus: CLAuthorizationStatus
    private var accuracyAuthorization: CLAccuracyAuthorization
    private(set) var progress: String?
    private(set) var errorMessage: String?

    init() {
        let locationManager = CLLocationManager()
        self.locationManager = locationManager
        authorizationStatus = locationManager.authorizationStatus
        accuracyAuthorization = locationManager.accuracyAuthorization
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
        switch authorizationStatus {
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
        accuracyAuthorization == .fullAccuracy ? "Precise" : "Reduced"
    }

    private var isReady: Bool {
        authorizationStatus == .authorizedAlways && accuracyAuthorization == .fullAccuracy
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
            await acknowledgeGoogleTerms()

            progress = "Requesting location access…"
            serviceSession = CLServiceSession(
                authorization: .always,
                fullAccuracyPurposeKey: LiveNavigationConstants.fullAccuracyPurposeKey
            )
            try await waitForLocationDecision()
            try Task.checkCancellation()

            progress = "Preparing location…"
            let token = try await locationPushToken()
            try Task.checkCancellation()
            readAuthorization()
            pushTokens.receiveLocation(credentials(token: token))
            UserDefaults.standard.set(true, forKey: Self.setupEnabledKey)
        } catch {
            logger.error("Live-location setup failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    func refreshRegistration(pushTokens: PushTokenSources) {
        readAuthorization()
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
        if authorizationStatus == .authorizedAlways {
            do {
                refreshed = try await locationPushToken()
            } catch {
                logger.error("Location-push token refresh failed: \(error.localizedDescription)")
            }
        }
        readAuthorization()
        guard let token = refreshed ?? pushTokens.location?.token else { return }
        pushTokens.receiveLocation(credentials(token: token))
    }

    private func locationPushToken() async throws -> String {
        logger.notice("Requesting the location-push token.")
        let token = try await locationManager.startMonitoringLocationPushes()
        logger.notice("Received location-push token (\(token.count) bytes).")
        return token.map { String(format: "%02x", $0) }.joined()
    }

    private func credentials(token: String) -> DeviceLocationCredentials {
        DeviceLocationCredentials(
            token: token,
            setupReady: isReady,
            authorization: authorization,
            fullAccuracy: accuracyAuthorization == .fullAccuracy,
            googleTermsAccepted: true
        )
    }

    private func readAuthorization() {
        authorizationStatus = locationManager.authorizationStatus
        accuracyAuthorization = locationManager.accuracyAuthorization
    }

    private func acknowledgeGoogleTerms() async {
        let options = GMSNavigationTermsAndConditionsOptions(companyName: "RemoteCoder")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            GMSNavigationServices.showTermsAndConditionsDialogIfNeeded(with: options) { _ in
                continuation.resume()
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
    case missingGoogleMapsAPIKey
    case perfHarnessBuild

    var errorDescription: String? {
        switch self {
        case .missingGoogleMapsAPIKey:
            return "This build is missing its Google Maps key."
        case .perfHarnessBuild:
            return "Performance test builds never register a location device."
        }
    }
}
