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

struct CodexModelsSettingsRow: View {
    let catalog: CodexModelCatalogSourceState
    let preferences: ModelPickerPreferences

    var body: some View {
        switch catalog {
        case .available(let source):
            NavigationLink {
                CodexModelsSettingsPage(catalog: source, preferences: preferences)
            } label: {
                ProviderSettingsLabel(provider: .codex, value: shownCount(source) ?? "Not Loaded")
            }
            .accessibilityIdentifier("codex-models-settings")
        case .noHosts:
            ProviderSettingsLabel(provider: .codex, value: "No Host")
                .foregroundStyle(.secondary)
        case .hostUnavailable:
            ProviderSettingsLabel(provider: .codex, value: "Unavailable")
                .foregroundStyle(.secondary)
        }
    }

    private func shownCount(_ source: CodexModelCatalogSource) -> String? {
        guard let entries = source.service.catalog?.entries.filter({ $0.option.provider == .codex }) else { return nil }
        return "\(entries.filter(preferences.codexModelVisibility.isVisible).count) of \(entries.count)"
    }
}

private struct CodexModelsSettingsPage: View {
    let catalog: CodexModelCatalogSource
    let preferences: ModelPickerPreferences

    private var service: CodexModelCatalogService { catalog.service }
    private var entries: [CodexModelCatalog.Entry] { service.catalog?.entries.filter { $0.option.provider == .codex } ?? [] }

    var body: some View {
        SettingsPage(title: "Codex") {
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

            HostModelsSection(entries: entries.filter { !$0.isHiddenUpstream }, header: "Shown in Pickers",
                              footer: "New models appear automatically. Conversations keep their model even when you hide it.",
                              preferences: preferences)
            HostModelsSection(entries: entries.filter(\.isHiddenUpstream), header: "Hidden by the Host",
                              footer: "The host hides these by default. Turn one on to add it to the pickers.",
                              preferences: preferences)
            ReasoningLevelsSection(provider: .codex, models: entries.map(\.option), preferences: preferences)
        }
    }
}

struct HostModelsSection: View {
    let entries: [CodexModelCatalog.Entry]
    let header: LocalizedStringKey
    let footer: LocalizedStringKey
    let preferences: ModelPickerPreferences

    var body: some View {
        if !entries.isEmpty {
            Section {
                ForEach(entries) { entry in
                    Toggle(isOn: Binding(get: { preferences.codexModelVisibility.isVisible(entry) },
                                         set: { preferences.setModelVisible($0, for: entry) })) {
                        VStack(alignment: .leading, spacing: 4) {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 6) {
                                    Text(entry.option.pickerTitle)
                                    if entry.option.supportsDaybreakBlue { DaybreakBlueBadge() }
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.option.pickerTitle)
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
}
