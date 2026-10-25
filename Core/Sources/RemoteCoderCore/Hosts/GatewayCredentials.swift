import Foundation
import OSLog
import Security

protocol GatewayCredentialStorage: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

/// Store the endpoint and credential together so an interrupted edit cannot pair
/// a new token with the previous endpoint.
struct KeychainGatewayCredentials: GatewayCredentialStorage {
    enum Scope: Equatable, Sendable {
        case device
        case iCloud
        case relayRoute(hostID: UUID)
    }

    private static let logger = AppLogger(category: "GatewayCredentials")
    let scope: Scope

    private func query(dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "emileberhard.RemoteCoder.gateway-configuration",
            kSecUseDataProtectionKeychain as String: dataProtection]
        switch scope {
        case .device:
            query[kSecAttrAccount as String] = "hosts-v2"
        case .iCloud:
            query[kSecAttrAccount as String] = "host-directory-v1"
            query[kSecAttrSynchronizable as String] = true
        case .relayRoute(let hostID):
            query[kSecAttrAccount as String] = "relay-route-v1.\(hostID.uuidString)"
        }
        return query
    }

    func read() throws -> Data? {
        if let data = try Self.copy(query(dataProtection: true)) { return data }
        #if os(macOS)
        guard scope == .device else { return nil }
        return try migrateFileKeychainItem()
        #else
        return nil
        #endif
    }

    func write(_ data: Data) throws {
        let match = query(dataProtection: true)
        let attributes = [kSecValueData as String: data]
        var status = SecItemUpdate(match as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = match
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = scope == .iCloud
                ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(match as CFDictionary, attributes as CFDictionary)
            }
        }
        guard status == errSecSuccess else { throw GatewayCredentialFailure.keychain(status) }
    }

    private static func copy(_ query: [String: Any]) throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw GatewayCredentialFailure.keychain(status) }
        guard let data = result as? Data else { throw GatewayCredentialFailure.invalidData }
        return data
    }

    #if os(macOS)
    private func migrateFileKeychainItem() throws -> Data? {
        let fileKeychain = query(dataProtection: false)
        guard let data = try Self.copy(fileKeychain) else { return nil }
        try write(data)
        guard try Self.copy(query(dataProtection: true)) == data else {
            throw GatewayCredentialFailure.verificationFailed
        }
        let status = SecItemDelete(fileKeychain as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Self.logger.error("Moved gateway configuration to the data protection keychain but could not delete the file keychain copy (status \(status)).")
        }
        return data
    }
    #endif
}

enum GatewayCredentialFailure: LocalizedError {
    case keychain(OSStatus)
    case invalidData
    case verificationFailed
    case configurationUnavailable

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            if status == errSecInteractionNotAllowed {
                return "Gateway credentials are locked. Unlock this device and retry."
            }
            return "Gateway credentials are unavailable (Keychain status \(status)). Existing configuration has been preserved."
        case .invalidData:
            return "The saved gateway configuration could not be read. It has not been replaced."
        case .verificationFailed:
            return "The protected gateway configuration could not be verified. Existing configuration has been preserved."
        case .configurationUnavailable:
            return "Retry loading the saved gateway configuration before changing it."
        }
    }
}
