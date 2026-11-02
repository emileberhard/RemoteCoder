import Foundation

protocol GatewayCredentialEnrolling: Sendable {
    func enroll(host: GatewayHostConfiguration, installationID: String) async throws -> String
    func sharingCredential(host: GatewayHostConfiguration) async throws -> String
}

struct GatewayCredentialEnrollment: GatewayCredentialEnrolling {
    func enroll(host: GatewayHostConfiguration, installationID: String) async throws -> String {
        guard let base = host.gatewayHTTPBaseURL() else { throw GatewayClient.ClientError.invalidURL }
        var request = URLRequest(url: base.appending(path: "credentials/enroll"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(host.authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Enrollment(installationId: installationID, label: "RemoteCoder iOS"))
        let (data, response) = try await AppStorageScope.networkSession.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw GatewayClient.ClientError.invalidMessage }
        guard response.statusCode == 200 else { throw Failure(status: response.statusCode) }
        let result = try JSONDecoder().decode(Enrolled.self, from: data)
        guard result.token.hasPrefix("rc1.\(installationID)."), result.token.count <= 256 else {
            throw GatewayClient.ClientError.invalidMessage
        }
        return result.token
    }

    func sharingCredential(host: GatewayHostConfiguration) async throws -> String {
        guard let base = host.gatewayHTTPBaseURL(), host.usesInstallationCredential else {
            throw GatewayClient.ClientError.invalidURL
        }
        var request = URLRequest(url: base.appending(path: "credentials/share"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(host.authToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await AppStorageScope.networkSession.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw GatewayClient.ClientError.invalidMessage }
        guard response.statusCode == 200 else { throw Failure(status: response.statusCode) }
        let result = try JSONDecoder().decode(Enrolled.self, from: data)
        let installationID = host.authToken.split(separator: ".").dropFirst().first
        guard let installationID, result.token.hasPrefix("rcs1.\(installationID)."), result.token.count <= 256 else {
            throw GatewayClient.ClientError.invalidMessage
        }
        return result.token
    }

    private struct Enrollment: Encodable { let installationId: String; let label: String }
    private struct Enrolled: Decodable { let token: String }
    private struct Failure: LocalizedError {
        let status: Int
        var errorDescription: String? {
            "Installation enrollment was refused (HTTP \(status)). The existing gateway credential has been preserved."
        }
    }
}
