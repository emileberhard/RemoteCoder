import SwiftUI

struct AgentPlacementPicker: View {
    let agent: ConversationAddress
    let workspace: ChatWorkspaceModel
    @State private var query = ""
    @State private var candidates: [(address: ConversationAddress, title: String, hostName: String)] = []
    @State private var destination: ConversationAddress?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section { ClusterCoverageStrip(coverage: workspace.agentCoverage) }
                if let error { Section { AgentNote(text: error) } }
                ForEach(candidates, id: \.address) { candidate in
                    Button {
                        destination = candidate.address
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(candidate.title).foregroundStyle(.primary)
                            Text(candidate.hostName).scaledFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(destination != nil)
                }
            }
            .navigationTitle("Move under…")
            .inlineNavigationTitle()
            .searchable(text: $query, prompt: "Search agents")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
            .task(id: query) {
                let prepared = await workspace.agentParentCandidates(excluding: agent, query: query)
                guard !Task.isCancelled else { return }
                candidates = prepared
            }
            .task(id: destination) {
                guard let destination else { return }
                defer { self.destination = nil }
                do {
                    try await workspace.moveAgent(agent, under: destination)
                    HapticService.shared.play(.success)
                    dismiss()
                } catch {
                    if !Task.isCancelled { self.error = error.localizedDescription }
                }
            }
        }
    }

}
