import Foundation
import Testing

@testable import RemoteCoderCore

struct CodexAppServerV2DiscoveryTests {
    @Test func modelListAcceptsOpenReasoningEffortsAndServiceTiers() throws {
        let json = """
        {
          "id": "gpt-5.6-sol",
          "model": "gpt-5.6-sol",
          "upgrade": null,
          "upgradeInfo": null,
          "displayName": "GPT-5.6 Sol",
          "description": "Frontier model",
          "supportedReasoningEfforts": [
            { "reasoningEffort": "low", "description": "Fast" },
            { "reasoningEffort": "xhigh", "description": "Deep" },
            { "reasoningEffort": "max", "description": "Maximum" },
            { "reasoningEffort": "ultra", "description": "Delegating" },
            { "reasoningEffort": "future", "description": "Forward compatible" }
          ],
          "defaultReasoningEffort": "ultra",
          "inputModalities": ["text", "image"],
          "additionalSpeedTiers": [],
          "serviceTiers": [
            { "id": "priority", "name": "Fast", "description": "1.5x speed" }
          ],
          "defaultServiceTier": null,
          "availabilityNux": null,
          "supportsPersonality": true,
          "hidden": false,
          "isDefault": true
        }
        """

        let model = try JSONDecoder().decode(CodexAppServerV2.Model.self, from: Data(json.utf8))

        #expect(model.supportedReasoningEfforts.last?.reasoningEffort.rawValue == "future")
        #expect(model.serviceTiers.first?.id == "priority")
    }
}
