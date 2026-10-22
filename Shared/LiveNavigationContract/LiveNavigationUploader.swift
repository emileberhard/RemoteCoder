import CryptoKit
import Foundation

enum LiveNavigationUploader {
    private struct EncryptedRequest: Encodable {
        let sessionId: String
        let sequence: UInt64
        let ephemeralPublicKey: String
        let sealedPayload: String
    }

    static func upload(
        _ event: LiveNavigationEvent,
        using command: LiveNavigationCommand,
        session: URLSession = .shared
    ) async throws -> LiveNavigationUploadResponse {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        guard let serverKeyData = Data(base64URLEncoded: command.serverPublicKey) else {
            throw LiveNavigationError.invalidServerKey
        }
        let serverKey: Curve25519.KeyAgreement.PublicKey
        do {
            serverKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverKeyData)
        } catch {
            throw LiveNavigationError.invalidServerKey
        }

        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: serverKey)
        let key = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(command.sessionId.utf8),
            sharedInfo: LiveNavigationConstants.keyDerivationInfo,
            outputByteCount: 32
        )
        let eventData = try JSONEncoder().encode(event)
        let sealed = try ChaChaPoly.seal(eventData, using: key)
        let combined = sealed.combined

        let body = EncryptedRequest(
            sessionId: command.sessionId,
            sequence: event.sequence,
            ephemeralPublicKey: privateKey.publicKey.rawRepresentation.base64URLEncodedString(),
            sealedPayload: combined.base64URLEncodedString()
        )
        var request = URLRequest(url: command.eventUploadURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(command.uploadToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LiveNavigationError.invalidUploadResponse(0, "non-HTTP response")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "empty response"
            throw LiveNavigationError.invalidUploadResponse(http.statusCode, detail)
        }
        return try JSONDecoder().decode(LiveNavigationUploadResponse.self, from: data)
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: padding))
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
