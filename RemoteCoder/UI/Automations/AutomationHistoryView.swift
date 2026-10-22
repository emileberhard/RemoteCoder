import SwiftUI

struct AutomationHistoryView: View {
    let workspace: ChatWorkspaceModel
    let authority: AutomationManagement
    let current: AutomationDetail
    @Environment(\.automationSurfaceVisible) private var settingsVisible
    @State private var presented = false
    @State private var readGeneration = UUID()
    @State private var items: [AutomationRevision] = []
    @State private var nextOffset = 0
    @State private var baseline: Int?
    @State private var more = false
    @State private var loading = false
    @State private var error: String?
    private var surfaceVisible: Bool { settingsVisible && presented }
    private var lifecycleKey: String { "\(surfaceVisible)|\(workspace.automationAuthorityIsConnected)" }

    var body: some View {
        List {
            if let baseline { Section { Text("Saved definition history begins at revision \(baseline). Older runs can still carry their own snapshots.").scaledFont(.footnote).foregroundStyle(.secondary) } }
            ForEach(items) { revision in
                NavigationLink {
                    AutomationRevisionView(workspace: workspace, authority: authority, current: current, metadata: revision)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Revision \(revision.revision) · \(revision.changeKind.capitalized)")
                        if let time = revision.recordedAt.stringValue { Text(time).scaledFont(.caption).foregroundStyle(.secondary) }
                        if case .number(let time) = revision.recordedAt { Text(Date(timeIntervalSince1970: time).formatted()).scaledFont(.caption).foregroundStyle(.secondary) }
                        if let reason = revision.reason { Text(reason).scaledFont(.caption) }
                        if revision.removed { Text("Removed").scaledFont(.caption) }
                    }
                }
            }
            if loading { ProgressView() }
            if more { Button("Load earlier revisions") { Task { await load(append: true) } }.disabled(loading) }
            if let error { Text(error).foregroundStyle(.secondary) }
        }
        .navigationTitle("Definition history")
        .onAppear { presented = true }
        .onDisappear { presented = false }
        .task(id: lifecycleKey) { if surfaceVisible { await load(force: true) } }
        .refreshable { await load(force: true) }
    }
    private func load(append: Bool = false, force: Bool = false) async {
        guard !loading || force else { return }
        let token = UUID(); readGeneration = token
        loading = true; defer { if readGeneration == token { loading = false } }
        do {
            if force {
                _ = await authority.refreshCapabilities()
                try Task.checkCancellation()
                guard readGeneration == token else { return }
            }
            let history = try await authority.history(current.id, offset: append ? nextOffset : 0)
            try Task.checkCancellation()
            guard readGeneration == token else { return }
            if append {
                var seen = Set<Int>()
                items = Array((items + history.items).filter { seen.insert($0.revision).inserted }.suffix(500))
            } else { items = history.items }
            nextOffset = history.offset + history.items.count
            baseline = history.baselineRevision; more = history.items.count == history.limit; error = nil
        } catch is CancellationError { } catch { if readGeneration == token { self.error = error.localizedDescription } }
    }
}

struct AutomationRevisionView: View {
    let workspace: ChatWorkspaceModel
    let authority: AutomationManagement
    let current: AutomationDetail
    let metadata: AutomationRevision
    @Environment(AutomationDraftStore.self) private var drafts
    @Environment(\.automationSurfaceVisible) private var settingsVisible
    @State private var presented = false
    @State private var snapshot: AutomationDetail?
    @State private var comparison: AutomationComparison?
    @State private var definitionText = ""
    @State private var actorText = "Unknown"
    @State private var attributionText = ""
    @State private var error: String?
    @State private var editor: AutomationEditorSession?
    @State private var restorePresented = false
    private var surfaceVisible: Bool { settingsVisible && presented && !restorePresented }
    private var lifecycleKey: String { "\(surfaceVisible)|\(workspace.automationAuthorityIsConnected)" }

    var body: some View {
        List {
            Section("Saved revision") {
                LabeledContent("Change", value: metadata.changeKind.capitalized)
                LabeledContent("Source", value: actorText)
                DisclosureGroup("Attribution") { Text(attributionText).scaledFont(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                LabeledContent("Schema", value: String(metadata.schemaVersion))
                if let reason = metadata.reason { Text(reason) }
                if let restored = metadata.restoredFromRevision { Text("Restored from revision \(restored)") }
            }
            if let comparison {
                Section("Changes from this revision to current") { AutomationComparisonView(comparison: comparison) }
            }
            if snapshot != nil {
                Section {
                    DisclosureGroup("Complete saved definition") {
                        Text(definitionText).scaledFont(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                    Button(editor == nil ? "Preview restore" : "Continue restore preview") {
                        Task { await prepareRestore() }
                    }.disabled(!authority.isAvailable || current.managed == true)
                    Text("Restoring creates a new revision. The preview starts paused. It restores configuration and prompt text; job code, files and conversation context keep their current state.")
                        .scaledFont(.footnote).foregroundStyle(.secondary)
                }
            } else if error == nil { ProgressView() }
            if let error { Text(error).foregroundStyle(.secondary) }
            if !authority.isAvailable, let error = authority.error { Text(error).foregroundStyle(.secondary) }
        }
        .navigationTitle("Revision \(metadata.revision)")
        .onAppear { presented = true }
        .onDisappear { presented = false }
        .task(id: lifecycleKey) {
            guard surfaceVisible else { return }
            _ = await authority.refreshCapabilities()
            do {
                try Task.checkCancellation()
                let snapshot = try await authority.detail(current.id, revision: metadata.revision)
                async let comparison = AutomationDocuments.compare(snapshot.definition, current.definition)
                async let definitionText = AutomationDocuments.pretty(.object(snapshot.definition.fields))
                async let attributionText = AutomationDocuments.pretty(metadata.actor ?? .null)
                let prepared = try await (comparison, definitionText, attributionText)
                try Task.checkCancellation()
                self.snapshot = snapshot; self.comparison = prepared.0; self.definitionText = prepared.1; self.attributionText = prepared.2
                self.actorText = metadata.actor?.objectValue?["surface"]?.stringValue ?? metadata.actor?.stringValue ?? "Unknown"
                self.error = nil
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
        .onChange(of: restorePresented) { _, presented in
            if !presented, let editor, !drafts.sessions.values.contains(where: { $0.id == editor.id }) { self.editor = nil }
        }
        .sheet(isPresented: $restorePresented) {
            if let editor {
                NavigationStack { AutomationEditorView(workspace: workspace, authority: authority, session: editor) {
                    drafts.discard(editor); self.editor = nil; restorePresented = false
                } }
            }
        }
    }
    private func prepareRestore() async {
        if editor != nil { restorePresented = true; return }
        guard let snapshot else { return }
        do {
            let latest = try await authority.detail(current.id)
            guard latest.managed != true else { error = "This source is managed by the service and cannot be restored here."; return }
            var draft = AutomationDraft(definition: snapshot.definition, expectedRevision: latest.revision, sourceRevision: metadata.revision)
            draft.set(.bool(false), at: ["enabled"])
            editor = drafts.session(authorityID: authority.hostID, draft: draft); restorePresented = editor != nil
        } catch { self.error = error.localizedDescription }
    }
}

struct AutomationComparisonView: View {
    let comparison: AutomationComparison
    var body: some View {
        ForEach(comparison.fields) { change in
            VStack(alignment: .leading, spacing: 3) {
                Text(change.path).scaledFont(.subheadline.weight(.semibold))
                Text("Before: \(change.before)").scaledFont(.caption).foregroundStyle(.secondary)
                Text("After: \(change.after)").scaledFont(.caption)
            }.textSelection(.enabled)
        }
        if comparison.oldPrompt != comparison.newPrompt {
            DisclosureGroup("Prompt changes (by line)") {
                ForEach(comparison.promptChanges) { change in
                    VStack(alignment: .leading) {
                        Text(change.path).scaledFont(.caption.weight(.semibold))
                        Text("− \(change.before)").foregroundStyle(.secondary)
                        Text("+ \(change.after)")
                    }.scaledFont(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                Text("Line comparison shows the first 2,000 lines. Complete prompt text is in the saved definition.").scaledFont(.footnote).foregroundStyle(.secondary)
            }
        }
        if comparison.fields.isEmpty && comparison.oldPrompt == comparison.newPrompt { Text("No definition changes").foregroundStyle(.secondary) }
    }
}
