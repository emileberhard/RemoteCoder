import CryptoKit
import Foundation
import Security
import Synchronization

struct GatewayLANEndpoint: Codable, Equatable, Sendable {
    struct Invalid: Error {}

    let host: String
    let port: Int
    let spkiSHA256: Data

    private enum CodingKeys: String, CodingKey {
        case host, port
        case spkiSHA256 = "spkiSha256"
    }

    init(host: String, port: Int, spkiSHA256: Data) throws {
        guard !host.isEmpty, host.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == ".") }),
              (1...65535).contains(port), spkiSHA256.count == SHA256.byteCount else { throw Invalid() }
        self.host = host
        self.port = port
        self.spkiSHA256 = spkiSHA256
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(host: values.decode(String.self, forKey: .host), port: values.decode(Int.self, forKey: .port),
                spkiSHA256: values.decode(Data.self, forKey: .spkiSHA256))
        } catch is Invalid {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "The LAN endpoint needs a DNS host name, a port and a 32-byte SPKI pin."))
        }
    }
}

enum GatewaySPKIPin {
    private static let p256SPKIHeader = Data([
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
        0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
    ])

    static func spkiSHA256(of certificate: SecCertificate) -> Data? {
        guard let key = SecCertificateCopyKey(certificate),
              let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
              attributes[kSecAttrKeyType] as? String == kSecAttrKeyTypeECSECPrimeRandom as String,
              attributes[kSecAttrKeySizeInBits] as? Int == 256,
              let point = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              point.count == 65, point.first == 0x04 else { return nil }
        return Data(SHA256.hash(data: p256SPKIHeader + point))
    }

    static func matches(_ trust: SecTrust, pin: Data) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first, let actual = spkiSHA256(of: leaf) else { return false }
        return actual == pin
    }
}

final class GatewayLANTrust: NSObject, URLSessionTaskDelegate, Sendable {
    private let pin: Mutex<Data?>

    init(pin: Data?) {
        self.pin = Mutex(pin)
    }

    func replacePin(_ pin: Data?) {
        self.pin.withLock { $0 = pin }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        answer(challenge)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        answer(challenge)
    }

    private func answer(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        guard accepts(trust) else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    func accepts(_ trust: SecTrust) -> Bool {
        guard let pin = pin.withLock({ $0 }) else { return false }
        return GatewaySPKIPin.matches(trust, pin: pin)
    }
}
