import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct ReasoningEffortVisibilityTests {
    @Test func defaultRangeEndsAtExtraHigh() throws {
        let codex = try [CodexModelFixtures.astraID, CodexModelFixtures.lunaID, CodexModelFixtures.sparkID]
            .map(CodexModelFixtures.option)
        for model in ClaudeModelCatalog.models + codex {
            let visibility = ReasoningEffortVisibility.defaultValue
            #expect(visibility.efforts(for: model) == [.low, .medium, .high, .xhigh], "\(model.id)")
            #expect(visibility.clamped(.effort(.max), for: model) == .effort(.xhigh), "\(model.id)")
            #expect(visibility.clamped(.effort(.ultra), for: model) == .effort(.xhigh), "\(model.id)")
        }
    }

    @Test func unlistedModelsKeepTheirReportedEffortRegardlessOfVisibility() {
        let model = ModelOption.unlisted(id: "gpt-retired", modelProvider: nil, reportedEffort: .ultra, reportedFastMode: false)
        let visibility = ReasoningEffortVisibility(rawValue: "medium")
        #expect(visibility.efforts(for: model) == [.ultra])
        #expect(visibility.clamped(.effort(.ultra), for: model) == .effort(.ultra))
    }

    @Test func clampsBothEndsAndUsesTheLowerNeighborForAnEquidistantHiddenLevel() throws {
        let model = try CodexModelFixtures.option(CodexModelFixtures.solID)
        let visibility = ReasoningEffortVisibility(rawValue: "medium,xhigh")
        #expect(visibility.clamped(.effort(.low), for: model) == .effort(.medium))
        #expect(visibility.clamped(.effort(.ultra), for: model) == .effort(.xhigh))
        #expect(visibility.clamped(.effort(.high), for: model) == .effort(.medium))
        #expect(visibility.clamped(.effort(.xhigh), for: model) == .effort(.xhigh))
        #expect(visibility.clamped(.automatic, for: model) == .automatic)
    }

    @Test func respectsModelCapabilitiesAndAllowsAutomaticWhenAllLevelsAreHidden() {
        let claude = ClaudeModelCatalog.defaultModel
        let visibility = ReasoningEffortVisibility(rawValue: "high,max,ultra")
        #expect(visibility.efforts(for: claude) == [.high, .max])
        #expect(visibility.clamped(.effort(.ultra), for: claude) == .effort(.max))
        #expect(ReasoningEffortVisibility(rawValue: "").clamped(.effort(.high), for: claude) == .automatic)
    }

    @Test func preferencesRoundTripIndependentlyAndAnEmptySelectionIsNotTheDefault() throws {
        let suite = "ReasoningEffortVisibilityTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ReasoningEffortVisibility.load(for: .codex, defaults: defaults) == .defaultValue)
        var codex = ReasoningEffortVisibility.defaultValue
        codex.setVisible(.max, true)
        codex.setVisible(.low, false)
        defaults.set(codex.rawValue, forKey: ReasoningEffortVisibility.codexKey)
        defaults.set("", forKey: ReasoningEffortVisibility.claudeKey)
        #expect(ReasoningEffortVisibility.load(for: .codex, defaults: defaults) == codex)
        #expect(ReasoningEffortVisibility.load(for: .claude, defaults: defaults).efforts(for: ClaudeModelCatalog.defaultModel).isEmpty)
    }
}
