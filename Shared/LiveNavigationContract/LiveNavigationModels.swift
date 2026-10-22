import CoreLocation
import Darwin
import Foundation
import notify

enum LiveNavigationConstants {
    static let fullAccuracyPurposeKey = "LiveNavigation"
    static let keyDerivationInfo = Data("RemoteCoderLiveNavigation/v1".utf8)
    static let commandChangedNotification = "emileberhard.RemoteCoder.liveNavigationCommandChanged"

    static func postCommandChangedNotification() {
        commandChangedNotification.withCString { name in
            _ = notify_post(name)
        }
    }
}

struct LiveNavigationCommand: Codable, Sendable {
    let schemaVersion: Int
    let sessionId: String
    let destination: LiveNavigationDestination?
    let profile: LiveNavigationProfile
    let eventUploadURL: URL
    let uploadToken: String
    let serverPublicKey: String
    let expiresAtUnixSeconds: Int64

    var isExpired: Bool {
        Date().timeIntervalSince1970 >= TimeInterval(expiresAtUnixSeconds)
    }

    func validate() throws {
        guard schemaVersion == 1 else {
            throw LiveNavigationError.invalidCommand("unsupported schema version \(schemaVersion)")
        }
        guard sessionId.isEmpty == false else {
            throw LiveNavigationError.invalidCommand("session id is empty")
        }
        guard uploadToken.isEmpty == false else {
            throw LiveNavigationError.invalidCommand("upload token is empty")
        }
        guard isExpired == false else {
            throw LiveNavigationError.invalidCommand("session has expired")
        }
        if let destination {
            try destination.validate()
        }
    }
}

struct LiveNavigationDestination: Codable, Sendable {
    let latitude: Double
    let longitude: Double
    let title: String
    let placeId: String?

    func validate() throws {
        guard (-90 ... 90).contains(latitude), (-180 ... 180).contains(longitude) else {
            throw LiveNavigationError.invalidCommand("destination coordinates are invalid")
        }
        guard title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw LiveNavigationError.invalidCommand("destination title is empty")
        }
    }
}

struct LiveNavigationProfile: Codable, Sendable {
    enum Mode: String, Codable, Sendable {
        case driving
        case cycling
        case walking
        case taxi
    }

    let mode: Mode
    let avoidHighways: Bool
    let avoidTolls: Bool

    var liveUpdateConfiguration: CLLocationUpdate.LiveConfiguration {
        switch mode {
        case .driving, .taxi:
            return .automotiveNavigation
        case .cycling:
            return .otherNavigation
        case .walking:
            return .fitness
        }
    }
}

struct LiveNavigationLocation: Codable, Sendable {
    let latitude: Double
    let longitude: Double
    let altitudeMeters: Double
    let horizontalAccuracyMeters: Double
    let verticalAccuracyMeters: Double
    let courseDegrees: Double
    let courseAccuracyDegrees: Double
    let speedMetersPerSecond: Double
    let speedAccuracyMetersPerSecond: Double
    let observedAtUnixSeconds: Double

    init(_ location: CLLocation) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        altitudeMeters = location.altitude
        horizontalAccuracyMeters = location.horizontalAccuracy
        verticalAccuracyMeters = location.verticalAccuracy
        courseDegrees = location.course
        courseAccuracyDegrees = location.courseAccuracy
        speedMetersPerSecond = location.speed
        speedAccuracyMetersPerSecond = location.speedAccuracy
        observedAtUnixSeconds = location.timestamp.timeIntervalSince1970
    }
}

struct LiveNavigationGuidance: Codable, Sendable {
    let state: String
    let instruction: String?
    let routeChanged: Bool
    let distanceToNextStepMeters: Double?
    let timeToNextStepSeconds: Double?
    let distanceToDestinationMeters: Double?
    let timeToDestinationSeconds: Double?
}

struct LiveNavigationEvent: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case bootstrap
        case location
        case guidance
        case routeChanged
        case arrived
        case stopped
        case error
    }

    let schemaVersion: Int
    let sessionId: String
    let sequence: UInt64
    let kind: Kind
    let sentAtUnixSeconds: Double
    let rawLocation: LiveNavigationLocation?
    let roadSnappedLocation: LiveNavigationLocation?
    let guidance: LiveNavigationGuidance?
    let message: String?
}

struct LiveNavigationUploadResponse: Decodable, Sendable {
    struct Command: Decodable, Sendable {
        let type: String
    }

    let acceptedSequence: UInt64
    let command: Command?
}

struct LiveNavigationStoredState: Codable, Sendable {
    let command: LiveNavigationCommand
    var lastSequence: UInt64
}

enum LiveNavigationCommandStore {
    private static let processLock = NSLock()

    static func load() throws -> LiveNavigationStoredState? {
        try withStateLock { url in
            try loadUnlocked(from: url)
        }
    }

    private static func loadUnlocked(from url: URL) throws -> LiveNavigationStoredState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(LiveNavigationStoredState.self, from: data)
    }

    static func save(command: LiveNavigationCommand, lastSequence: UInt64 = 0) throws {
        try command.validate()
        try withStateLock { url in
            try saveUnlocked(
                LiveNavigationStoredState(command: command, lastSequence: lastSequence),
                to: url
            )
        }
    }

    static func saveProgress(command: LiveNavigationCommand, acceptedSequence: UInt64) throws -> Bool {
        try command.validate()
        return try withStateLock { url in
            guard let current = try loadUnlocked(from: url),
                  current.command.sessionId == command.sessionId else {
                return false
            }
            guard acceptedSequence >= current.lastSequence else {
                // The app may advance while the extension finishes its bootstrap upload.
                return true
            }
            try saveUnlocked(
                LiveNavigationStoredState(command: command, lastSequence: acceptedSequence),
                to: url
            )
            return true
        }
    }

    private static func saveUnlocked(_ state: LiveNavigationStoredState, to url: URL) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func clear(sessionID: String) throws {
        try withStateLock { url in
            guard let current = try loadUnlocked(from: url),
                  current.command.sessionId == sessionID else {
                return
            }
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func stateURL() throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: RemoteCoderAppGroup.identifier
        ) else {
            throw LiveNavigationError.appGroupUnavailable
        }
        return container.appending(path: "live-navigation-state.json", directoryHint: .notDirectory)
    }

    private static func withStateLock<T>(_ body: (URL) throws -> T) throws -> T {
        try processLock.withLock {
            let url = try stateURL()
            let lockURL = url.appendingPathExtension("lock")
            let descriptor = lockURL.path.withCString {
                Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
            }
            guard descriptor >= 0 else {
                throw LiveNavigationError.commandStoreUnavailable(String(cString: strerror(errno)))
            }
            defer { Darwin.close(descriptor) }
            guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
                throw LiveNavigationError.commandStoreUnavailable(String(cString: strerror(errno)))
            }
            defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
            return try body(url)
        }
    }
}

enum LiveNavigationError: LocalizedError {
    case appGroupUnavailable
    case commandStoreUnavailable(String)
    case invalidCommand(String)
    case invalidPayload
    case invalidServerKey
    case invalidUploadResponse(Int, String)
    case unexpectedAcceptedSequence(expected: UInt64, actual: UInt64)

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "The shared RemoteCoder app group is unavailable."
        case .commandStoreUnavailable(let detail):
            return "The shared live-navigation command store is unavailable: \(detail)."
        case .invalidCommand(let detail):
            return "Invalid live-navigation command: \(detail)."
        case .invalidPayload:
            return "The location push did not contain a valid live-navigation command."
        case .invalidServerKey:
            return "The live-navigation server public key is invalid."
        case .invalidUploadResponse(let status, let body):
            return "Live-navigation upload failed with HTTP \(status): \(body)"
        case .unexpectedAcceptedSequence(let expected, let actual):
            return "Live-navigation upload acknowledged sequence \(actual), expected \(expected)."
        }
    }
}
