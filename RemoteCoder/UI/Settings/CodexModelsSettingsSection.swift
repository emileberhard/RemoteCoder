import SwiftUI

struct CodexModelCatalogSource {
    let service: CodexModelCatalogService
    let sourceLabel: String
    let refresh: @MainActor () async -> Void
}

enum CodexModelCatalogSourceState {
    case noHosts
    case hostUnavailable
    case available(CodexModelCatalogSource)

    var source: CodexModelCatalogSource? {
        if case .available(let source) = self { source } else { nil }
    }
}

struct CodexModelsSettingsSection: View {
    let catalog: CodexModelCatalogSourceState
    let preferences: ModelPickerPreferences

    private var shownCount: String? {
        guard let entries = catalog.source?.service.catalog?.entries else { return nil }
        return "\(entries.filter(preferences.codexModelVisibility.isVisible).count) of \(entries.count) shown"
    }

    var body: some View {
        Section {
            switch catalog {
            case .available(let catalog):
                NavigationLink {
                    CodexModelsSettingsPage(catalog: catalog, preferences: preferences)
                } label: {
                    LabeledContent("Models", value: shownCount ?? "Not loaded")
                }
                .accessibilityIdentifier("codex-models-settings")
            case .noHosts:
                Text("Add a host that runs Codex to choose its models.")
                    .foregroundStyle(.secondary)
            case .hostUnavailable:
                Text("The selected host is unavailable.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Codex models")
        }
    }
}

private struct CodexModelsSettingsPage: View {
    let catalog: CodexModelCatalogSource
    let preferences: ModelPickerPreferences

    private var service: CodexModelCatalogService { catalog.service }
    private var entries: [CodexModelCatalog.Entry] { service.catalog?.entries ?? [] }

    var body: some View {
        Form {
            Section {
                LabeledContent("Source", value: catalog.sourceLabel)
                LabeledContent("Updated") {
                    if let fetchedAt = service.catalog?.fetchedAt {
                        Text(fetchedAt, format: .relative(presentation: .named))
                    } else {
                        Text("Unknown")
                    }
                }
                Button {
                    HapticService.shared.play(.buttonPress)
                    Task { await catalog.refresh() }
                } label: {
                    HStack {
                        Label("Refresh", systemImage: "arrow.clockwise")
                        if service.isRefreshing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(service.isRefreshing)
                .accessibilityIdentifier("codex-models-refresh")
                if let error = service.refreshError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .scaledFont(.subheadline)
                        .foregroundStyle(.red)
                }
            } footer: {
                if service.refreshError != nil, service.catalog != nil {
                    Text("Showing the last list the host reported.")
                }
            }

            modelSection(entries.filter { !$0.isHiddenUpstream }, header: "Shown in pickers",
                         footer: "New models appear automatically. Conversations keep their model even when you hide it.")
            modelSection(entries.filter(\.isHiddenUpstream), header: "Hidden by the host",
                         footer: "The host hides these by default. Turn one on to add it to the pickers.")
        }
        .navigationTitle("Codex Models")
        .inlineNavigationTitle()
    }

    @ViewBuilder
    private func modelSection(_ entries: [CodexModelCatalog.Entry], header: String, footer: String) -> some View {
        if !entries.isEmpty {
            Section {
                ForEach(entries) { entry in
                    Toggle(isOn: visibilityBinding(for: entry)) {
                        VStack(alignment: .leading, spacing: 4) {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 6) {
                                    Text(entry.option.displayName)
                                    if entry.option.supportsDaybreakBlue { DaybreakBlueBadge() }
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.option.displayName)
                                    if entry.option.supportsDaybreakBlue { DaybreakBlueBadge() }
                                }
                            }
                            Text(details(for: entry))
                                .scaledFont(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("codex-model-visible-\(entry.id)")
                }
            } header: {
                Text(header)
            } footer: {
                Text(footer)
            }
        }
    }

    private func details(for entry: CodexModelCatalog.Entry) -> String {
        [entry.summary, entry.option.acceptsImages ? nil : "Text only", entry.isUpstreamDefault ? "Host default" : nil]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")
    }

    private func visibilityBinding(for entry: CodexModelCatalog.Entry) -> Binding<Bool> {
        Binding(get: { preferences.codexModelVisibility.isVisible(entry) },
                set: { preferences.setModelVisible($0, for: entry) })
    }
}
