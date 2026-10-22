import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct DeviceRegistrationTests {
    private let appHost = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let routing = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!

    @Test func theSharedFixtureRoundTripsWithTheGatewaysFieldSpelling() throws {
        let data = try ProtocolFixtures.data(at: "devices/register.json")
        let request = try JSONDecoder().decode(DeviceRegistrationRequest.self, from: data)
        #expect(request.tokens.location?.navigation.eventBaseURL == "https://gateway.example")

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? NSDictionary
        let original = try JSONSerialization.jsonObject(with: data) as? NSDictionary
        #expect(encoded == original)
    }

    @Test func aConnectedHostRegistersTheCurrentTokensAndKeepsItsRoutingID() async {
        let transport = MockTransport(routingID: routing)
        let registration = makeRegistration(transport)
        registration.update(credentials: credentials(alert: token(1), voip: token(3)))
        registration.update(liveActivityToken: token(2))
        await registration.settle()

        #expect(registration.state == .registered(routingID: routing))
        let last = await transport.registered.last
        #expect(last?.tokens.alert == token(1))
        #expect(last?.tokens.voip == token(3))
        #expect(last?.tokens.liveActivity == token(2))
        #expect(last?.appHostId == appHost.uuidString)
    }

    @Test func aTokenChangeReplacesTheWholeSetAndAnEmptySetUnregisters() async {
        let transport = MockTransport(routingID: routing)
        let registration = makeRegistration(transport)
        registration.update(credentials: credentials(alert: token(1)))
        await registration.settle()
        registration.update(credentials: credentials(alert: token(4)))
        await registration.settle()
        #expect(await transport.registered.map(\.tokens.alert) == [token(1), token(4)])

        registration.update(credentials: credentials())
        await registration.settle()
        #expect(registration.state == .absent)
        #expect(await transport.unregistered == [deviceID])
    }

    @Test func aNewConnectionRegistersAgainAndAnUnchangedOneDoesNot() async {
        let transport = MockTransport(routingID: routing)
        let registration = makeRegistration(transport)
        registration.update(credentials: credentials(alert: token(1)))
        await registration.settle()
        await registration.settle()
        #expect(await transport.registered.count == 1)

        await transport.reconnect()
        await registration.settle()
        #expect(await transport.registered.count == 2)
    }

    @Test func aResultFromASupersededConnectionIsNotRecorded() async {
        let transport = MockTransport(routingID: routing, dropsConnectionDuringFirstRegister: true)
        let registration = makeRegistration(transport)
        registration.update(credentials: credentials(alert: token(1)))
        await registration.settle()

        #expect(await transport.registered.count == 2)
        #expect(registration.state == .registered(routingID: routing))
    }

    @Test func aFailureStaysVisibleUntilRetried() async {
        let transport = MockTransport(routingID: routing, failures: 1)
        let registration = makeRegistration(transport)
        registration.update(credentials: credentials(alert: token(1)))
        await registration.settle()
        #expect(registration.failure != nil)
        #expect(await transport.registered.count == 1)

        await registration.settle()
        #expect(registration.failure == nil)
        #expect(await transport.registered.count == 2)
    }

    private let deviceID = "6f1e2a3b-4c5d-4e6f-8a7b-9c0d1e2f3a4b"

    private func makeRegistration(_ transport: MockTransport) -> DeviceRegistration {
        DeviceRegistration(appHostID: appHost, eventBaseURL: "https://gateway.example", transport: transport)
    }

    private func credentials(alert: String? = nil, voip: String? = nil) -> DeviceCredentials {
        DeviceCredentials(
            deviceID: deviceID, bundleID: "com.example.RemoteCoder", apnsEnvironment: "development",
            alertToken: alert, voipToken: voip, location: nil
        )
    }

    private func token(_ seed: UInt8) -> String {
        String(repeating: String(format: "a%x", seed), count: 32)
    }
}

private actor MockTransport: DeviceRegistrationTransport {
    struct Refused: Error {}

    private(set) var registered: [DeviceRegistrationRequest] = []
    private(set) var unregistered: [String] = []
    private var connection: UUID? = UUID()
    private var dropsConnection: Bool
    private var failures: Int
    private let routingID: UUID

    init(routingID: UUID, dropsConnectionDuringFirstRegister: Bool = false, failures: Int = 0) {
        self.routingID = routingID
        dropsConnection = dropsConnectionDuringFirstRegister
        self.failures = failures
    }

    var connectionIdentity: UUID? { connection }

    func reconnect() { connection = UUID() }

    func connectIfNeeded() async throws {
        if connection == nil { connection = UUID() }
    }

    func registerDevice(_ request: DeviceRegistrationRequest) async throws -> DeviceRegistrationResponse {
        registered.append(request)
        if failures > 0 {
            failures -= 1
            throw Refused()
        }
        if dropsConnection {
            dropsConnection = false
            connection = UUID()
        }
        return DeviceRegistrationResponse(hostId: routingID)
    }

    func unregisterDevice(deviceID: String) async throws {
        unregistered.append(deviceID)
    }
}
