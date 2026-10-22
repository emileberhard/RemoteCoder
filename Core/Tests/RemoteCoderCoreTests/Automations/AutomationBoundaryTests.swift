import Foundation
import Testing
@testable import RemoteCoderCore

struct AutomationBoundaryTests {
    @Test func editingNamePreservesUnavailableTargetsAndAdvancedFields() throws {
        let body = Data(#"{"id":"nightly","enabled":true,"name":"Old","when":[{"every":"1h","timezone":"Europe/Stockholm","match":{}}],"run":{"agent":{"provider":"codex","prompt":"Exact\nprompt","gateway_host":"retired-host","account":{"id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","generation":7},"model":"model-no-longer-listed","checkpoint":{"origin_thread_id":"thread-old"},"future_option":{"x":true}}},"filter":{"command":["/bin/test","-f","/tmp/ready"],"timeout":30},"tags":["keep"]}"#.utf8)
        let definition = try JSONDecoder().decode(AutomationDefinition.self, from: body)
        var draft = AutomationDraft(definition: definition, expectedRevision: 12)
        draft.set(.string("New"), at: ["name"])
        let request = draft.saveRequest(requestID: "stable-save")
        #expect(request.expectedRevision == 12)
        var expected = definition.fields["run"]?.objectValue ?? [:]
        var agent = expected["agent"]?.objectValue ?? [:]
        agent.removeValue(forKey: "account")
        expected["agent"] = .object(agent)
        #expect(request.data?["run"] == .object(expected))
        #expect(request.data?["filter"] == definition.fields["filter"])
        #expect(request.data?["when"] == definition.fields["when"])
        #expect(request.data?["tags"] == .array([.string("keep")]))
        #expect(request.data?["name"] == .string("New"))
    }

    @Test func publicRequestUsesCamelCaseAndKeepsDefinitionSnakeCase() throws {
        let request = AutomationRequest(id: "job", data: ["max_age": .string("1h"), "run": .object(["agent": .object(["gateway_host": .string("gateway-primary")])])],
                                        requestId: "original", expectedRevision: 0, targetRevision: 2)
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(request))
        #expect(value.objectValue?["requestId"] == .string("original"))
        #expect(value.objectValue?["expectedRevision"] == .number(0))
        #expect(value.objectValue?["targetRevision"] == .number(2))
        #expect(value.objectValue?["expected_revision"] == nil)
        #expect(value.objectValue?["data"]?.objectValue?["max_age"] == .string("1h"))
        #expect(value.objectValue?["data"]?.objectValue?["run"]?.objectValue?["agent"]?.objectValue?["gateway_host"] == .string("gateway-primary"))
        #expect(value.objectValue?["runId"] == nil)
    }

    @Test func completeSaveAndRestoreExpressOptionalDeletionWithoutDroppingUneditedFields() {
        let definition = AutomationDefinition(fields: ["id": .string("job"), "enabled": .bool(true),
            "max_age": .string("1h"), "tags": .array([.string("preserved")]),
            "run": .object(["agent": .object(["prompt": .string("keep"), "session_id": .string("old-thread"),
                "checkpoint": .object(["id": .string("old-checkpoint")]), "future_option": .bool(true)])])])
        var draft = AutomationDraft(definition: definition, expectedRevision: 7, sourceRevision: 3)
        draft.set(nil, at: ["max_age"])
        draft.set(nil, at: ["run", "agent", "session_id"])
        draft.set(nil, at: ["run", "agent", "checkpoint"])
        for request in [draft.saveRequest(requestID: "save"), draft.restoreRequest(requestID: "restore", enabled: false)] {
            #expect(request.replaceDefinition == true)
            #expect(request.data?["max_age"] == nil)
            #expect(request.data?["run"]?.objectValue?["agent"]?.objectValue?["session_id"] == nil)
            #expect(request.data?["run"]?.objectValue?["agent"]?.objectValue?["checkpoint"] == nil)
            #expect(request.data?["run"]?.objectValue?["agent"]?.objectValue?["future_option"] == .bool(true))
            #expect(request.data?["tags"] == .array([.string("preserved")]))
            #expect(request.expectedRevision == 7)
        }
    }

    @Test func multipleTriggersKeepOtherTriggersAndTypedMatchValues() throws {
        let definition = AutomationDefinition(fields: ["id": .string("events"), "when": .array([
            .object(["event": .string("first"), "match": .object(["/data/count": .number(2)])]),
            .object(["imessage": .number(42), "timezone": .string("Europe/Stockholm")])
        ])])
        var draft = AutomationDraft(definition: definition, expectedRevision: 3)
        draft.setTrigger(["event": .string("changed"), "match": .object(["/data/count": .number(2)])], index: 0)
        #expect(draft.definition.triggers[1]["imessage"] == .number(42))
        #expect(draft.definition.triggers[0]["match"] == .object(["/data/count": .number(2)]))
    }

    @Test func serviceConflictIsStructuredAndNotAnEmptySuccess() throws {
        let bytes = Data(#"{"ok":false,"error":{"code":"conflict","message":"Changed elsewhere","hint":"Reload","current_revision":9},"health":{"ok":true}}"#.utf8)
        let result = try JSONDecoder().decode(AutomationEnvelope<AutomationList>.self, from: bytes)
        do { _ = try result.value(); Issue.record("Conflict must fail") }
        catch let error as AutomationServiceError { #expect(error.isConflict); #expect(error.currentRevision == 9) }
    }

    @Test func inventoryAndHistoricalRunCoverageDecodeActualServiceShape() throws {
        let inventory = Data(#"{"ok":true,"data":{"items":[{"id":"old","name":"Archived name","revision":5,"enabled":false,"removed":true,"next_due":null,"last_run":{"id":"r","state":"uncertain","created":100,"finished":null,"error":null},"when":{"event":"event.v1"}}],"limit":50,"offset":0},"health":{"ok":true,"issues":[]}}"#.utf8)
        let value = try JSONDecoder().decode(AutomationEnvelope<AutomationList>.self, from: inventory).value()
        #expect(value.items[0].isRemoved)
        #expect(value.items[0].lastRun?.isActive == true)
        let historical = Data(#"{"ok":true,"data":{"id":"legacy","state":"succeeded","revision":6,"definition_history":"legacy_snapshot","output":"","output_coverage":{"available":false},"receipt":null}}"#.utf8)
        let run = try JSONDecoder().decode(AutomationEnvelope<AutomationRunDetail>.self, from: historical).value()
        #expect(run.definitionHistory == "legacy_snapshot")
        #expect(run.revision == 6)
    }

    @Test func conversationRouteRequiresActualHostAndThreadAndIgnoresRetiredAccount() throws {
        let receipt: JSONValue = .object(["gateway_host": .string("gateway-secondary"), "thread_id": .string("thread-live"),
            "gateway_account": .object(["id": .string("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"), "generation": .number(3)])])
        let route = try #require(AutomationExecutionRoute(receipt: receipt))
        #expect(route.host == "gateway-secondary")
        #expect(AutomationExecutionRoute(receipt: .object(["gateway_host": .string("auto")])) == nil)
        #expect(AutomationExecutionRoute(receipt: .object(["gateway_host": .string("mini"), "thread_id": .string("thread"),
            "gateway_account": .object(["id": .string("broken"), "generation": .number(3)])])) != nil)
    }

    @Test func selectingClaudeDropsTheEnrollmentAndOldClaudeReceiptsUseTheHost() throws {
        var draft = AutomationDraft.new()
        let account: JSONValue = .object(["id": .string("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"), "generation": .number(7)])
        draft.set(account, at: ["run", "agent", "account"])
        draft.chooseProvider("codex")
        #expect(draft.definition.agent?["account"] == nil)
        draft.chooseProvider("claude")
        #expect(draft.definition.agent?["account"] == nil)
        let route = try #require(AutomationExecutionRoute(receipt: .object([
            "gateway_host": .string("gateway-secondary"), "thread_id": .string("claude_old"), "gateway_account": account
        ])))
        #expect(route.host == "gateway-secondary")
        #expect(route.threadID == "claude_old")
    }

    @Test func restoreCarriesSourceAndCurrentRevisionAndExplicitPausedChoice() {
        var draft = AutomationDraft.new()
        draft.set(.string("saved"), at: ["id"])
        draft.expectedRevision = 8; draft.sourceRevision = 2
        let request = draft.restoreRequest(requestID: "restore-stable", enabled: false)
        #expect(request.targetRevision == 2)
        #expect(request.expectedRevision == 8)
        #expect(request.data?["enabled"] == .bool(false))
        #expect(request.id == "saved")
    }

    @Test func diffSeparatesPromptFromConfigurationAndReportsRemovedFields() async throws {
        let old = AutomationDefinition(fields: ["name": .string("Before"), "tags": .array([.string("obsolete")]), "run": .object(["agent": .object(["prompt": .string("one\ntwo"), "model": .string("saved-model")])])])
        let new = AutomationDefinition(fields: ["name": .string("After"), "run": .object(["agent": .object(["prompt": .string("one\nthree"), "model": .string("saved-model")])])])
        let diff = try await AutomationDocuments.compare(old, new)
        #expect(diff.fields.map(\.path) == ["name", "tags"])
        #expect(diff.promptChanges == [AutomationFieldChange(path: "Line 2", before: "two", after: "three")])
    }
}

struct AutomationGatewayFailureTests {
    @Test func rejectedAndUncertainMutationsRemainDistinct() throws {
        let rejected = try #require(GatewayRPCFailure(code: -32003, message: "Mini unavailable", data: .object([
            "kind": .string("automationUnavailable"), "retryable": .bool(true)
        ])))
        let uncertain = try #require(GatewayRPCFailure(code: -32003, message: "Lost acknowledgement", data: .object([
            "kind": .string("automationAcknowledgementUnknown"), "retryable": .bool(true), "requestId": .string("original")
        ])))
        #expect(!AutomationMutationFailure.acknowledgementUnknown(rejected))
        #expect(AutomationMutationFailure.acknowledgementUnknown(uncertain))
        #expect(!AutomationMutationFailure.acknowledgementUnknown(GatewayClient.ClientError.serverError(message: "Invalid request", code: -32602)))
        #expect(AutomationMutationFailure.acknowledgementUnknown(GatewayClient.ClientError.requestTimedOut(method: "automations/set")))
    }
}

struct AutomationReviewRegressionTests {
    @Test func physicalHostResolutionNeverGuessesByFirstDNSComponent() {
        let mini = GatewayHostConfiguration(id: UUID(), name: "Mini", hostname: "mini.alpha.example", port: 8787, authToken: "test")
        let other = GatewayHostConfiguration(id: UUID(), name: "Other", hostname: "mini.beta.example", port: 8787, authToken: "test")
        let hosts = [mini, other]
        #expect(AutomationHostResolver.resolve("mini.alpha.example", hosts: hosts, reportedHostnames: [:])?.id == mini.id)
        #expect(AutomationHostResolver.resolve("mini", hosts: hosts, reportedHostnames: [:]) == nil)
        #expect(AutomationHostResolver.resolve("mini.unregistered.example", hosts: hosts, reportedHostnames: [:]) == nil)
        #expect(AutomationHostResolver.resolve("physical-primary", hosts: hosts, reportedHostnames: [mini.id: "physical-primary"])?.id == mini.id)
        let duplicate = GatewayHostConfiguration(id: UUID(), name: "Duplicate", hostname: mini.hostname, port: 8787, authToken: "test")
        #expect(AutomationHostResolver.resolve(mini.hostname, hosts: [mini, duplicate], reportedHostnames: [mini.id: "physical-primary", duplicate.id: "physical-primary"]) == nil)
        #expect(AutomationHostResolver.resolve("physical-primary", hosts: [mini, duplicate], reportedHostnames: [mini.id: "physical-primary", duplicate.id: "physical-primary"]) == nil)
    }

    @Test func dirtyAdvancedBufferSurvivesFormChangesUntilExplicitReconciliation() {
        let original = AutomationDefinition(fields: ["id": .string("job"), "name": .string("Original")])
        let formEdited = AutomationDefinition(fields: ["id": .string("job"), "name": .string("Form edit")])
        var document = AutomationDocumentState()
        document.installClean("original JSON", definition: original)
        document.text = "unapplied Advanced JSON"
        #expect(document.isDirty)
        #expect(document.conflicts(with: formEdited))
        #expect(!document.canApply(capturedText: document.text, capturedDefinition: original, currentDefinition: formEdited))
        #expect(document.text == "unapplied Advanced JSON")
        document.keepTextAgainst(formEdited)
        #expect(document.canApply(capturedText: document.text, capturedDefinition: formEdited, currentDefinition: formEdited))
        document.installClean(document.text, definition: formEdited)
        #expect(!document.isDirty)
    }

    @Test func asynchronousAdvancedApplyCannotOverwriteNewTextNewFormOrExplicitLoadCurrent() {
        let original = AutomationDefinition(fields: ["id": .string("job"), "name": .string("Before")])
        let current = AutomationDefinition(fields: ["id": .string("job"), "name": .string("Current")])
        var document = AutomationDocumentState()
        document.installClean("prepared", definition: original)
        document.text = "captured edit"
        let capturedText = document.text
        document.text = "later typing"
        #expect(!document.canApply(capturedText: capturedText, capturedDefinition: original, currentDefinition: original))
        document.text = capturedText
        #expect(!document.canApply(capturedText: capturedText, capturedDefinition: original, currentDefinition: current))
        document = AutomationDocumentState()
        document.installClean("current JSON", definition: current)
        #expect(!document.canApply(capturedText: capturedText, capturedDefinition: original, currentDefinition: current))
        #expect(document.text == "current JSON")
    }

    @Test func retryConnectivityRejectionDoesNotSettleOriginalUnknownAcknowledgement() throws {
        let unavailable = try #require(GatewayRPCFailure(code: -32003, message: "Mini unavailable", data: .object([
            "kind": .string("automationUnavailable"), "retryable": .bool(true)
        ])))
        #expect(!AutomationMutationFailure.keepPendingAfterFailure(unavailable, alreadyPending: false))
        #expect(AutomationMutationFailure.keepPendingAfterFailure(unavailable, alreadyPending: true))
        #expect(AutomationMutationFailure.keepPendingAfterFailure(GatewayClient.ClientError.notConnected, alreadyPending: true))
        let conflict = try JSONDecoder().decode(AutomationServiceError.self, from: Data(#"{"code":"conflict","message":"Changed","current_revision":9}"#.utf8))
        #expect(!AutomationMutationFailure.keepPendingAfterFailure(conflict, alreadyPending: true))
    }

    @Test func authoritativeStateTimezoneRunTimesAndValidationPathsDecodeWithoutGuessing() async throws {
        let bytes = Data(#"{"ok":true,"data":{"items":[{"id":"job","revision":5,"enabled":true,"expired":true,"completed":false,"managed":false,"next_due":1000,"next_due_timezone":"America/New_York","last_run":{"id":"run","state":"succeeded","revision":4,"created":10,"started":11,"finished":12}}],"limit":50,"offset":0}}"#.utf8)
        let list = try JSONDecoder().decode(AutomationEnvelope<AutomationList>.self, from: bytes).value()
        #expect(list.items[0].stateLabel == "Expired")
        #expect(list.items[0].enabled)
        #expect(list.items[0].lastRun?.started == 11)
        #expect(list.items[0].lastRun?.revision == 4)
        let prepared = await AutomationPresentation.prepare(list.items)
        #expect(prepared[0].nextDueLabel?.contains("America/New_York") == true)
        let errorBytes = Data(#"{"code":"invalid_input","message":"Invalid definition","fields":[{"path":["when","list[Trigger]",1,"cron"],"message":"Use a five-field expression"}]}"#.utf8)
        let error = try JSONDecoder().decode(AutomationServiceError.self, from: errorBytes)
        #expect(error.fields?.first?.path == [.string("when"), .string("list[Trigger]"), .number(1), .string("cron")])
        #expect(error.fields?.first?.message == "Use a five-field expression")
        #expect(error.fields?.first?.presented(whenIsList: true)?.label == "when.1.cron")
        #expect(!error.isConflict)
    }
}

struct AutomationOperationRaceTests {
    private func mutation(_ requestID: String) -> AutomationMutation {
        AutomationMutation(operation: .run, request: AutomationRequest(id: "job", requestId: requestID))
    }
    @Test func reopenedSurfaceCannotOverlapAnAttemptAndStaleCompletionCannotSettleItsRetry() throws {
        let request = mutation("original")
        var state = AutomationOperationState()
        let attemptResult1 = state.begin(request)
        let first = try #require(attemptResult1)
        let operationResult2 = state.begin(request) == nil
        #expect(operationResult2)
        let operationResult3 = state.finish(first, outcome: AutomationOperationOutcome(message: "Acknowledgement unknown", admittedRunID: nil, fields: []), retainingPending: true)
        #expect(operationResult3)
        let attemptResult4 = state.begin(request)
        let retry = try #require(attemptResult4)
        #expect(retry.hadPendingAtStart)
        let operationResult5 = !state.finish(first, outcome: .committed(.object(["runs": .array([.string("old-result")])]), mutation: request), retainingPending: false)
        #expect(operationResult5)
        #expect(state.inFlight == retry)
        #expect(state.pending?.request.requestId == "original")
        let operationResult6 = state.finish(retry, outcome: .committed(.object(["runs": .array([.string("exact-run")])]), mutation: request), retainingPending: false)
        #expect(operationResult6)
        #expect(state.pending == nil)
        #expect(state.outcome?.admittedRunID == "exact-run")
    }
    @Test func olderCompletionCannotClearOrReleaseANewerRequestOrReplaceItsRetainedOutcome() throws {
        var state = AutomationOperationState()
        let firstRequest = mutation("first")
        let attemptResult7 = state.begin(firstRequest)
        let first = try #require(attemptResult7)
        let operationResult8 = state.finish(first, outcome: .committed(.object(["runs": .array([.string("run-first")])]), mutation: firstRequest), retainingPending: false)
        #expect(operationResult8)
        let nextRequest = mutation("next")
        let attemptResult9 = state.begin(nextRequest)
        let next = try #require(attemptResult9)
        let operationResult10 = !state.finish(first, outcome: AutomationOperationOutcome(message: "Late failure", admittedRunID: nil, fields: []), retainingPending: false)
        #expect(operationResult10)
        #expect(state.inFlight == next)
        #expect(state.pending == nextRequest)
        let operationResult11 = state.finish(next, outcome: .committed(.object(["accepted": .bool(true), "runs": .array([]), "reason": .string("Precondition declined")]), mutation: nextRequest), retainingPending: false)
        #expect(operationResult11)
        #expect(state.pending == nil)
        #expect(state.outcome?.message == "Precondition declined")
        let operationResult12 = !state.finish(first, outcome: .committed(.object(["runs": .array([.string("late-old")])]), mutation: firstRequest), retainingPending: false)
        #expect(operationResult12)
        #expect(state.outcome?.message == "Precondition declined")
    }
    @Test func actualTriggerUnionErrorsSelectOnlySubmittedBranchAndCorrectListIndex() throws {
        let bytes = Data(#"{"code":"invalid_input","message":"Definition invalid","fields":[{"path":["when","Trigger"],"message":"Input should be a valid dictionary"},{"path":["when","list[Trigger]",1,"cron"],"message":"Invalid expression"},{"path":["when"],"message":"At least one trigger required"}]}"#.utf8)
        let error = try JSONDecoder().decode(AutomationServiceError.self, from: bytes)
        let presented = error.fields?.compactMap { $0.presented(whenIsList: true) }
        #expect(presented?.map(\.label) == ["when.1.cron", "when"])
        #expect(presented?.first?.path[1] == .number(1))
        #expect(error.fields?.compactMap { $0.presented(whenIsList: false) }.map(\.label) == ["when", "when"])
    }
}
