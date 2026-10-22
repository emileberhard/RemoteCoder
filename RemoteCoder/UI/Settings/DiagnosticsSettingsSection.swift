import SwiftUI

struct DiagnosticsSettingsSection: View {
    @State private var exportedLog: URL?
    @State private var isExporting = false

    var body: some View {
        Section {
            LabeledContent("Version", value: BuildIdentity.currentApp.display)
                .contextMenu {
                    if let commit = BuildIdentity.currentApp.commit {
                        Button("Copy Commit", systemImage: "doc.on.doc") {
                            HapticService.shared.copy(commit)
                        }
                    }
                }
            if let exportedLog {
                ShareLink(item: exportedLog) {
                    Label("Share exported logs", systemImage: "square.and.arrow.up")
                }
            }
            Button {
                HapticService.shared.play(.buttonPress)
                isExporting = true
                Task {
                    let url = await DiagnosticsOutbox.shared.exportArchive()
                    isExporting = false
                    exportedLog = url
                }
            } label: {
                HStack {
                    Label("Export logs", systemImage: "square.and.arrow.up")
                    if isExporting {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isExporting)
        } header: {
            Text("Diagnostics")
        }
    }
}
