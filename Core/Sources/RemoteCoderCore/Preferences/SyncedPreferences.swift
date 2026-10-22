import Foundation

struct PreferenceEntry: Codable, Equatable, Sendable {
    static let syncedVersions: ClosedRange<UInt64> = 1...(1 << 53) - 1

    let value: JSONValue
    let updatedAt: UInt64
    let device: String

    func supersedes(_ other: PreferenceEntry) -> Bool {
        (updatedAt, device) > (other.updatedAt, other.device)
    }
}

struct PreferenceDocument: Codable, Equatable, Sendable {
    let entries: [String: PreferenceEntry]
}

struct PreferenceReplica: Codable, Equatable, Sendable {
    let device: String
    private(set) var entries: [String: PreferenceEntry] = [:]

    init(device: String) {
        self.device = device
    }

    mutating func adopt(_ key: String, value: JSONValue) {
        guard entries[key] == nil else { return }
        entries[key] = PreferenceEntry(value: value, updatedAt: 0, device: device)
    }

    mutating func record(_ key: String, value: JSONValue, at now: UInt64) {
        let floor = entries[key].map { $0.updatedAt + 1 } ?? 0
        entries[key] = PreferenceEntry(value: value, updatedAt: max(now, floor), device: device)
    }

    mutating func merge(_ received: [String: PreferenceEntry]) -> [String: JSONValue] {
        var changedValues: [String: JSONValue] = [:]
        for (key, entry) in received where entries[key].map(entry.supersedes) ?? true {
            if entries[key]?.value != entry.value { changedValues[key] = entry.value }
            entries[key] = entry
        }
        return changedValues
    }

    func newer(than host: [String: PreferenceEntry]) -> [String: PreferenceEntry] {
        entries.filter { key, entry in
            PreferenceEntry.syncedVersions.contains(entry.updatedAt) && (host[key].map(entry.supersedes) ?? true)
        }
    }
}

extension JSONValue {
    init?(propertyList object: Any) {
        switch object {
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let array as [Any]:
            let values = array.compactMap(JSONValue.init(propertyList:))
            guard values.count == array.count else { return nil }
            self = .array(values)
        case let dictionary as [String: Any]:
            let values = dictionary.compactMapValues(JSONValue.init(propertyList:))
            guard values.count == dictionary.count else { return nil }
            self = .object(values)
        default:
            return nil
        }
    }

    var propertyList: Any? {
        switch self {
        case .null:
            return nil
        case .bool(let value):
            return value
        case .number(let value):
            return value
        case .string(let value):
            return value
        case .array(let values):
            let converted = values.compactMap(\.propertyList)
            return converted.count == values.count ? converted : nil
        case .object(let values):
            let converted = values.compactMapValues(\.propertyList)
            return converted.count == values.count ? converted : nil
        }
    }
}
