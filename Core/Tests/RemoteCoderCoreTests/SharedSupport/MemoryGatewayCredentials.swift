import Foundation
import Security
import Synchronization
#if canImport(RemoteCoderCore)
@testable import RemoteCoderCore
#else
@testable import RemoteCoder
#endif

final class MemoryGatewayCredentials: GatewayCredentialStorage {
    private struct State { var data: Data?; var failure: OSStatus?; var failReadback = false }
    private let state = Mutex(State())
    func read() throws -> Data? {
        try state.withLock { value in
            if let failure = value.failure { throw GatewayCredentialFailure.keychain(failure) }
            return value.failReadback ? nil : value.data
        }
    }
    func write(_ data: Data) throws {
        try state.withLock { value in
            if let failure = value.failure { throw GatewayCredentialFailure.keychain(failure) }
            value.data = data
        }
    }
    func fail(with status: OSStatus?) { state.withLock { $0.failure = status } }
    func failReadback() { state.withLock { $0.failReadback = true } }
}

