import SwiftUI

private struct AutomationConversationOpenerKey: EnvironmentKey {
    static let defaultValue: (@MainActor (AutomationExecutionRoute) async throws -> Bool)? = nil
}

private struct AutomationSurfaceVisibilityKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var automationSurfaceVisible: Bool {
        get { self[AutomationSurfaceVisibilityKey.self] }
        set { self[AutomationSurfaceVisibilityKey.self] = newValue }
    }
    var automationConversationOpener: (@MainActor (AutomationExecutionRoute) async throws -> Bool)? {
        get { self[AutomationConversationOpenerKey.self] }
        set { self[AutomationConversationOpenerKey.self] = newValue }
    }
}

struct AutomationsAuthorityView: View {
    let workspace: ChatWorkspaceModel
    var body: some View {
        NavigationStack {
            if let authority = workspace.automationAuthority {
                AutomationsView(workspace: workspace, authority: authority)
            } else {
                ContentUnavailableView("Automations unavailable", systemImage: "clock.arrow.circlepath",
                    description: Text("No connected gateway reports an automation service."))
                    .navigationTitle("Automations")
            }
        }
    }
}

struct AutomationsView: View {
    let workspace: ChatWorkspaceModel
    @Bindable var authority: AutomationManagement
    @Environment(AutomationDraftStore.self) private var drafts
    @Environment(\.automationSurfaceVisible) private var settingsVisible
    @State private var presented = false
    @State private var query = ""
    @State private var filter: AutomationInventoryFilter = .active
    @State private var editor: AutomationEditorSession?
    @State private var editorPresented = false

    private var surfaceVisible: Bool { settingsVisible && presented && !editorPresented }
    private var lifecycleKey: String { "\(surfaceVisible)|\(workspace.automationAuthorityIsConnected)|\(filter.rawValue)|\(query)" }
    private var inventory: AutomationInventory? { authority.cachedInventory(for: filter, search: query) }

    var body: some View {
        List {
            Section {
                LabeledContent("Managed on", value: authority.hostName)
                Picker("Show", selection: $filter) {
                    ForEach(AutomationInventoryFilter.allCases) { Text($0.label).tag($0) }
                }
                if let error = authority.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    if let date = inventory?.refreshedAt {
                        Text("Showing saved results from \(date.formatted()).").scaledFont(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let health = authority.health { Label(health, systemImage: "exclamationmark.triangle") }
                ForEach(drafts.drafts(authorityID: authority.hostID)) { saved in
                    Button("Continue editing \(saved.draft.definition.name.isEmpty ? "new automation" : saved.draft.definition.name)") {
                        editor = saved; editorPresented = true
                    }
                }
                if drafts.isFull { Text("Twenty drafts are kept. Save or discard a draft before starting another.").scaledFont(.footnote).foregroundStyle(.secondary) }
            }
            Section("Automations") {
                ForEach((inventory?.items ?? []).filter { !$0.isSource }) { item in inventoryLink(item) }
            }
            if (inventory?.items ?? []).contains(where: \.isSource) {
                Section("Sources") {
                    ForEach((inventory?.items ?? []).filter(\.isSource)) { item in inventoryLink(item) }
                }
            }
            Section {
                if (inventory?.items ?? []).isEmpty && authority.isAvailable && !(inventory?.isRefreshing ?? true) {
                    ContentUnavailableView("No \(filter == .all ? "" : filter.label.lowercased() + " ")automations",
                                           systemImage: "clock.arrow.circlepath")
                }
                if (inventory?.isRefreshing ?? true) { ProgressView("Updating automations…") }
                if (inventory?.hasMore ?? false) {
                    Button("Load more") { Task { await authority.refresh(filter: filter, search: query, append: true) } }.disabled((inventory?.isRefreshing ?? true))
                }
            }
        }
        .navigationTitle("Automations")
        .searchable(text: Binding(get: { query }, set: { query = String($0.prefix(200)) }), prompt: "Search ID, name or trigger")
        .toolbar {
            ToolbarItem { Button("Refresh", systemImage: "arrow.clockwise") { Task { await authority.refresh(filter: filter, search: query) } } }
            ToolbarItem { Button("New automation", systemImage: "plus") {
                var draft = AutomationDraft.new()
                if let directories = workspace.model(for: authority.hostID)?.directories,
                   case .resolved(let home) = directories.home {
                    draft.set(.string(home), at: ["cwd"])
                }
                editor = drafts.session(authorityID: authority.hostID, draft: draft); editorPresented = editor != nil
            }.disabled(drafts.isFull || !authority.isAvailable) }
        }
        .refreshable { await authority.refresh(filter: filter, search: query) }

        .onAppear { presented = true }
        .onDisappear { presented = false }
        .task(id: lifecycleKey) {
            guard surfaceVisible else { return }
            if !query.isEmpty { do { try await Task.sleep(for: .milliseconds(300)) } catch { return } }
            await authority.refresh(filter: filter, search: query, force: true)
            await workspace.accountDirectory.refreshCodex(interactive: false)
        }
        .sheet(isPresented: $editorPresented) {
            if let editor {
                NavigationStack {
                    AutomationEditorView(workspace: workspace, authority: authority, session: editor) {
                        drafts.discard(editor); self.editor = nil; editorPresented = false
                    }
                }
            }
        }
    }

    private func inventoryLink(_ item: AutomationSummary) -> some View {
        NavigationLink {
            AutomationDetailView(workspace: workspace, authority: authority, automationID: item.id)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(item.label).scaledFont(.headline)
                    Spacer()
                    Text(item.stateLabel).scaledFont(.caption).foregroundStyle(.secondary)
                }
                if item.isSource {
                    Text((item.kind?.capitalized ?? "Event") + " source" + (item.managed == true ? " · Managed by service" : ""))
                        .scaledFont(.subheadline).foregroundStyle(.secondary)
                } else { Text(item.triggerDescription).scaledFont(.subheadline).foregroundStyle(.secondary) }
                if let next = item.nextDueLabel { Text("Next: \(next)").scaledFont(.caption) }
                else if item.completed == true { Text("Schedule completed").scaledFont(.caption) }
                if let run = item.lastRun {
                    Text("Last run: \(run.state)\(run.error.map { " · \($0)" } ?? "")").scaledFont(.caption).foregroundStyle(.secondary)
                    if let revision = run.revision { Text(revision == 0 ? "One-time invocation" : "Revision \(revision)").scaledFont(.caption).foregroundStyle(.secondary) }
                    if let time = run.created { Text("Admitted: \(Date(timeIntervalSince1970: time).formatted())").scaledFont(.caption).foregroundStyle(.secondary) }
                    if let time = run.started { Text("Started: \(Date(timeIntervalSince1970: time).formatted())").scaledFont(.caption).foregroundStyle(.secondary) }
                    if let time = run.finished { Text("Finished: \(Date(timeIntervalSince1970: time).formatted())").scaledFont(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
}
