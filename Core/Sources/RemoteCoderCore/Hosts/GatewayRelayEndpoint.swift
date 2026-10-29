import CryptoKit
import Foundation
import Network
import Security

struct GatewayRelayEndpoint: Codable, Equatable, Sendable {
    struct Invalid: Error {}

    let proxyHost: String
    let proxyPort: UInt16
    let proxySPKISHA256: Data
    let targetHost: String
    let targetPort: UInt16
    let username: String
    let password: String

    private enum CodingKeys: String, CodingKey {
        case proxyHost, proxyPort, targetHost, targetPort, username, password
        case proxySPKISHA256 = "proxySpkiSha256"
    }

    init(proxyHost: String, proxyPort: UInt16, proxySPKISHA256: Data, targetHost: String, targetPort: UInt16,
         username: String, password: String) throws {
        guard Self.isHost(proxyHost), Self.isHost(targetHost), proxyPort > 0, targetPort > 0,
              proxySPKISHA256.count == SHA256.byteCount,
              !username.isEmpty, !username.contains(":"), !password.isEmpty else { throw Invalid() }
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.proxySPKISHA256 = proxySPKISHA256
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.username = username
        self.password = password
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(proxyHost: values.decode(String.self, forKey: .proxyHost),
                proxyPort: values.decode(UInt16.self, forKey: .proxyPort),
                proxySPKISHA256: values.decode(Data.self, forKey: .proxySPKISHA256),
                targetHost: values.decode(String.self, forKey: .targetHost),
                targetPort: values.decode(UInt16.self, forKey: .targetPort),
                username: values.decode(String.self, forKey: .username),
                password: values.decode(String.self, forKey: .password))
        } catch is Invalid {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "The relay endpoint needs host names, ports, a credential and a 32-byte SPKI pin."))
        }
    }

    func proxyConfiguration() -> ProxyConfiguration {
        let tls = NWProtocolTLS.Options()
        let pin = proxySPKISHA256
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            complete(GatewaySPKIPin.matches(sec_trust_copy_ref(trust).takeRetainedValue(), pin: pin))
        }, Self.verification)
        let proxy = ProxyConfiguration(
            httpCONNECTProxy: .hostPort(host: NWEndpoint.Host(proxyHost), port: NWEndpoint.Port(integerLiteral: proxyPort)),
            tlsOptions: tls)
        proxy.applyCredential(username: username, password: password)
        return proxy
    }

    private static let verification = DispatchQueue(label: "RemoteCoder.GatewayRelay.verify")

    private static func isHost(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == ".") }
    }
}
