import SwiftUI

struct AutomationRunView: View {
    let workspace: ChatWorkspaceModel
    let authority: AutomationManagement
    let runID: String
    @Environment(AutomationDraftStore.self) private var drafts
    @Environment(\.automationSurfaceVisible) private var settingsVisible
    @State private var presented = false
    @Environment(\.automationConversationOpener) private var openConversation
    @State private var run: AutomationRunDetail?
    @State private var error: String?
    @State private var loading = false
    @State private var readGeneration = UUID()
    @State private var openingConversation = false
    @State private var confirmCancel = false
    @State private var outputOffset: Int?
    @State private var receiptText = ""
    @State private var definitionText = ""
    @State private var refreshedAt: Date?

    private var operation: AutomationOperationState { drafts.operation(operationKey) }
    private var pending: AutomationMutation? { operation.pending }
    private var cancelling: Bool { operation.isInFlight }
    private var operationKey: String { "\(authority.hostID)|run|\(runID)" }
    private var surfaceVisible: Bool { settingsVisible && presented }
    private var lifecycleKey: String { "\(surfaceVisible)|\(workspace.automationAuthorityIsConnected)" }
    private var pollKey: String { "\(surfaceVisible)|\(workspace.automationAuthorityIsConnected)|\(run?.isActive == true)" }

    var body: some View {
        List {
            if let run {
                Section("Run") {
                    LabeledContent("State", value: run.state.capitalized)
                    if let time = run.created { LabeledContent("Admitted", value: Date(timeIntervalSince1970: time).formatted()) }
                    if let time = run.started { LabeledContent("Started", value: Date(timeIntervalSince1970: time).formatted()) }
                    if let time = run.finished { LabeledContent("Finished", value: Date(timeIntervalSince1970: time).formatted()) }
                    if run.definitionHistory == "saved_revision", let revision = run.revision {
                        LabeledContent("Definition", value: "Saved revision \(revision)")
                    } else if run.definitionHistory == "one_time" {
                        Text("One-time invocation").foregroundStyle(.secondary)
                    } else {
                        Text("Legacy run: its snapshot or receipt predates saved definition history.").foregroundStyle(.secondary)
                    }
                    if run.state == "uncertain" {
                        Text("Execution acknowledgement is uncertain. Inspect the recorded conversation and receipt before deciding what to do next.")
                    }
                    if let error = run.error { Text(error).foregroundStyle(.secondary) }
                    if let route = AutomationExecutionRoute(receipt: run.receipt), workspace.automationConversation(run) != nil, let openConversation {
                        Button("Open conversation") {
                            guard !openingConversation else { return }
                            openingConversation = true
                            Task {
                                defer { openingConversation = false }
                                do {
                                    if try await openConversation(route) == false { error = "Finish dictation before opening this conversation." }
                                } catch { self.error = error.localizedDescription }
                            }
                        }.disabled(openingConversation)
                    } else if run.receipt?.objectValue?["thread_id"] != nil {
                        Text("The exact execution host or account is unavailable. Add that host or account to open this conversation.")
                            .scaledFont(.footnote).foregroundStyle(.secondary)
                    }
                    if run.isActive && run.imported != true {
                        Button("Cancel run", role: .destructive) { confirmCancel = true }
                            .disabled(cancelling || pending != nil || !authority.isAvailable)
                    }
                }
                Section("Output") {
                    Text(run.output.flatMap { $0.isEmpty ? nil : $0 } ?? "No output recorded")
                        .scaledFont(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    let coverage = run.outputCoverage?.objectValue ?? [:]
                    if case .number(let offset) = coverage["offset"], case .number(let bytes) = coverage["returned_bytes"], case .number(let size) = coverage["size_bytes"] {
                        Text("Bytes \(Int(offset))–\(Int(offset + bytes)) of \(Int(size))").scaledFont(.footnote).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Beginning") { outputOffset = 0; Task { await load(force: true) } }
                        Button("Latest") { outputOffset = nil; Task { await load(force: true) } }
                        if case .number(let next) = coverage["next_offset"] {
                            Button("Next page") { outputOffset = Int(next); Task { await load(force: true) } }
                        }
                    }.disabled(loading)
                }
                Section {
                    DisclosureGroup("Execution receipt") { Text(receiptText).scaledFont(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    if run.definition != nil {
                        DisclosureGroup("Admitted definition") { Text(definitionText).scaledFont(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                        Text("This is the definition admitted for this run. Current settings can differ. Job code, files and conversation context are not snapshotted here.")
                            .scaledFont(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if loading { ProgressView() }
            if let error {
                Text(error).foregroundStyle(.secondary)
                if let refreshedAt { Text("Showing the last successful update from \(refreshedAt.formatted()).").scaledFont(.footnote).foregroundStyle(.secondary) }
            }
            if !authority.isAvailable, let unavailable = authority.error { Text(unavailable).foregroundStyle(.secondary) }
            if let message = operation.outcome?.message { Text(message).foregroundStyle(.secondary) }
            if let pending {
                Section("Cancellation awaiting acknowledgement") {
                    Button("Retry same cancellation") { cancel(pending) }.disabled(cancelling || !authority.isAvailable)
                    Button("Check receipt") { Task { await reconcile(pending) } }.disabled(cancelling)
                }
            }
        }
        .navigationTitle("Run details")
        .toolbar { ToolbarItem { Button("Refresh", systemImage: "arrow.clockwise") { Task { await load(force: true) } } } }
        .onAppear { presented = true }
        .onDisappear { presented = false }
        .task(id: lifecycleKey) { if surfaceVisible { await load(force: true) } }
        .refreshable { await load(force: true) }
        .task(id: pollKey) {
            guard surfaceVisible, workspace.automationAuthorityIsConnected, run?.isActive == true else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                await load()
                if run?.isActive != true { return }
            }
        }
        .confirmationDialog("Cancel this run?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel run", role: .destructive) {
                cancel(AutomationMutation(operation: .run, request: AutomationRequest(requestId: UUID().uuidString, runId: runID, cancel: true)))
            }
        }
    }
    private func load(force: Bool = false) async {
        guard !loading || force else { return }
        let token = UUID(); readGeneration = token
        loading = true; defer { if readGeneration == token { loading = false } }
        do {
            if force {
                _ = await authority.refreshCapabilities()
                try Task.checkCancellation()
                guard readGeneration == token else { return }
            }
            let value = try await authority.runDetail(runID, outputOffset: outputOffset)
            async let receiptText = AutomationDocuments.pretty(value.receipt ?? .null)
            async let definitionText = AutomationDocuments.pretty(.object(value.definition?.fields ?? [:]))
            let prepared = try await (receiptText, definitionText)
            try Task.checkCancellation()
            guard readGeneration == token else { return }
            run = value; self.receiptText = prepared.0; self.definitionText = prepared.1; error = nil; refreshedAt = .now
        } catch is CancellationError { } catch { if readGeneration == token { self.error = error.localizedDescription } }
    }
    private func cancel(_ mutation: AutomationMutation) {
        guard let attempt = drafts.begin(mutation, key: operationKey) else { return }
        Task {
            do {
                let result = try await authority.mutate(mutation)
                guard drafts.finish(attempt, key: operationKey, outcome: .committed(result, mutation: mutation), retainingPending: false) else { return }
                if surfaceVisible { await load(force: true) }
            } catch {
                let keep: Bool
                if error is AutomationManagementError { keep = attempt.hadPendingAtStart }
                else { keep = AutomationMutationFailure.keepPendingAfterFailure(error, alreadyPending: attempt.hadPendingAtStart) }
                _ = drafts.finish(attempt, key: operationKey, outcome: AutomationOperationOutcome(message: error.localizedDescription, admittedRunID: nil, fields: (error as? AutomationServiceError)?.fields ?? []), retainingPending: keep)
            }
        }
    }
    private func reconcile(_ mutation: AutomationMutation) async {
        guard let id = mutation.request.requestId, let attempt = drafts.begin(mutation, key: operationKey) else { return }
        do {
            let result = try await authority.gateway.showAutomationReceipt(id)
            guard drafts.finish(attempt, key: operationKey, outcome: .committed(result, mutation: mutation), retainingPending: false) else { return }
            await authority.refreshCachedInventories()
            if surfaceVisible { await load(force: true) }
        } catch {
            _ = drafts.finish(attempt, key: operationKey, outcome: AutomationOperationOutcome(message: error.localizedDescription, admittedRunID: nil, fields: []), retainingPending: true)
        }
    }
}
