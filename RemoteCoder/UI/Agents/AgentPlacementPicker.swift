import SwiftUI

struct AgentPlacementPicker: View {
    let agent: ConversationAddress
    let workspace: ChatWorkspaceModel
    @State private var query = ""
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

    private var candidates: [(address: ConversationAddress, title: String, hostName: String)] {
        workspace.agentParentCandidates.filter {
            $0.address != agent && (query.isEmpty || $0.title.localizedStandardContains(query) || $0.hostName.localizedStandardContains(query))
        }
    }
}
