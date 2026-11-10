import SwiftUI

struct ConversationSearchList: View {
    let search: ConversationSearchSession
    let open: (ConversationSearchRow) -> ChatWorkspaceModel.ConversationSwitchOutcome
    let ask: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let results = search.results
        ScrollView {
            LazyVStack(spacing: 10) {
                section(results.titles, title: "Titles", systemImage: "textformat", isFirst: true)
                section(results.messages, title: "Messages", systemImage: "text.bubble",
                        isFirst: results.titles.rows.isEmpty)
                section(results.meaning, title: "By meaning", systemImage: "sparkles",
                        isFirst: results.titles.rows.isEmpty && results.messages.rows.isEmpty)
                if results.isPainted, results.isEmpty, !results.status.isSearching {
                    ContentUnavailableView.search
                        .padding(.vertical, 20)
                }
                ConversationSearchStatusRow(status: results.status)
                Button(action: ask) {
                    Label("Ask an agent", systemImage: "sparkle.magnifyingglass")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .appContentSurface(.standard, in: .rect(cornerRadius: 14))
                .accessibilityIdentifier("ask-conversation-search")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentMargins(.horizontal, 12, for: .scrollContent)
        .contentMargins(.top, 6, for: .scrollContent)
        .contentMargins(.bottom, 20, for: .scrollContent)
        .scrollIndicators(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder
    private func section(_ section: ConversationSearchSection, title: LocalizedStringKey, systemImage: String,
                         isFirst: Bool) -> some View {
        if !section.rows.isEmpty {
            DrawerSectionHeader(title: title, systemImage: systemImage, isFirst: isFirst)
            ForEach(section.visibleRows) { row in
                ConversationSearchCard(row: row) {
                    search.recordOpening(row)
                    _ = open(row)
                }
                .equatable()
                .accessibilityIdentifier("search-result-\(row.id)")
            }
            if section.hiddenRowCount > 0 {
                DrawerMoreButton(title: "Show \(section.hiddenRowCount) more") {
                    withAnimation(reduceMotion ? nil : .snappy) { search.reveal(section.kind) }
                }
            }
        }
    }
}

private struct ConversationSearchCard: View, Equatable {
    let row: ConversationSearchRow
    let open: () -> Void
    @Environment(AppThemeStore.self) private var themeStore
    @ScaledMetric(relativeTo: .caption2) private var markSize: CGFloat = 13

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.row == rhs.row }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    headline
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let dateLabel = row.dateLabel {
                        Text(dateLabel)
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    Image(row.provider.markImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: markSize, height: markSize)
                        .foregroundStyle(row.provider.markStyle)
                        .accessibilityLabel("\(row.provider.displayName) conversation")
                    if let folder = row.folder {
                        Text(folder)
                            .truncationMode(.middle)
                    }
                    if let hostName = row.hostName {
                        Text(hostName)
                            .fontWeight(.semibold)
                            .foregroundStyle(themeStore.theme.colors.accentTint)
                            .layoutPriority(1)
                    }
                    Spacer(minLength: 6)
                    if row.additionalHitCount > 0 {
                        Text("+\(row.additionalHitCount) more")
                            .monospacedDigit()
                            .layoutPriority(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if let excerpt = row.excerpt {
                    Text(excerpt)
                        .font(.footnote)
                        .foregroundStyle(row.section == .meaning ? AnyShapeStyle(themeStore.theme.colors.accentTint) : AnyShapeStyle(.secondary))
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                }
            }
            .contentTransition(.identity)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassTapTarget(cornerRadius: 16)
        }
        .buttonStyle(ResponsiveButtonStyle(feedback: nil, pressedScale: 0.985, pressedOpacity: 0.94))
        .accessibilityElement(children: .combine)
        .appContentSurface(.standard, in: .rect(cornerRadius: 16))
    }

    @ViewBuilder
    private var headline: some View {
        switch row.headline {
        case let .title(title): Text(title).foregroundStyle(.primary)
        case let .excerpt(excerpt): Text(excerpt).foregroundStyle(.primary)
        case .untitled: Text("Untitled").foregroundStyle(.secondary)
        }
    }
}

private struct ConversationSearchStatusRow: View {
    let status: ConversationSearchStatus

    var body: some View {
        HStack(spacing: 6) {
            if status.isSearching {
                ProgressView()
                    .controlSize(.mini)
                Text("Searching…")
            } else if let summary = status.unavailableSummary {
                Text(summary)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .lineLimit(2, reservesSpace: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DrawerSearchField: View {
    @Bindable var search: ConversationSearchSession
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search", text: $search.query)
                .focused($isFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("drawer-search")
            if !search.query.isEmpty {
                Button {
                    search.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: ControlMetrics.minimumTarget, minHeight: ControlMetrics.minimumTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(ResponsiveButtonStyle(feedback: nil, pressedScale: 0.9, pressedOpacity: 0.8))
                .accessibilityLabel("Clear Search")
            }
        }
        .font(.body)
        .padding(.leading, 16)
        .padding(.trailing, search.query.isEmpty ? 16 : 2)
        .frame(height: 48)
        .appContentSurface(.standard, in: .capsule)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background {
            if isFocused { HiddenDrawerFocusRelease(isFocused: $isFocused) }
        }
    }
}

private struct HiddenDrawerFocusRelease: View {
    @FocusState.Binding var isFocused: Bool
    @Environment(\.surfaceVisibility) private var visibility

    var body: some View {
        Color.clear
            .onChange(of: visibility.isVisible) { _, visible in
                if !visible { isFocused = false }
            }
    }
}

struct DrawerSectionHeader: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isFirst: Bool
    @ScaledMetric(relativeTo: .subheadline) private var iconWidth: CGFloat = 18

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: iconWidth, alignment: .center)
                .accessibilityHidden(true)
            Text(title)
        }
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, isFirst ? 6 : 14)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct DrawerMoreButton: View {
    let title: String
    let action: () -> Void
    @Environment(AppThemeStore.self) private var themeStore
    @ScaledMetric(relativeTo: .subheadline) private var iconWidth: CGFloat = 18

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .frame(width: iconWidth, alignment: .center)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(themeStore.theme.colors.accentTint)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: ControlMetrics.minimumTarget, alignment: .leading)
            .contentShape(.rect)
        }
        .padding(.vertical, -6)
        .buttonStyle(ResponsiveButtonStyle(feedback: .disclosure, pressedScale: 0.99, pressedOpacity: 0.8))
    }
}
