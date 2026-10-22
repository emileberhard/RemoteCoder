import Foundation
#if canImport(RemoteCoderCore)
@testable import RemoteCoderCore
#else
@testable import RemoteCoder
#endif

enum CodexModelFixtures {
    static let astraID = "gpt-6-astra"
    static let solID = "gpt-6.1-sol"
    static let lunaID = "gpt-5.6-luna"
    static let sparkID = "gpt-5.3-codex-spark"
    static let reserveID = "gpt-reserve"

    static func wireModels() -> [[String: Any]] {
        [
            wireModel(astraID, name: "GPT-6 Astra", efforts: ["low", "medium", "high", "xhigh", "max", "ultra"],
                      serviceTiers: ["priority"], isDefault: true),
            wireModel(solID, name: "GPT-6.1 Sol", efforts: ["low", "medium", "high", "xhigh", "max", "ultra"],
                      serviceTiers: ["priority"]),
            wireModel(lunaID, name: "GPT-5.6 Luna", efforts: ["low", "medium", "high", "xhigh", "max"],
                      additionalSpeedTiers: ["fast"]),
            wireModel(sparkID, name: "GPT-5.3 Codex Spark", efforts: ["minimal", "low", "medium", "high", "xhigh"],
                      inputModalities: ["text"]),
            wireModel(reserveID, name: "GPT-Reserve", efforts: ["low", "medium", "high"],
                      serviceTiers: ["priority"], hidden: true),
        ]
    }

    static func wireModel(
        _ id: String,
        name: String,
        efforts: [String],
        serviceTiers: [String] = [],
        additionalSpeedTiers: [String] = [],
        inputModalities: [String] = ["text", "image"],
        hidden: Bool = false,
        isDefault: Bool = false,
        cyberPrograms: [String]? = nil
    ) -> [String: Any] {
        var wire: [String: Any] = [
            "id": id,
            "model": id,
            "displayName": name,
            "description": "\(name) test model",
            "supportedReasoningEfforts": efforts.map { ["reasoningEffort": $0, "description": $0] },
            "defaultReasoningEffort": "medium",
            "inputModalities": inputModalities,
            "additionalSpeedTiers": additionalSpeedTiers,
            "serviceTiers": serviceTiers.map { ["id": $0, "name": $0, "description": $0] },
            "hidden": hidden,
            "isDefault": isDefault,
        ]
        if let cyberPrograms { wire["availableAccessPrograms"] = ["cyber": cyberPrograms] }
        return wire
    }

    static func models(_ wire: [[String: Any]] = wireModels()) throws -> [CodexAppServerV2.Model] {
        try JSONDecoder().decode([CodexAppServerV2.Model].self, from: JSONSerialization.data(withJSONObject: wire))
    }

    static func catalog() throws -> CodexModelCatalog {
        CodexModelCatalog(models: try models(), fetchedAt: Date(timeIntervalSince1970: 0))
    }

    struct MissingModel: Error {
        let id: String
    }

    static func option(_ id: String) throws -> ModelOption {
        guard let entry = try catalog().entry(for: id) else { throw MissingModel(id: id) }
        return entry.option
    }

    static func seed(hostID: UUID, storage: HostStorage,
                     models: [[String: Any]] = wireModels()) throws {
        let directory = storage.directory(for: .target(hostID: hostID))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot: [String: Any] = ["models": models, "fetchedAt": 0]
        try JSONSerialization.data(withJSONObject: snapshot).write(to: directory.appending(path: "codex-models.json"))
    }
}
