import SwiftUI

struct AutomationDetailView: View {
    let workspace: ChatWorkspaceModel
    let authority: AutomationManagement
    let automationID: String
    @Environment(AutomationDraftStore.self) private var drafts
    @Environment(\.automationSurfaceVisible) private var settingsVisible
    @State private var presented = false
    @State private var detail: AutomationDetail?
    @State private var error: String?
    @State private var refreshing = false
    @State private var readGeneration = UUID()
    @State private var editor: AutomationEditorSession?
    @State private var editorPresented = false
    @State private var confirmRemove = false
    @State private var runs: [AutomationRunSummary] = []
    @State private var runOffset = 0
    @State private var moreRuns = false
    @State private var preparingAdmission = false
    @State private var eventType = ""
    @State private var eventSource = ""
    @State private var eventData = "{}"
    private var needsEvent: Bool {
        guard let detail else { return false }
        return !detail.definition.triggers.isEmpty && detail.definition.triggers.allSatisfy { $0["event"]?.stringValue != nil || ($0["imessage"] != nil && $0["imessage"] != .null) }
    }

    private var operation: AutomationOperationState { drafts.operation(operationKey) }
    private var pending: AutomationMutation? { operation.pending }
    private var mutating: Bool { operation.isInFlight }
    private var admittedRunID: String? { operation.outcome?.admittedRunID }
    private var validationFields: [AutomationValidationField] { operation.outcome?.fields ?? [] }
    private var operationKey: String { "\(authority.hostID)|automation|\(automationID)" }
    private var surfaceVisible: Bool { settingsVisible && presented && !editorPresented }
    private var lifecycleKey: String { "\(surfaceVisible)|\(workspace.automationAuthorityIsConnected)" }
    private var pollingKey: String { "\(surfaceVisible)|\(workspace.automationAuthorityIsConnected)|\(runs.contains(where: \.isActive))" }

    var body: some View {
        List {
            if let admittedRunID {
                Section("Latest admitted run") {
                    NavigationLink("Open admitted run") { AutomationRunView(workspace: workspace, authority: authority, runID: admittedRunID) }
                }
            }
            if let detail {
                Section {
                    LabeledContent("Revision", value: String(detail.revision))
                    LabeledContent("State", value: detail.isRemoved ? "Removed" : detail.expired == true ? "Expired" : detail.completed == .bool(true) || detail.completed == .number(1) ? "Completed" : detail.definition.enabled ? "Active" : "Paused")
                    LabeledContent("Enabled", value: detail.definition.enabled ? "Yes" : "No")
                    if detail.managed == true { Text("Managed by the service. Change the owning Messages automation to configure this source.").scaledFont(.footnote).foregroundStyle(.secondary) }
                    Text(AutomationPresentation.triggerDescription(detail.definition.fields["when"]))
                    if let agent = detail.definition.agent {
                        LabeledContent("Provider", value: agent["provider"]?.stringValue ?? "Unknown")
                        LabeledContent("Execution host", value: agent["gateway_host"]?.stringValue ?? "Unknown")
                        LabeledContent("Model", value: agent["model"]?.stringValue ?? "Service default")
                    }
                    if detail.managed != true, editor != nil { Button("Continue editing") { editorPresented = true } }
                    else if detail.managed != true { Button("Edit") {
                        editor = drafts.session(authorityID: authority.hostID, draft: AutomationDraft(definition: detail.definition, expectedRevision: detail.revision))
                        editorPresented = editor != nil
                    }.disabled(detail.isRemoved || !authority.isAvailable) }
                    if !detail.isRemoved && detail.managed != true {
                        Button(detail.definition.enabled ? "Pause" : "Resume") {
                            var draft = AutomationDraft(definition: detail.definition, expectedRevision: detail.revision)
                            draft.set(.bool(!detail.definition.enabled), at: ["enabled"])
                            perform(AutomationMutation(operation: .save, request: draft.saveRequest(requestID: UUID().uuidString)))
                        }.disabled(mutating || pending != nil || !authority.isAvailable)
                        if needsEvent {
                            DisclosureGroup("Event for this run") {
                                TextField("Event type", text: $eventType)
                                TextField("Event source", text: $eventSource)
                                TextEditor(text: $eventData).scaledFont(.system(.caption, design: .monospaced)).frame(minHeight: 100).accessibilityLabel("Event data JSON")
                                ForEach(Array(validationFields.enumerated()), id: \.offset) { _, field in
                                    Text("\(field.label): \(field.message)").scaledFont(.footnote).foregroundStyle(.red)
                                }
                                Text("Supply an event matching this automation. Messages events also require their exact source and conversation data.").scaledFont(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Button("Run now") { Task { await admitRun() } }.disabled(mutating || preparingAdmission || pending != nil || !authority.isAvailable || detail.definition.isSource)
                        Text("Run now admits a run. Follow its status below for the outcome.").scaledFont(.footnote).foregroundStyle(.secondary)
                        Button("Remove", role: .destructive) { confirmRemove = true }
                            .disabled(mutating || pending != nil || !authority.isAvailable)
                    }
                    NavigationLink("Definition history") {
                        AutomationHistoryView(workspace: workspace, authority: authority, current: detail)
                    }
                }
                Section("Runs") {
                    ForEach(runs) { run in
                        NavigationLink {
                            AutomationRunView(workspace: workspace, authority: authority, runID: run.id)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(run.state.capitalized)
                                if let revision = run.revision { Text(revision == 0 ? "One-time invocation" : "Revision \(revision)").scaledFont(.caption) }
                                if let created = run.created { Text("Admitted: \(Date(timeIntervalSince1970: created).formatted())").scaledFont(.caption).foregroundStyle(.secondary) }
                                if let started = run.started { Text("Started: \(Date(timeIntervalSince1970: started).formatted())").scaledFont(.caption).foregroundStyle(.secondary) }
                                if let finished = run.finished { Text("Finished: \(Date(timeIntervalSince1970: finished).formatted())").scaledFont(.caption).foregroundStyle(.secondary) }
                                if let error = run.error { Text(error).scaledFont(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    if runs.isEmpty { Text("No recorded runs").foregroundStyle(.secondary) }
                    if moreRuns { Button("Load earlier runs") { Task { await load(append: true) } }.disabled(refreshing) }
                }
                if let imported = detail.importedRuns, !imported.isEmpty {
                    Section("Imported history") {
                        Text("Older receipts may lack a saved definition revision.").scaledFont(.footnote).foregroundStyle(.secondary)
                        ForEach(Array(imported.enumerated()), id: \.offset) { _, receipt in
                            if let id = receipt.objectValue?["run_id"]?.stringValue {
                                NavigationLink(id) { AutomationRunView(workspace: workspace, authority: authority, runID: id) }
                            }
                        }
                    }
                }
            }
            if refreshing { ProgressView() }
            if let error { Section { Text(error).foregroundStyle(.secondary) } }
            if !authority.isAvailable, let unavailable = authority.error { Text(unavailable).foregroundStyle(.secondary) }
            if let message = operation.outcome?.message { Section { Text(message).foregroundStyle(.secondary) } }
            if let pending {
                Section("Awaiting acknowledgement") {
                    Text("Keep this operation unchanged until its saved receipt or retry confirms the outcome.")
                    Button("Check receipt") { Task { await reconcile(pending) } }.disabled(mutating)
                    Button("Retry same operation") { perform(pending) }.disabled(mutating || !authority.isAvailable)
                }
            }
        }
        .navigationTitle(detail?.definition.name ?? automationID)
        .toolbar { ToolbarItem { Button("Refresh", systemImage: "arrow.clockwise") { Task { await load(force: true) } } } }
        .onAppear { presented = true }
        .onDisappear { presented = false }
        .task(id: lifecycleKey) { if surfaceVisible { await load(force: true) } }
        .refreshable { await load(force: true) }
        .task(id: pollingKey) {
            guard surfaceVisible, workspace.automationAuthorityIsConnected else { return }
            while !Task.isCancelled {
                guard runs.contains(where: \.isActive) else { return }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await load()
            }
        }
        .confirmationDialog("Remove this automation?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                guard let detail else { return }
                perform(AutomationMutation(operation: .remove, request: AutomationRequest(id: automationID, requestId: UUID().uuidString, expectedRevision: detail.revision)))
            }
        } message: { Text("Queued runs are cancelled. Running and uncertain runs remain visible and can be managed separately. Definition history is kept.") }
        .onChange(of: editorPresented) { _, presented in
            if !presented, let editor, !drafts.sessions.values.contains(where: { $0.id == editor.id }) { self.editor = nil }
        }
        .sheet(isPresented: $editorPresented) {
            if let editor {
                NavigationStack { AutomationEditorView(workspace: workspace, authority: authority, session: editor) {
                    drafts.discard(editor); self.editor = nil; editorPresented = false; Task { await load(force: true) }
                } }
            }
        }
    }
    private func load(append: Bool = false, force: Bool = false) async {
        guard !refreshing || force else { return }
        let token = UUID(); readGeneration = token
        refreshing = true
        defer { if readGeneration == token { refreshing = false } }
        do {
            if force {
                _ = await authority.refreshCapabilities()
                try Task.checkCancellation()
                guard readGeneration == token else { return }
            }
            let offset = append ? runOffset : 0
            let result = try await authority.detail(automationID, offset: offset)
            try Task.checkCancellation()
            guard readGeneration == token else { return }
            detail = result
            if eventType.isEmpty { eventType = result.definition.triggers.first?["event"]?.stringValue ?? "" }
            if eventSource.isEmpty { eventSource = result.definition.triggers.first?["source"]?.stringValue ?? "" }
            let page = result.runs ?? []
            if append {
                var seen = Set<String>()
                runs = Array((runs + page).filter { seen.insert($0.id).inserted }.suffix(500))
            } else { runs = page }
            let importedCount = result.importedRuns?.count ?? 0
            runOffset = offset + max(page.count, importedCount)
            moreRuns = page.count == 50 || importedCount == 50; error = nil
        } catch is CancellationError { } catch { if readGeneration == token { self.error = error.localizedDescription } }
    }
    private func admitRun() async {
        guard !preparingAdmission, !mutating, pending == nil, detail?.managed != true else { return }
        preparingAdmission = true; defer { preparingAdmission = false }
        let requestID = UUID().uuidString
        var request = AutomationRequest(id: automationID, requestId: requestID)
        if needsEvent {
            guard !eventType.isEmpty, !eventSource.isEmpty else { error = "Enter the event type and source before running."; return }
            do {
                let data = try await AutomationDocuments.parseObject(eventData)
                request.data = ["specversion": .string("1.0"), "id": .string(requestID), "type": .string(eventType), "source": .string(eventSource), "data": .object(data)]
            } catch { self.error = error.localizedDescription; return }
        }
        perform(AutomationMutation(operation: .run, request: request))
    }
    private func perform(_ mutation: AutomationMutation) {
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
                let fields = (error as? AutomationServiceError)?.fields ?? []
                guard drafts.finish(attempt, key: operationKey, outcome: AutomationOperationOutcome(message: error.localizedDescription, admittedRunID: nil, fields: fields), retainingPending: keep) else { return }
                if (error as? AutomationServiceError)?.isConflict == true, surfaceVisible { await load(force: true) }
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
