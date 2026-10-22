import Compression
import Foundation

/// Wraps Apple's raw DEFLATE encoder in a gzip container.
///
/// `Compression`'s `COMPRESSION_ZLIB` emits RFC 1951 DEFLATE with no framing,
/// and Foundation ships no gzip writer, so the ten-byte header, CRC32 and
/// length trailer are assembled here. Log segments upload gzipped because the
/// host stores them verbatim and `gunzip` has to be able to read them back.
enum GzipEncoding {
    /// Returns `nil` only when the encoder itself fails, which in practice
    /// means an allocation failure — the caller falls back to skipping the
    /// segment rather than shipping something the host cannot open.
    static func gzipped(_ data: Data) -> Data? {
        guard let deflated = deflate(data) else { return nil }

        var out = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF])
        out.append(deflated)
        out.append(littleEndian: crc32(data))
        out.append(littleEndian: UInt32(truncatingIfNeeded: data.count))
        return out
    }

    private static func deflate(_ data: Data) -> Data? {
        if data.isEmpty { return Data() }
        // DEFLATE can expand incompressible input; the slack covers its worst
        // case plus the per-block overhead.
        let capacity = data.count + (data.count / 2) + 1024
        var output = Data(count: capacity)

        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return data.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_encode_buffer(
                    destinationBase,
                    capacity,
                    sourceBase,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard written > 0 else { return nil }
        output.removeSubrange(written...)
        return output
    }

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(littleEndian value: UInt32) {
        append(contentsOf: [
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24),
        ])
    }
}
