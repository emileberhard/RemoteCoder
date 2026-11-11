#if os(macOS)
import SwiftUI

struct ConversationSearchList: View {
    let search: ConversationSearchSession
    let open: (ConversationSearchRow) -> ChatWorkspaceModel.ConversationSwitchOutcome
    let ask: () -> Void

    var body: some View {
        let results = search.results
        List {
            section(results.titles, title: "Titles")
            section(results.messages, title: "Messages")
            section(results.meaning, title: "By meaning")
            if results.isPainted, results.isEmpty, results.status.isComplete { ContentUnavailableView.search }
            ConversationSearchStatusRow(status: results.status)
            Button(action: ask) { Label("Ask an agent", systemImage: "sparkle.magnifyingglass") }
                .accessibilityIdentifier("ask-conversation-search")
        }
        .listStyle(.sidebar)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    @ViewBuilder
    private func section(_ section: ConversationSearchSection, title: LocalizedStringKey) -> some View {
        if !section.rows.isEmpty {
            Section(title) {
                ForEach(section.visibleRows) { row in
                    ConversationSearchSourceRow(row: row) {
                        search.recordOpening(row)
                        _ = open(row)
                    }
                    .equatable()
                    .accessibilityIdentifier("search-result-\(row.id)")
                }
                if section.hiddenRowCount > 0 {
                    Button("Show \(section.hiddenRowCount) more") { search.reveal(section.kind) }
                        .buttonStyle(.link)
                }
            }
        }
    }
}

private struct ConversationSearchSourceRow: View, Equatable {
    let row: ConversationSearchRow
    let open: () -> Void
    @Environment(\.sidebarRowSize) private var rowSize
    @Environment(\.interfaceScale) private var scale

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.row == rhs.row }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    headline
                        .scaledFont(rowSize.titleFont)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let dateLabel = row.dateLabel {
                        Text(dateLabel)
                            .scaledFont(rowSize.detailFont)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 4) {
                    Image(row.provider.markImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: rowSize.markSize * scale, height: rowSize.markSize * scale)
                        .accessibilityLabel("\(row.provider.displayName) conversation")
                    if let folder = row.folder {
                        Text(folder)
                            .truncationMode(.middle)
                    }
                    if let hostName = row.hostName {
                        Text("·")
                        Text(hostName)
                            .layoutPriority(1)
                    }
                    Spacer(minLength: 4)
                    if let label = row.additionalHitLabel {
                        Text(label)
                            .monospacedDigit()
                            .layoutPriority(1)
                    }
                }
                .scaledFont(rowSize.detailFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if let excerpt = row.excerpt {
                    Text(excerpt)
                        .scaledFont(rowSize.detailFont)
                        .foregroundStyle(row.section == .meaning ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .lineLimit(2, reservesSpace: true)
                }
            }
            .contentTransition(.identity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var headline: some View {
        switch row.headline {
        case let .title(title): Text(title)
        case let .excerpt(excerpt): Text(excerpt)
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
            }
            if let summary = status.summary { Text(summary) }
        }
        .scaledFont(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
#endif
