import SwiftUI

struct GatewayHostsSettings<Page: View>: View {
    @Bindable var settings: HostStore
    let workspace: ChatWorkspaceModel
    @ViewBuilder let page: (GatewayHostsSettingsSection) -> Page
    @State private var editor: HostEditor?
    @State private var gatewayVersions: [UUID: BuildIdentity?] = [:]
    @State private var relayAnswers: [UUID: Bool] = [:]
    @State private var verifyingHost: UUID?
    @State private var identityFailure: String?

    var body: some View {
        page(GatewayHostsSettingsSection(settings: settings, workspace: workspace, editor: $editor,
                                         gatewayVersions: gatewayVersions, relayAnswers: relayAnswers,
                                         identityFailure: identityFailure, verifyingHost: verifyingHost,
                                         verifyIdentity: { verifyingHost = $0 }))
            .sheet(item: $editor) { destination in
                GatewayHostEditorView(host: destination.host, defaultPort: settings.localConfiguration.codexGatewayPort ?? 8787) { host in
                    settings.upsert(host) ? nil : (settings.errorMessage ?? "The gateway could not be saved.")
                }
            }
            .task(id: settings.hosts.map(\.configuration)) {
                gatewayVersions = [:]
                relayAnswers = [:]
                await BoundedFanOut.run(settings.hosts.map(\.configuration), limit: 2, deadline: nil, skipping: { _ in false }) { host in
                    let routes = workspace.model(for: host.id)?.hostServices.routes
                    let identity = try? await routes?.version()
                    guard !Task.isCancelled else { return }
                    gatewayVersions.updateValue(identity, forKey: host.id)
                    let relayAnswered = await routes?.probeRelay()
                    guard !Task.isCancelled else { return }
                    relayAnswers[host.id] = relayAnswered
                }
            }
            .task(id: verifyingHost) {
                guard let verifyingHost else { return }
                defer { self.verifyingHost = nil }
                do {
                    try await workspace.verifyGatewayIdentity(hostID: verifyingHost)
                    identityFailure = nil
                } catch { if !Task.isCancelled { identityFailure = error.localizedDescription } }
            }
    }
}

fileprivate enum HostEditor: Identifiable {
    case new
    case existing(GatewayHostConfiguration)

    var id: String {
        switch self {
        case .new: "new"
        case .existing(let host): host.id.uuidString
        }
    }

    var host: GatewayHostConfiguration? {
        switch self {
        case .new: nil
        case .existing(let host): host
        }
    }
}

struct GatewayHostsSettingsSection: View {
    @Bindable var settings: HostStore
    let workspace: ChatWorkspaceModel
    @Binding fileprivate var editor: HostEditor?
    let gatewayVersions: [UUID: BuildIdentity?]
    let relayAnswers: [UUID: Bool]
    let identityFailure: String?
    let verifyingHost: UUID?
    let verifyIdentity: (UUID) -> Void

    var body: some View {
        Section {
            if let identityFailure { AgentNote(text: identityFailure) }
            if let error = settings.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Button("Retry loading saved hosts") {
                    HapticService.shared.play(.buttonPress)
                    settings.reload()
                }
            }
            if let failure = settings.syncFailure {
                Label(failure, systemImage: "icloud.slash")
                    .foregroundStyle(.orange)
            }
            if settings.hosts.isEmpty {
                Text("Add a host to start using RemoteCoder.")
                    .foregroundStyle(.secondary)
            }

            ForEach(settings.hosts) { host in
                hostRow(for: host.configuration)
            }
            ForEach(settings.invalidHosts) { host in
                invalidHostRow(for: host)
            }

            Button("Add host", systemImage: "plus") {
                HapticService.shared.play(.buttonPress)
                editor = .new
            }
            Button("Create installation credentials") {
                HapticService.shared.play(.buttonPress)
                Task {
                    await workspace.enrollInstallationCredentials()
                }
            }
        } header: {
            Text("Gateway hosts")
        }
    }

    private static func name(of route: GatewayRoute.Kind, for host: GatewayHostConfiguration) -> String {
        switch route {
        case .lan: "local network"
        case .configured: isTailnet(host.hostname) ? "Tailscale" : host.connectionSummary
        case .relay: "relay"
        }
    }

    private static func symbol(of route: GatewayRoute.Kind) -> String {
        switch route {
        case .lan: "wifi"
        case .configured: "network"
        case .relay: "shield.lefthalf.filled"
        }
    }

    private static func isTailnet(_ hostname: String) -> Bool {
        if hostname.lowercased().hasSuffix(".ts.net") { return true }
        let octets = hostname.split(separator: ".").compactMap { UInt8($0) }
        return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
    }

    private func hostRow(for host: GatewayHostConfiguration) -> some View {
        HStack(spacing: 12) {
            Button {
                let previous = settings.activeHostID
                settings.setActiveHost(host)
                if settings.activeHostID != previous { HapticService.shared.play(.selection) }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(host.displayName)
                            .foregroundStyle(.primary)
                        Text(host.connectionSummary)
                            .scaledFont(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(gatewayVersions[host.id].map { $0?.display ?? "Unavailable" } ?? "Loading…")
                            .scaledFont(.subheadline)
                            .foregroundStyle(.secondary)
                        if let route = workspace.model(for: host.id)?.gatewayRoute {
                            Label("Connected via \(Self.name(of: route, for: host))", systemImage: Self.symbol(of: route))
                                .scaledFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let relayAnswered = relayAnswers[host.id] {
                            Label(relayAnswered ? "Relay ready" : "Relay unreachable",
                                  systemImage: relayAnswered ? "checkmark.shield" : "exclamationmark.shield")
                                .scaledFont(.caption)
                                .foregroundStyle(relayAnswered ? Color.secondary : Color.orange)
                        }
                        if let failure = workspace.model(for: host.id)?.hostServices.registration.failure {
                            Label(failure, systemImage: "exclamationmark.triangle.fill")
                                .scaledFont(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer(minLength: 0)
                    if host.id == settings.activeHostID {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: ControlMetrics.minimumTarget, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(host.id == settings.activeHostID ? "Active" : "")

            AppMenu(trigger: .icon) {
                if let commit = gatewayVersions[host.id]??.commit {
                    Button("Copy Gateway Commit", systemImage: "doc.on.doc") {
                        HapticService.shared.copy(commit)
                    }
                }
                Button("Edit", systemImage: "pencil") { editor = .existing(host) }
                if host.gatewayID != host.id {
                    Button("Verify identity", systemImage: "checkmark.shield") { verifyIdentity(host.id) }
                        .disabled(verifyingHost != nil)
                }
                if settings.hosts.count > 1 {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        HapticService.shared.play(settings.delete(host) ? .commit : .error)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(minWidth: ControlMetrics.minimumTarget, minHeight: ControlMetrics.minimumTarget)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Options for \(host.displayName)")
            .tooltip("Show options for \(host.displayName)")
        }
    }

    private func invalidHostRow(for host: GatewayHostConfiguration) -> some View {
        HStack(spacing: 12) {
            Button {
                editor = .existing(host)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(host.displayName)
                            .foregroundStyle(.primary)
                        Text(host.connectionSummary)
                            .scaledFont(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .frame(maxWidth: .infinity, minHeight: ControlMetrics.minimumTarget, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue("Invalid address or authorization token")

            AppMenu(trigger: .icon) {
                Button("Edit", systemImage: "pencil") { editor = .existing(host) }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    HapticService.shared.play(settings.delete(host) ? .commit : .error)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(minWidth: ControlMetrics.minimumTarget, minHeight: ControlMetrics.minimumTarget)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Options for \(host.displayName)")
            .tooltip("Show options for \(host.displayName)")
        }
    }
}

struct GatewayHostEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var hostname: String
    @State private var port: String
    @State private var authToken: String
    @State private var transport: GatewayTransport
    @State private var errorMessage: String?

    private let existingID: UUID?
    private let onSave: (GatewayHostConfiguration) -> String?

    init(
        host: GatewayHostConfiguration?,
        defaultPort: Int,
        onSave: @escaping (GatewayHostConfiguration) -> String?
    ) {
        self.onSave = onSave
        self._name = State(initialValue: host?.name ?? "")
        self._hostname = State(initialValue: host?.hostname ?? "")
        self._port = State(initialValue: String(host?.port ?? defaultPort))
        self._authToken = State(initialValue: host?.authToken ?? "")
        self._transport = State(initialValue: host?.transport ?? .tls)
        self.existingID = host?.id
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Name (optional)", text: $name)

                    TextField("Hostname", text: $hostname)
                        .noAutocapitalization()
                        .autocorrectionDisabled()

                    Picker("Transport", selection: $transport.nativeSelectionFeedback()) {
                        ForEach(GatewayTransport.allCases, id: \.self) { transport in
                            Text(transport.label).tag(transport)
                        }
                    }
                    if transport == .trustedNetwork {
                        Text("HTTP has no application-layer encryption. Use it only on an explicitly trusted private network, such as your Tailscale connection.")
                            .scaledFont(.footnote).foregroundStyle(.secondary)
                    }
                    TextField("Port", text: $port)
                        .numericKeyboard()
                }
                .listRowBackground(Color.primary.opacity(0.06))

                Section {
                    SecureField("Authorization token", text: $authToken)
                        .noAutocapitalization()
                        .autocorrectionDisabled()
                } header: {
                    Text("Authentication")
                }
                .listRowBackground(Color.primary.opacity(0.06))

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .scaledFont(.footnote)
                            .foregroundStyle(.red)
                    }
                    .listRowBackground(Color.primary.opacity(0.06))
                }
            }
            .scrollContentBackground(.hidden)
            .clearNavigationBackground()
            .navigationTitle(existingID == nil ? "Add Host" : "Edit Host")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        HapticService.shared.play(.disclosure)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
    }

    private func save() {
        let trimmedHostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedHostname.isEmpty else {
            errorMessage = "Hostname is required."
            HapticService.shared.play(.error)
            return
        }

        guard let portValue = Int(port), (1...65535).contains(portValue) else {
            errorMessage = "Port must be between 1 and 65535."
            HapticService.shared.play(.error)
            return
        }

        guard !trimmedToken.isEmpty else {
            errorMessage = "Authorization token is required."
            HapticService.shared.play(.error)
            return
        }

        let config = GatewayHostConfiguration(
            id: existingID ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            hostname: trimmedHostname,
            port: portValue,
            authToken: trimmedToken,
            transport: transport
        )

        guard config.gatewayWebSocketURL() != nil else {
            errorMessage = "Enter a hostname without a scheme, path, or user information."
            HapticService.shared.play(.error)
            return
        }
        if let failure = onSave(config) {
            errorMessage = failure
            HapticService.shared.play(.error)
        } else {
            HapticService.shared.play(.commit)
            dismiss()
        }
    }
}
