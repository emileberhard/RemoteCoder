import SwiftUI

struct AutomationEditorView: View {
    let workspace: ChatWorkspaceModel
    let authority: AutomationManagement
    @Bindable var session: AutomationEditorSession
    let onSaved: () -> Void
    @Environment(AutomationDraftStore.self) private var drafts
    @Environment(\.automationSurfaceVisible) private var settingsVisible
    @Environment(\.dismiss) private var dismiss
    @State private var presented = false
    @State private var advanced = false

    private let agentPath = ["run", "agent"]
    private var locked: Bool { session.isSaving || session.pending != nil || session.isApplyingAdvanced }
    private var catalogKey: String {
        let agent = session.draft.definition.agent ?? [:]
        return [agent["gateway_host"]?.stringValue, agent["provider"]?.stringValue].compactMap { $0 }.joined(separator: "|")
    }
    private var isAgent: Bool { session.draft.definition.agent != nil }
    private var surfaceVisible: Bool { settingsVisible && presented }
    private var lifecycleKey: String { "\(surfaceVisible)|\(workspace.automationAuthorityIsConnected)" }

    var body: some View {
        Form {
            Section("Automation") {
                TextField("ID", text: text(["id"]))
                    .disabled(session.draft.expectedRevision != 0)
                    .autocorrectionDisabled()
                TextField("Name (optional)", text: text(["name"], optional: true))
                Toggle("Enabled", isOn: flag(["enabled"]))
                TextField("Working directory", text: text(["cwd"]))
                integer("Timeout (seconds)", path: ["timeout"])
                validationErrors(groups: ["id", "name", "enabled", "cwd", "timeout"])
            }.disabled(locked)
            if session.draft.definition.isSource {
                Section {
                    Text("This definition configures an event source. Its configuration is available in Advanced. Automatically managed Messages sources can only be changed by the service.")
                }
            } else {
                triggerSections
                actionSections
                conditionSection
                Section("Limits") {
                    TextField("Maximum event age (for example 1h)", text: text(["max_age"], optional: true))
                    TextField("Expires at (ISO date with offset)", text: text(["expires_at"], optional: true))
                    validationErrors(groups: ["max_age", "expires_at"])
                    Text("A schedule resumes with the next due wake-up; missed intervals are not replayed without limit.")
                        .scaledFont(.footnote).foregroundStyle(.secondary)
                }.disabled(locked)
            }
            Section {
                DisclosureGroup("Advanced", isExpanded: $advanced) {
                    Text("Complete saved configuration, including conditions, tags, command exit codes, session checkpoints, and settings not exposed above. Apply changes before saving.")
                        .scaledFont(.footnote).foregroundStyle(.secondary)
                    TextEditor(text: $session.document.text).scaledFont(.system(.body, design: .monospaced)).frame(minHeight: 260)
                        .accessibilityLabel("Advanced configuration")
                    Button("Apply configuration") { Task { await session.applyAdvanced() } }
                    if session.document.conflicts(with: session.draft.definition) {
                        Text("The form and Advanced text both changed. Applying the text will replace the form configuration.").scaledFont(.footnote).foregroundStyle(.secondary)
                        Button("Keep Advanced text against current form") { session.keepAdvancedAgainstForm() }
                        Button("Replace Advanced text with current form") { Task { await session.prepareAdvanced(discardText: true) } }
                    }
                    validationErrors(groups: ["config", "kind", "every", "event_source", "event_types", "token_env", "token_file", "command"])
                    if session.document.isDirty {
                        Text("Apply or discard the Advanced text changes before saving.").scaledFont(.footnote).foregroundStyle(.secondary)
                        Button("Discard Advanced text changes") { Task { await session.prepareAdvanced(discardText: true) } }
                    }
                    if let error = session.advancedError { Text(error).foregroundStyle(.red) }
                }
                if session.document.isDirty && !advanced {
                    Button("Review unapplied Advanced changes") { advanced = true }
                }
                TextField("Reason (optional)", text: Binding(get: { session.reason }, set: { session.reason = String($0.prefix(2000)) }), axis: .vertical)
                Button("Discard draft", role: .destructive) { drafts.discard(session); dismiss() }
            }.disabled(locked)
            if let conflict = session.conflict {
                Section("Changed elsewhere") {
                    Text("Revision \(conflict.revision) is current. Your draft is kept. Review differences before choosing how to continue.")
                    if let comparison = session.comparison { AutomationComparisonView(comparison: comparison) }
                    Button("Load current revision") { session.useCurrent() }
                    Button("Keep draft against revision \(conflict.revision)") { session.rebaseDraft() }
                    Text("Keeping the draft allows an explicit save that replaces the current definition with your draft.")
                        .scaledFont(.footnote).foregroundStyle(.secondary)
                }
            }
            if let error = session.error { Section { Text(error).foregroundStyle(.secondary) } }
            if !authority.isAvailable {
                Section {
                    Text(authority.error ?? "Checking the automation service…").foregroundStyle(.secondary)
                    Button("Refresh connection") { Task { _ = await authority.refreshCapabilities() } }
                }
            }
            if session.pending != nil {
                Section("Save awaiting acknowledgement") {
                    Button("Check saved receipt") {
                        Task { if await session.reconcile(using: authority) { onSaved() } }
                    }.disabled(session.isSaving)
                    Text("Your original save and request ID are retained. Refresh the connection, then check the receipt or retry the same save.")
                        .scaledFont(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(session.draft.sourceRevision != nil ? "Restore preview" : session.draft.expectedRevision == 0 ? "New automation" : "Edit automation")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(session.pending != nil ? "Retry save" : session.draft.sourceRevision != nil ? "Restore as new revision" : "Save") {
                    Task { if await session.save(using: authority) { onSaved() } }
                }.disabled(session.isSaving || session.isApplyingAdvanced || session.isPreparingAdvanced || session.document.isDirty || session.conflict != nil || !authority.isAvailable || session.draft.definition.id.isEmpty)
            }
        }
        .onAppear { presented = true }
        .onDisappear { presented = false }
        .task(id: lifecycleKey) {
            guard surfaceVisible, workspace.automationAuthorityIsConnected else { return }
            _ = await authority.refreshCapabilities()
        }
        .task(id: catalogKey) {
            let agent = session.draft.definition.agent ?? [:]
            await workspace.refreshAutomationModels(host: agent["gateway_host"]?.stringValue ?? "")
        }
        .onChange(of: session.isPreparingAdvanced) { _, preparing in
            if !preparing, advanced, session.advancedError == nil { Task { await session.prepareAdvanced() } }
        }
        .onChange(of: session.draft.definition) { _, _ in
            if advanced { Task { await session.prepareAdvanced() } }
        }
        .onChange(of: advanced) { _, opened in
            if opened { Task { await session.prepareAdvanced() } }
        }
    }

    @ViewBuilder private var triggerSections: some View {
        ForEach(session.draft.definition.triggers.indices, id: \.self) { index in
            Section("Trigger \(index + 1)") {
                Picker("Type", selection: triggerKind(index)) {
                    Text("Once").tag("at"); Text("Interval").tag("every"); Text("Cron").tag("cron")
                    Text("Event").tag("event"); Text("Messages").tag("imessage")
                }
                let kind = triggerKind(index).wrappedValue
                if kind == "imessage" { messageReference(index) }
                else { TextField(triggerLabel(kind), text: triggerText(index, key: kind)).autocorrectionDisabled() }
                TextField("Timezone", text: triggerText(index, key: "timezone"))
                if kind == "event" { TextField("Source (optional)", text: triggerText(index, key: "source", optional: true)) }
                if kind == "event" || kind == "imessage" {
                    AutomationTriggerMatchView(values: Binding(get: {
                        session.draft.definition.triggers[index]["match"]?.objectValue ?? [:]
                    }, set: { match in
                        var trigger = session.draft.definition.triggers[index]
                        trigger["match"] = .object(match); session.draft.setTrigger(trigger, index: index)
                    }))
                }
                if session.draft.definition.triggers.count > 1 {
                    Button("Remove trigger", role: .destructive) { session.draft.removeTrigger(at: index) }
                }
                validationErrors(groups: ["when"], index: index)
                if kind == "at" {
                    Text("Use an ISO date with an explicit offset when a clock change makes local time ambiguous.").scaledFont(.footnote).foregroundStyle(.secondary)
                }
            }.disabled(locked)
        }
        Section { Button("Add trigger") { session.draft.addTrigger() }.disabled(locked || session.draft.definition.triggers.count >= 20) }
    }

    @ViewBuilder private var actionSections: some View {
        Section("Action") {
            Picker("Run", selection: Binding(get: { isAgent ? "agent" : "command" }, set: { session.draft.chooseAction($0) })) {
                Text("Agent").tag("agent"); Text("Command").tag("command")
            }
            if isAgent {
                Picker("Provider", selection: Binding(get: { session.draft.text(at: agentPath + ["provider"]) }, set: { session.draft.chooseProvider($0) })) {
                    Text("Codex").tag("codex"); Text("Claude").tag("claude")
                }
                executionHostPicker
                modelPicker
                effortPicker
                TextEditor(text: text(agentPath + ["prompt"])).frame(minHeight: 180).accessibilityLabel("Prompt")
                Picker("Session", selection: text(agentPath + ["session"])) {
                    Text("Fresh").tag("fresh"); Text("Persistent").tag("persistent")
                }
                TextField("Existing thread ID (optional)", text: text(agentPath + ["session_id"], optional: true))
                Picker("Access", selection: text(agentPath + ["access"])) {
                    Text("Full access").tag("full-access"); Text("Read only").tag("read-only")
                }
                Picker("When busy", selection: text(agentPath + ["if_active"])) {
                    Text("Queue").tag("queue"); Text("Skip").tag("skip"); Text("Steer").tag("steer")
                }
            } else {
                let arguments = session.draft.value(at: ["run", "command"])?.arrayValue ?? []
                ForEach(arguments.indices, id: \.self) { index in
                    TextField(index == 0 ? "Executable" : "Argument \(index)", text: commandArgument(index))
                        .autocorrectionDisabled()
                }
                Button("Add argument") {
                    var values = arguments; values.append(.string("")); session.draft.set(.array(values), at: ["run", "command"])
                }
                if arguments.count > 1 {
                    Button("Remove last argument") { session.draft.set(.array(Array(arguments.dropLast())), at: ["run", "command"]) }
                }
                Text("Each field is one argument; shell syntax requires an explicit shell executable.").scaledFont(.footnote).foregroundStyle(.secondary)
            }
            validationErrors(groups: ["run"])
        }.disabled(locked)
    }
    private var conditionSection: some View {
        Section("Advanced conditions") {
            DisclosureGroup("Precondition and tags") {
                Toggle("Run a precondition command", isOn: Binding(get: { session.draft.value(at: ["filter"])?.objectValue != nil }, set: { enabled in
                    session.draft.set(enabled ? .object(["command": .array([.string("")]), "timeout": .number(30)]) : nil, at: ["filter"])
                }))
                if session.draft.value(at: ["filter"])?.objectValue != nil {
                    argumentFields(path: ["filter", "command"])
                    integer("Precondition timeout (seconds)", path: ["filter", "timeout"])
                }
                validationErrors(groups: ["filter", "tags"])
                Text("Tags").scaledFont(.subheadline)
                argumentFields(path: ["tags"], executableLabel: "Tag", argumentLabel: "Tag")
                if !isAgent {
                    Text("Finding exit codes").scaledFont(.subheadline)
                    let codes = session.draft.value(at: ["run", "finding_exit_codes"])?.arrayValue ?? []
                    ForEach(codes.indices, id: \.self) { index in
                        TextField("Exit code", value: Binding(get: {
                            if case .number(let value) = codes[index] { return Int(value) }; return 1
                        }, set: { value in
                            var current = session.draft.value(at: ["run", "finding_exit_codes"])?.arrayValue ?? []
                            guard current.indices.contains(index) else { return }
                            current[index] = .number(Double(value)); session.draft.set(.array(current), at: ["run", "finding_exit_codes"])
                        }), format: .number)
                    }
                    Button("Add finding exit code") { session.draft.set(.array(codes + [.number(1)]), at: ["run", "finding_exit_codes"]) }
                    if !codes.isEmpty { Button("Remove last exit code") { session.draft.set(.array(Array(codes.dropLast())), at: ["run", "finding_exit_codes"]) } }
                }
            }
        }.disabled(locked)
    }
    private func argumentFields(path: [String], executableLabel: String = "Executable", argumentLabel: String = "Argument") -> some View {
        let values = session.draft.value(at: path)?.arrayValue ?? []
        return VStack {
            ForEach(values.indices, id: \.self) { index in
                TextField(index == 0 ? executableLabel : "\(argumentLabel) \(index)", text: Binding(get: { values[index].stringValue ?? "" }, set: { value in
                    var current = session.draft.value(at: path)?.arrayValue ?? []
                    guard current.indices.contains(index) else { return }
                    current[index] = .string(value); session.draft.set(.array(current), at: path)
                }))
            }
            Button("Add \(argumentLabel.lowercased())") { session.draft.set(.array(values + [.string("")]), at: path) }
            if !values.isEmpty { Button("Remove last \(argumentLabel.lowercased())") { session.draft.set(.array(Array(values.dropLast())), at: path) } }
        }
    }
    private var executionHostPicker: some View {
        let saved = session.draft.text(at: agentPath + ["gateway_host"])
        let hosts = workspace.settings.hosts.compactMap {
            workspace.model(for: $0.id)?.directories.information?.hostname
        } + ["auto"]
        return Picker("Execution host", selection: text(agentPath + ["gateway_host"])) {
            ForEach(Array(Set(hosts + [saved]).filter { !$0.isEmpty }).sorted(), id: \.self) { name in
                Text(name == "auto" ? "Automatic" : name + (workspace.automationExecutionHost(name) != nil ? "" : " (saved, unavailable)")).tag(name)
            }
        }
    }

    private var effortPicker: some View {
        let agent = session.draft.definition.agent ?? [:]
        let saved = agent["effort"]?.stringValue ?? ""
        let models = workspace.automationModels(host: agent["gateway_host"]?.stringValue ?? "",
                                                provider: agent["provider"]?.stringValue ?? "codex")
        let model = models.first { $0.id == agent["model"]?.stringValue }
        let choices = model?.reasoningEfforts.map(\.rawValue) ?? []
        return Picker("Reasoning effort", selection: text(agentPath + ["effort"], optional: true)) {
            Text("Service default").tag("")
            ForEach(choices, id: \.self) { Text($0.capitalized).tag($0) }
            if !saved.isEmpty && !choices.contains(saved) { Text("\(saved) (saved)").tag(saved) }
        }
    }
    private var modelPicker: some View {
        let agent = session.draft.definition.agent ?? [:]
        let saved = agent["model"]?.stringValue ?? ""
        let options = workspace.automationModels(host: agent["gateway_host"]?.stringValue ?? "",
                                                  provider: agent["provider"]?.stringValue ?? "codex")
        return Picker("Model", selection: text(agentPath + ["model"], optional: true)) {
            Text("Service default").tag("")
            ForEach(options) { Text($0.displayName).tag($0.id) }
            if !saved.isEmpty && !options.contains(where: { $0.id == saved }) { Text("\(saved) (saved, unavailable)").tag(saved) }
        }
    }
    @ViewBuilder private func validationErrors(groups: [String], index: Int? = nil) -> some View {
        let fields = session.validationFields.compactMap { $0.presented(whenIsList: session.draft.definition.fields["when"]?.arrayValue != nil) }.filter { field in
            guard let first = field.path.first?.stringValue, groups.contains(first) else { return false }
            if let index, field.path.count > 1, case .number(let value) = field.path[1] { return value == Double(index) }
            return true
        }
        ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
            Text("\(field.label): \(field.message)").scaledFont(.footnote).foregroundStyle(.red)
        }
    }
    private func text(_ path: [String], optional: Bool = false) -> Binding<String> {
        Binding(get: { session.draft.text(at: path) }, set: { session.draft.set(optional && $0.isEmpty ? nil : .string($0), at: path) })
    }
    private func flag(_ path: [String]) -> Binding<Bool> {
        Binding(get: { session.draft.value(at: path) == .bool(true) }, set: { session.draft.set(.bool($0), at: path) })
    }
    private func integer(_ label: String, path: [String]) -> some View {
        TextField(label, value: Binding(get: {
            if case .number(let value) = session.draft.value(at: path) { return Int(value) }; return 0
        }, set: { session.draft.set(.number(Double($0)), at: path) }), format: .number)
    }
    private func commandArgument(_ index: Int) -> Binding<String> {
        Binding(get: { session.draft.value(at: ["run", "command"])?.arrayValue?[index].stringValue ?? "" }, set: { value in
            var args = session.draft.value(at: ["run", "command"])?.arrayValue ?? []
            guard args.indices.contains(index) else { return }
            args[index] = .string(value); session.draft.set(.array(args), at: ["run", "command"])
        })
    }
    private func triggerKind(_ index: Int) -> Binding<String> {
        Binding(get: {
            let trigger = session.draft.definition.triggers[index]
            return ["at", "every", "cron", "event", "imessage"].first { trigger[$0] != nil && trigger[$0] != .null } ?? "every"
        }, set: { kind in
            var trigger = session.draft.definition.triggers[index]
            for key in ["at", "every", "cron", "event", "imessage"] { trigger.removeValue(forKey: key) }
            if kind != "event" { trigger.removeValue(forKey: "source") }
            if kind != "event" && kind != "imessage" { trigger.removeValue(forKey: "match") }
            trigger[kind] = .string(kind == "every" ? "1h" : "")
            session.draft.setTrigger(trigger, index: index)
        })
    }
    private func triggerText(_ index: Int, key: String, optional: Bool = false) -> Binding<String> {
        Binding(get: {
            let value = session.draft.definition.triggers[index][key]
            if case .number(let number) = value { return String(Int(number)) }
            return value?.stringValue ?? ""
        }, set: { text in
            var trigger = session.draft.definition.triggers[index]
            trigger[key] = optional && text.isEmpty ? nil : .string(text)
            session.draft.setTrigger(trigger, index: index)
        })
    }
    @ViewBuilder private func messageReference(_ index: Int) -> some View {
        let value = session.draft.definition.triggers[index]["imessage"]
        let isNumeric: Bool = { if case .number = value { return true }; return false }()
        Picker("Conversation reference", selection: Binding(get: { isNumeric ? "number" : "name" }, set: { type in
            var trigger = session.draft.definition.triggers[index]
            if type == "number" { trigger["imessage"] = .number(Double(Int(trigger["imessage"]?.stringValue ?? "") ?? 0)) }
            else if case .number(let number) = trigger["imessage"] { trigger["imessage"] = .string(String(Int(number))) }
            session.draft.setTrigger(trigger, index: index)
        })) {
            Text("Conversation ID or name").tag("name")
            Text("Local numeric chat ID").tag("number")
        }
        if isNumeric {
            TextField("Chat ID", value: Binding(get: {
                if case .number(let number) = session.draft.definition.triggers[index]["imessage"] { return Int(number) }; return 0
            }, set: { number in
                var trigger = session.draft.definition.triggers[index]; trigger["imessage"] = .number(Double(number)); session.draft.setTrigger(trigger, index: index)
            }), format: .number)
        } else { TextField("Conversation ID or name", text: triggerText(index, key: "imessage")) }
    }
    private func triggerLabel(_ kind: String) -> String {
        switch kind {
        case "at": "Date and time"; case "every": "Interval (for example 30m)"; case "cron": "Five-field cron expression"
        case "event": "Event type"; default: "Messages conversation ID or name"
        }
    }
}
