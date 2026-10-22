import CoreLocation
import GoogleNavigation
import Observation
import OSLog

@MainActor
@Observable
final class LiveNavigationSetupController {
    struct GoogleStatus {
        let termsAccepted: Bool
        let sdkVersion: String
        let openSourceLicenses: String
    }

    static let setupEnabledKey = "liveNavigation.setupEnabled"

    private let locationManager = CLLocationManager()
    private let logger = Logger(subsystem: "RemoteCoder", category: "LiveNavigationSetup")
    private var serviceSession: CLServiceSession?

    private(set) var isWorking = false
    private(set) var status = "Not configured"
    private(set) var errorMessage: String?
    private(set) var googleStatus: GoogleStatus?

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

    func refreshGoogleStatus() {
        // SDK initialization touches UserDefaults. Never do this while SwiftUI
        // holds its render lock: Google's initializer can wait on that same lock.
        googleStatus = GoogleStatus(
            termsAccepted: GMSNavigationServices.areTermsAndConditionsAccepted(),
            sdkVersion: GMSNavigationServices.navSDKVersion(),
            openSourceLicenses: GMSNavigationServices.openSourceLicenseInfo()
        )
    }

    func prepare(policy: SharedGatewayPolicy, googleMapsAPIKey: String, pushTokens: PushTokenSources) async {
        guard isWorking == false else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            guard policy.registersDevice else { throw SetupError.perfHarnessBuild }
            guard googleMapsAPIKey.isEmpty == false else {
                throw SetupError.missingGoogleMapsAPIKey
            }
            if googleStatus == nil {
                refreshGoogleStatus()
            }
            status = "Waiting for Google terms…"
            guard await acceptGoogleTermsIfNeeded() else {
                throw SetupError.googleTermsDeclined
            }

            status = "Requesting location access…"
            let session = CLServiceSession(
                authorization: .always,
                fullAccuracyPurposeKey: LiveNavigationConstants.fullAccuracyPurposeKey
            )
            serviceSession = session
            LiveNavigationCoordinator.shared.retainSetupSession(session)

            try await waitForLocationDecision()
            try Task.checkCancellation()

            status = "Preparing location…"
            logger.notice("Requesting the location-push token.")
            let token = try await locationManager.startMonitoringLocationPushes()
            try Task.checkCancellation()
            logger.notice("Received location-push token (\(token.count, privacy: .public) bytes).")
            let setupReady = locationManager.authorizationStatus == .authorizedAlways
                && locationManager.accuracyAuthorization == .fullAccuracy
                && googleStatus?.termsAccepted == true

            pushTokens.receiveLocation(
                DeviceLocationCredentials(
                    token: token.map { String(format: "%02x", $0) }.joined(),
                    setupReady: setupReady,
                    authorization: authorization,
                    fullAccuracy: locationManager.accuracyAuthorization == .fullAccuracy,
                    googleTermsAccepted: googleStatus?.termsAccepted == true
                )
            )
            UserDefaults.standard.set(true, forKey: Self.setupEnabledKey)
            status = setupReady
                ? "Ready"
                : "Enable Always and Precise location to finish setup."
        } catch {
            logger.error("Live-location setup failed: \(error.localizedDescription, privacy: .public)")
            status = "Setup incomplete"
            errorMessage = error.localizedDescription
        }
    }

    private func acceptGoogleTermsIfNeeded() async -> Bool {
        if googleStatus?.termsAccepted == true { return true }
        let options = GMSNavigationTermsAndConditionsOptions(companyName: "RemoteCoder")
        let accepted = await withCheckedContinuation { continuation in
            GMSNavigationServices.showTermsAndConditionsDialogIfNeeded(with: options) { accepted in
                continuation.resume(returning: accepted)
            }
        }
        refreshGoogleStatus()
        return accepted
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
