import Foundation

struct BenchStreamPlan: Decodable, Sendable {
    enum Kind: String, Decodable, Sendable {
        case mixed, paragraph, code, table, conversation, fitTable = "fit-table", tableAppearance = "table-appearance"
        case wideTable = "wide-table", wideTableThenProse = "wide-table-then-prose"
    }

    let kind: Kind
    let seconds: Double
    let charsPerTick: Int
    let tickMs: Int

    private enum CodingKeys: CodingKey { case kind, seconds, charsPerTick, tickMs }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(Kind.self, forKey: .kind)
        seconds = try values.decode(Double.self, forKey: .seconds)
        charsPerTick = try values.decode(Int.self, forKey: .charsPerTick)
        tickMs = try values.decode(Int.self, forKey: .tickMs)
        guard seconds.isFinite, seconds > 0, seconds <= 120,
              (1...4096).contains(charsPerTick), (10...1000).contains(tickMs) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "stream requires seconds in (0, 120], charsPerTick in 1...4096, and tickMs in 10...1000"))
        }
        guard tickCount * charsPerTick <= 1_048_576 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "stream must produce at most 1 MiB of text"))
        }
    }

    var tickCount: Int { Int(ceil(seconds * 1000 / Double(tickMs))) }

    var report: [String: Any] {
        ["kind": kind.rawValue, "seconds": seconds, "charsPerTick": charsPerTick, "tickMs": tickMs,
         "expectedTicks": tickCount, "expectedCharacters": tickCount * charsPerTick]
    }
}
