import SwiftUI

struct HostAvailabilityLines: View {
    let target: ChatTargetModel
    let workspace: ChatWorkspaceModel

    var body: some View {
        HostAvailabilityLineList(lines: workspace.presentation(of: target).chat,
                                 detail: target.connectionFailureDetail,
                                 retry: { Task { try? await target.connectNow() } })
    }
}

struct HostAvailabilityLineList: View {
    let lines: [HostPresentation.Line]
    let detail: () async -> String?
    let retry: () -> Void

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines, id: \.text) { line in
                    if line.tone == .warning {
                        HostProblemLine(text: line.text, detail: detail, retry: retry)
                    } else {
                        Text(verbatim: line.text)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .scaledFont(.footnote)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct HostProblemLine: View {
    let text: String
    let detail: () async -> String?
    let retry: () -> Void
    @State private var showsDetail = false
    @State private var loadedDetail: String?

    var body: some View {
        Button { showsDetail = true } label: {
            Label(text, systemImage: "network.slash")
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsDetail) {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: loadedDetail ?? text)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") {
                    showsDetail = false
                    retry()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .frame(idealWidth: 300)
            .presentationCompactAdaptation(.popover)
            .task { loadedDetail = await detail() }
        }
    }
}
