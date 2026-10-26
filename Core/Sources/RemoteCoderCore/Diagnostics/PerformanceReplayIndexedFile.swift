#if RC_PERF_HARNESS || SWIFT_PACKAGE
import CryptoKit
import Darwin
import Foundation

struct PerformanceReplayIndexedFile: Codable, Sendable {
    let path: String
    let offsets: [UInt64]
    let sha256: String

    func validate() throws {
        guard path.hasPrefix("history/"), path.split(separator: "/").count == 2,
              !path.contains(".."), offsets.count >= 1, offsets.count <= 20_001,
              offsets.first == 0, (offsets.last ?? 0) <= 24 * 1_048_576,
              zip(offsets, offsets.dropFirst()).allSatisfy({ $0 < $1 }),
              sha256.count == 64, sha256.allSatisfy(\.isHexDigit) else {
            throw PerformanceReplayScenario.Failure.invalidScenario("invalid indexed history")
        }
    }

    private func url(root: URL) throws -> URL {
        let url = root.appending(path: path).resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
            throw PerformanceReplayScenario.Failure.invalidScenario("history escapes fixture directory")
        }
        return url
    }

    func verify(root: URL) throws {
        try validate()
        let handle = try FileHandle(forReadingFrom: url(root: root))
        defer { try? handle.close() }
        guard try handle.seekToEnd() == offsets.last else {
            throw PerformanceReplayScenario.Failure.invalidScenario("indexed history size differs")
        }
        try handle.seek(toOffset: 0)
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty { hash.update(data: chunk) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw PerformanceReplayScenario.Failure.invalidScenario("indexed history digest differs")
        }
    }

    func records(_ range: Range<Int>, root: URL) throws -> [Data] {
        guard range.lowerBound >= 0, range.upperBound < offsets.count, range.count <= 100 else {
            throw PerformanceReplayScenario.Failure.invalidScenario("history page exceeds bounds")
        }
        let count = offsets[range.upperBound] - offsets[range.lowerBound]
        guard count <= 16 * 1_048_576 else { throw PerformanceReplayScenario.Failure.invalidScenario("history page exceeds 16 MiB") }
        let handle = try FileHandle(forReadingFrom: url(root: root))
        defer { try? handle.close() }
        try handle.seek(toOffset: offsets[range.lowerBound])
        guard let data = try handle.read(upToCount: Int(count)), data.count == count else {
            throw PerformanceReplayScenario.Failure.invalidScenario("truncated history page")
        }
        let lines = data.split(separator: 10)
        guard lines.count == range.count else { throw PerformanceReplayScenario.Failure.invalidScenario("history index does not match records") }
        return lines.map { Data($0) }
    }
    func read(_ range: Range<Int>, root: URL) throws -> [JSONValue] {
        try records(range, root: root).map { try JSONDecoder().decode(JSONValue.self, from: $0) }
    }

    func prepared(root: URL, destination: URL, path: String, offset: Double) throws -> Self {
        try verify(root: root)
        let target = destination.appending(path: path)
        guard target.deletingLastPathComponent().resolvingSymlinksInPath().path.hasPrefix(destination.resolvingSymlinksInPath().path + "/") else {
            throw PerformanceReplayScenario.Failure.invalidScenario("prepared history escapes destination")
        }
        let descriptor = open(target.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            throw PerformanceReplayScenario.Failure.invalidScenario("could not create prepared history")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var generated: [UInt64] = [0]
        var hash = SHA256()
        var lower = 0
        while lower < offsets.count - 1 {
            var upper = min(offsets.count - 1, lower + 100)
            while upper > lower + 1 && offsets[upper] - offsets[lower] > 16 * 1_048_576 { upper -= 1 }
            for value in try read(lower..<upper, root: root) {
                var data = try JSONEncoder().encode(PerformanceReplayScenario.shift(value, by: offset))
                data.append(10)
                let size = (generated.last ?? 0) + UInt64(data.count)
                guard size <= 24 * 1_048_576 else {
                    throw PerformanceReplayScenario.Failure.invalidScenario("prepared history exceeds 24 MiB")
                }
                try handle.write(contentsOf: data)
                hash.update(data: data)
                generated.append(size)
            }
            lower = upper
        }
        return Self(path: path, offsets: generated,
            sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
#endif
