import Compression
import Foundation
import Testing
@testable import RemoteCoderCore

struct GzipEncodingTests {
    @Test func crc32MatchesTheStandardCheckValue() {
        #expect(GzipEncoding.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func theDeflateBodyInflatesBackToTheOriginal() throws {
        let payload = Data(String(repeating: "a log line with some entropy 12345\n", count: 50).utf8)
        let gzipped = try #require(GzipEncoding.gzipped(payload))
        #expect(Array(gzipped.prefix(3)) == [0x1F, 0x8B, 0x08], "gzip magic and deflate method")
        let trailer = gzipped.suffix(8)
        let checksum = trailer.prefix(4).reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let size = trailer.suffix(4).reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        #expect(checksum == GzipEncoding.crc32(payload))
        #expect(size == UInt32(payload.count))
        #expect(gzipped.count < payload.count, "repetitive log text must compress")
        let deflated = gzipped.dropFirst(10).dropLast(8)

        var restored = Data(count: payload.count)
        let written = restored.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return Data(deflated).withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    destinationBase,
                    payload.count,
                    sourceBase,
                    deflated.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        #expect(written == payload.count)
        #expect(restored == payload)
    }

    @Test func emptyInputStillProducesAValidContainer() throws {
        let gzipped = try #require(GzipEncoding.gzipped(Data()))

        #expect(gzipped.count == 18, "header plus empty body plus trailer")
        #expect(Array(gzipped.prefix(2)) == [0x1F, 0x8B])
        #expect(Array(gzipped.suffix(8)) == [0, 0, 0, 0, 0, 0, 0, 0])
    }
}
