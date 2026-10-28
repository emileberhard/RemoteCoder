import SwiftUI

struct ClusterSettingsView: View {
    let workspace: ChatWorkspaceModel
    @Environment(HostStore.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @State private var operation: Operation?

    private enum Operation: Equatable {
        case join(UUID), remove(UUID), retry(UUID)
    }

    private var model: ClusterModel { workspace.cluster }
    private var anchor: UUID? {
        guard let host = settings.activeHost, host.configuration.gatewayID == host.id else { return nil }
        return host.id
    }
    private var members: [ClusterMember] { anchor.flatMap { model.listings[$0]?.members } ?? [] }
    private var writable: Bool { settings.activeHost?.configuration.usesInstallationCredential == false }

    var body: some View {
        SettingsFormPage {
            Section {
                if let failure = model.persistenceFailure { AgentNote(text: failure) }
                if let failure = model.operationFailure { AgentNote(text: failure) }
                if !writable { Label("Read only", systemImage: "lock") }
                if let anchor, let local = model.listings[anchor]?.local {
                    LabeledContent(local.name, value: local.version)
                }
                ForEach(members) { member in
                    memberRow(member)
                }
                if let anchor, let failure = model.failures[anchor] {
                    AgentNote(text: failure)
                }
            } header: { Text("Cluster") }
            Section {
                ForEach(settings.hosts.filter { host in
                    guard let anchor else { return true }
                    return host.id != anchor && !model.isMember(host.id, of: anchor)
                }) { host in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(host.displayName)
                            if host.configuration.gatewayID != host.id {
                                Label("Identity unresolved", systemImage: "questionmark.circle")
                                    .scaledFont(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Join") { operation = .join(host.id) }
                            .disabled(!writable || host.configuration.usesInstallationCredential || host.configuration.gatewayID != host.id || anchor == nil || operation != nil)
                    }
                }
            } header: { Text("Known hosts") }
            ForEach(model.pairs.filter { !$0.complete }) { pair in
                Section {
                    LabeledContent(name(pair.first), value: pair.firstComplete ? "Done" : "Pending")
                    LabeledContent(name(pair.second), value: pair.secondComplete ? "Done" : "Pending")
                    if let error = pair.error { AgentNote(text: error) }
                    Button("Retry", systemImage: "arrow.clockwise") { operation = .retry(pair.id) }
                        .disabled(!writable || model.running.contains(pair.id) || operation != nil)
                } header: { Text(pair.operation == .join ? "Join" : "Remove") }
            }
        }
        .task(id: RefreshKey(hosts: settings.hosts.map(\.configuration), phase: scenePhase)) {
            guard scenePhase == .active else { return }
            await model.refresh(hosts: workspace.clusterHosts)
        }
        .task(id: operation) {
            guard let operation else { return }
            defer { self.operation = nil }
            switch operation {
            case .join(let host):
                if let anchor { await model.join(host, anchor: anchor, hosts: workspace.clusterHosts) }
            case .remove(let host): await model.remove(host, hosts: workspace.clusterHosts)
            case .retry(let pair):
                await model.retry(pair, hosts: workspace.clusterHosts)
                await model.refresh(hosts: workspace.clusterHosts)
            }
        }
    }

    private struct RefreshKey: Equatable {
        let hosts: [GatewayHostConfiguration]
        let phase: ScenePhase
    }

    private func name(_ id: UUID) -> String {
        settings.hosts.first { $0.id == id }?.displayName ?? members.first { $0.id == id }?.name ?? id.uuidString
    }

    private func memberRow(_ member: ClusterMember) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(member.name)
                HStack {
                    Label(member.reachability.state == "reachable" ? "Reachable" : member.reachability.state == "unsupported" ? "Too old" : "Unreachable",
                          systemImage: member.reachability.state == "reachable" ? "checkmark.circle" : "network.slash")
                    if let version = member.version { Text(version) }
                }
                .scaledFont(.caption).foregroundStyle(.secondary)
                if let load = member.load {
                    HStack {
                        if let cpu = load.cpuPercent { Text("CPU \(cpu, specifier: "%.0f")%") }
                        if let pressure = load.memoryPressure { Text("Memory \(pressure)") }
                        if let active = load.activeAgents { Text("\(active) active") }
                    }
                    .scaledFont(.caption).foregroundStyle(.secondary)
                }
                if member.state == "remove_pending" {
                    Label("Remove pending", systemImage: "clock").scaledFont(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if writable {
                Button("Remove", role: .destructive) { operation = .remove(member.id) }
                    .disabled(operation != nil)
            }
        }
    }
}
