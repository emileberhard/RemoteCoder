#if RC_PERF_HARNESS || SWIFT_PACKAGE
import CryptoKit
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

    func read(_ range: Range<Int>, root: URL) throws -> [JSONValue] {
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
        return try lines.map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
}
#endif
