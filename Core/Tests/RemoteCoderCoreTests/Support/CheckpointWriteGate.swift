import Foundation
import SQLite3
import Synchronization
@testable import RemoteCoderCore

private let checkpointWriteGate = Mutex<CheckpointWriteGate?>(nil)
private let checkpointWriteVFS = CheckpointWriteVFS()
private let checkpointFileMethods = Mutex<[UInt: CheckpointFileMethods]>([:])

private let writeCheckpointFile: @convention(c) (UnsafeMutablePointer<sqlite3_file>?, UnsafeRawPointer?, Int32, Int64) -> Int32 = { file, bytes, count, offset in
    guard let file, let methods = checkpointFileMethods.withLock({ $0[UInt(bitPattern: file)] }),
          let write = methods.original.pointee.xWrite else { preconditionFailure() }
    methods.gate.reachedWrite()
    return write(file, bytes, count, offset)
}

private let closeCheckpointFile: @convention(c) (UnsafeMutablePointer<sqlite3_file>?) -> Int32 = { file in
    guard let file, let methods = checkpointFileMethods.withLock({ $0.removeValue(forKey: UInt(bitPattern: file)) }),
          let close = methods.original.pointee.xClose else { preconditionFailure() }
    file.pointee.pMethods = methods.original
    return close(file)
}

private let openCheckpointFile: @convention(c) (UnsafeMutablePointer<sqlite3_vfs>?, UnsafePointer<CChar>?, UnsafeMutablePointer<sqlite3_file>?, Int32, UnsafeMutablePointer<Int32>?) -> Int32 = { _, filename, file, flags, outputFlags in
    let original = checkpointWriteVFS.original
    guard let open = original.pointee.xOpen else { preconditionFailure() }
    let result = open(original, filename, file, flags, outputFlags)
    guard result == SQLITE_OK, let filename, let file, let methods = file.pointee.pMethods else { return result }
    let path = URL(fileURLWithPath: String(cString: filename)).resolvingSymlinksInPath().path
    let gate = checkpointWriteGate.withLock { gate in
        gate.flatMap { path == $0.file.path || path == $0.file.path + "-wal" ? $0 : nil }
    }
    if let gate {
        let wrapped = CheckpointFileMethods(original: methods, gate: gate)
        checkpointFileMethods.withLock { $0[UInt(bitPattern: file)] = wrapped }
        file.pointee.pMethods = UnsafePointer(wrapped.wrapped)
    }
    return result
}

private final class CheckpointFileMethods: @unchecked Sendable {
    let original: UnsafePointer<sqlite3_io_methods>
    let wrapped: UnsafeMutablePointer<sqlite3_io_methods>
    let gate: CheckpointWriteGate

    init(original: UnsafePointer<sqlite3_io_methods>, gate: CheckpointWriteGate) {
        self.original = original
        self.gate = gate
        wrapped = .allocate(capacity: 1)
        wrapped.initialize(to: original.pointee)
        wrapped.pointee.xWrite = writeCheckpointFile
        wrapped.pointee.xClose = closeCheckpointFile
    }

    deinit { wrapped.deinitialize(count: 1); wrapped.deallocate() }
}

private final class CheckpointWriteVFS: @unchecked Sendable {
    let original: UnsafeMutablePointer<sqlite3_vfs>
    let wrapped: UnsafeMutablePointer<sqlite3_vfs>

    init() {
        guard let original = sqlite3_vfs_find(nil) else { preconditionFailure() }
        self.original = original
        wrapped = .allocate(capacity: 1)
        wrapped.initialize(to: original.pointee)
        wrapped.pointee.pNext = nil
        wrapped.pointee.zName = UnsafePointer(strdup("RemoteCoderCheckpointWriteGate"))
        wrapped.pointee.xOpen = openCheckpointFile
    }

    deinit {
        free(UnsafeMutablePointer(mutating: wrapped.pointee.zName))
        wrapped.deinitialize(count: 1)
        wrapped.deallocate()
    }
}

final class CheckpointWriteGate: Sendable {
    fileprivate let file: URL
    private let armed = Mutex(false)
    private let released = DispatchSemaphore(value: 0)
    private let arrivals = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))

    fileprivate init(file: URL) throws {
        self.file = file.resolvingSymlinksInPath()
        checkpointWriteGate.withLock {
            precondition($0 == nil)
            $0 = self
        }
        let code = sqlite3_vfs_register(checkpointWriteVFS.wrapped, 1)
        guard code == SQLITE_OK else {
            checkpointWriteGate.withLock { $0 = nil }
            throw CheckpointDatabase.Failure(operation: "install test write gate", code: code, detail: "SQLite rejected the write VFS")
        }
    }

    func arm() { armed.withLock { $0 = true } }

    fileprivate func reachedWrite() {
        let shouldWait = armed.withLock {
            guard $0 else { return false }
            $0 = false
            return true
        }
        guard shouldWait else { return }
        arrivals.continuation.yield(())
        released.wait()
    }

    func waitForWrite() async throws {
        var iterator = arrivals.stream.makeAsyncIterator()
        guard await iterator.next() != nil else { throw CancellationError() }
    }

    func release() { released.signal() }

    fileprivate func close() {
        release()
        checkpointWriteGate.withLock { $0 = nil }
        arrivals.continuation.finish()
    }
}

@MainActor
func withCheckpointWriteGate(_ file: URL, operation: (CheckpointWriteGate) async throws -> Void) async throws {
    let gate = try CheckpointWriteGate(file: file)
    defer { gate.close() }
    try await operation(gate)
}
