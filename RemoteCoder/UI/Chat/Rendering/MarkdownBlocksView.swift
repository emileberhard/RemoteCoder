import SwiftUI

#if DEBUG
@MainActor
final class MarkdownBlockBodyCounter {
    private(set) var counts: [Int: Int] = [:]
    private(set) var menuOwner: ChatBubbleMenuOwner?
    private(set) var capturePermissions: [Int: Bool] = [:]

    func record(index: Int, menuOwner: ChatBubbleMenuOwner?) {
        counts[index, default: 0] += 1
        self.menuOwner = menuOwner
    }

    func recordCapturePermission(index: Int, captureAllowed: Bool) {
        capturePermissions[index] = captureAllowed
    }
}

extension EnvironmentValues {
    @Entry var markdownBlockBodyCounter: MarkdownBlockBodyCounter?
}
#endif

/// Displays pre-rendered markdown blocks. All parsing and highlighting happens
/// off the main actor in `MarkdownRendering`; these views only draw.
struct MarkdownBlocksView: View {
    let blocks: [RenderedMarkdownBlock]
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.transcriptRowPresentation) private var rowPresentation
    #if os(macOS)
    @Environment(\.transcriptTextSelectionEnabled) private var textSelectionEnabled
    @Environment(\.transcriptSurfaceActivity) private var surfaceActivity
    #endif

    #if os(macOS)
    private func selectionEnabled(at index: Int) -> Bool {
        if textSelectionEnabled || index != blocks.count - 1 { return true }
        switch blocks[index].content {
        case .codeBlock(_, _, let presentation): return !presentation.isStreaming
        default: return false
        }
    }
    #endif

    var body: some View {
        let _ = PerfBuild.count("markdown.body")
        #if os(macOS)
        let _ = surfaceActivity?.recordBody()
        #endif
        VStack(alignment: .leading, spacing: MarkdownBlockView.spacing * interfaceScale) {
            ForEach(blocks.indices, id: \.self) { index in
                MarkdownBlockView(block: blocks[index], isFirst: index == 0)
                    .equatable()
                    .environment(\.transcriptBlockIndex, index)
                    #if os(macOS)
                    .environment(\.transcriptTextSelectionEnabled, selectionEnabled(at: index))
                    #endif
                    .transition(.opacity)
            }
        }
        .onChange(of: blocks.count, initial: true) { _, count in rowPresentation?.retainBlocks(count: count) }
    }
}

struct MarkdownBlockView: View, Equatable {
    static let spacing: CGFloat = 14
    let block: RenderedMarkdownBlock
    let isFirst: Bool
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.chatBubbleMenuOwner) private var menuOwner
    #if DEBUG
    @Environment(\.markdownBlockBodyCounter) private var bodyCounter
    @Environment(\.transcriptBlockIndex) private var blockIndex
    #endif

    var body: some View {
        #if DEBUG
        let _ = bodyCounter?.record(index: blockIndex ?? -1, menuOwner: menuOwner)
        #endif
        if case .htmlVisual = block.content {
            blockContent
        } else if let menuOwner {
            blockContent.modifier(ChatBubbleContextMenu(owner: menuOwner))
        } else {
            blockContent
        }
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.block == rhs.block && lhs.isFirst == rhs.isFirst
    }

    @ViewBuilder private var blockContent: some View {
        switch block.content {
        case .heading(let level, let text):
            let _ = PerfBuild.count("block.body.other")
            InlineMarkdownText(text: text)
                .scaledFont(headingFont(for: level))
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .padding(.top, isFirst ? 0 : (level == 1 ? 20 : 18) * interfaceScale)
                .padding(.bottom, 2 * interfaceScale)
                .transcriptTextSelection()
                .accessibilityHeading(accessibilityHeadingLevel(for: level))

        case .htmlVisual(let url, let title):
            HTMLVisualInline(url: url, title: title)

        case .images(let images):
            let _ = PerfBuild.count("block.body.other")
            VStack(alignment: .leading, spacing: 10 * interfaceScale) {
                ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                    ChatImageView(url: image.url, alt: image.alt)
                }
            }
            .padding(.vertical, isFirst ? 0 : 4 * interfaceScale)

        case .bulletList(let items):
            let _ = PerfBuild.count("block.body.list")
            VStack(alignment: .leading, spacing: 16 * interfaceScale) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        InlineMarkdownText(text: item.content)
                            .foregroundStyle(.primary)
                    }
                    .padding(.leading, CGFloat(item.level) * 16)
                }
            }
            .padding(.leading, 8)
            .transcriptTextSelection()

        case .codeBlock(let language, let code, let presentation):
            let _ = PerfBuild.count("block.body.code")
            CodeBlockView(code: code, language: language, presentation: presentation)
                .padding(.vertical, isFirst ? 0 : 6 * interfaceScale)

        case .mermaid(let source, let isComplete):
            let _ = PerfBuild.count("block.body.other")
            MermaidDiagramView(source: source, isComplete: isComplete)
                .padding(.vertical, isFirst ? 0 : 6 * interfaceScale)

        case .table(let headers, let alignments, let rows, let columnCharacterCounts):
            let _ = PerfBuild.count("block.body.table")
            MarkdownTableView(headers: headers, alignments: alignments, rows: rows,
                              columnCharacterCounts: columnCharacterCounts)

        case .paragraph(let text):
            let _ = PerfBuild.count("block.body.paragraph")
            InlineMarkdownText(text: text)
                .foregroundStyle(.primary)
                .padding(.bottom, 2 * interfaceScale)
                .transcriptTextSelection()

        case .quote(let text):
            let _ = PerfBuild.count("block.body.other")
            InlineMarkdownText(text: text)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(.tertiary)
                        .frame(width: 3)
                }
                .padding(.bottom, 2 * interfaceScale)
                .transcriptTextSelection()
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        case 3: return .headline
        default: return .body
        }
    }

    private func accessibilityHeadingLevel(for level: Int) -> AccessibilityHeadingLevel {
        switch level {
        case 1: .h1
        case 2: .h2
        case 3: .h3
        case 4: .h4
        case 5: .h5
        case 6: .h6
        default: .unspecified
        }
    }
}

private struct MarkdownTableView: View {
    let headers: [AttributedString]
    let alignments: [TableAlignment]
    let rows: [[AttributedString]]
    let columnCharacterCounts: [Int]
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppThemeStore.self) private var themeStore
    #if os(macOS)
    @State private var idealWidth: CGFloat?
    #endif

    var body: some View {
        #if os(macOS)
        table
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { idealWidth = $0 }
            .transcriptTextSelection()
            .transcriptHorizontalScroll()
            .frame(idealWidth: idealWidth, maxWidth: idealWidth, alignment: .leading)
            .transcriptContentCard()
        #else
        ViewThatFits(in: .horizontal) {
            table.transcriptTextSelection().fixedSize(horizontal: true, vertical: false)
            table.transcriptTextSelection().transcriptHorizontalScroll()
        }
        .transcriptContentCard()
        #endif
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 0) {
                ForEach(Array(headers.enumerated()), id: \.offset) { colIdx, header in
                    InlineMarkdownText(text: header)
                        .scaledFont(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .frame(
                            minWidth: columnMinWidth(for: colIdx),
                            alignment: alignment(for: colIdx)
                        )
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                }
            }
            .background(tableHeaderBackground, in: UnevenRoundedRectangle(
                topLeadingRadius: TranscriptContentCard.cornerRadius,
                topTrailingRadius: TranscriptContentCard.cornerRadius))

            Divider().opacity(0.4)

            // Data rows
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { colIdx, cell in
                        InlineMarkdownText(text: cell)
                            .scaledFont(.caption)
                            .foregroundStyle(.primary)
                            .frame(
                                minWidth: columnMinWidth(for: colIdx),
                                alignment: alignment(for: colIdx)
                            )
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                }
                .background(rowIdx.isMultiple(of: 2) ? Color.clear : tableAltRowBackground)

                if rowIdx < rows.count - 1 {
                    Divider().opacity(0.15)
                }
            }
        }
    }

    private var tableHeaderBackground: Color {
        themeStore.theme.selectedOptionTint(for: colorScheme)
    }

    private var tableAltRowBackground: Color {
        themeStore.theme.messageAttachmentTint(for: colorScheme)
    }

    private func alignment(for colIdx: Int) -> Alignment {
        guard colIdx < alignments.count else { return .leading }
        switch alignments[colIdx] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func columnMinWidth(for colIdx: Int) -> CGFloat {
        guard colIdx < columnCharacterCounts.count else { return 50 }
        return min(max(CGFloat(columnCharacterCounts[colIdx]) * 7.5 + 20, 50), 220)
    }
}

struct CodeCopyFeedback {
    private(set) var generation = 0
    private(set) var isVisible = false

    mutating func show() {
        generation &+= 1
        isVisible = true
    }

    mutating func hide(ifGeneration generation: Int) {
        guard self.generation == generation else { return }
        isVisible = false
    }
}

private struct CodeBlockView: View {
    let code: String
    let language: String?
    let presentation: RenderedCodePresentation
    @State private var localShowsAllLines = false
    @Environment(\.transcriptRowPresentation) private var rowPresentation
    @Environment(\.transcriptBlockIndex) private var blockIndex

    private var showsAllLines: Bool {
        get {
            guard let rowPresentation, let blockIndex else { return localShowsAllLines }
            return rowPresentation.codeIsExpanded(blockIndex, isStreaming: presentation.isStreaming)
        }
        nonmutating set {
            if let rowPresentation, let blockIndex {
                rowPresentation.setCodeExpanded(blockIndex, expanded: newValue, isStreaming: presentation.isStreaming)
            } else {
                localShowsAllLines = newValue
            }
        }
    }
    @Environment(AppThemeStore.self) private var themeStore
    @State private var copyFeedback = CodeCopyFeedback()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let language {
                    Text(language.lowercased())
                        .scaledFont(.caption2)
                        .fontWeight(.medium)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
                        .textCase(.lowercase)
                }

                Spacer()

                Button {
                    HapticService.shared.copy(code)
                    copyFeedback.show()
                } label: {
                    Image(systemName: copyFeedback.isVisible ? "checkmark" : "doc.on.doc")
                        .scaledFont(TypeMetrics.symbol(13, weight: .medium))
                        .scaledFrame(width: ControlMetrics.minimumTarget, height: ControlMetrics.minimumTarget)
                        .foregroundStyle(copyFeedback.isVisible ? themeStore.theme.colors.accentTint : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .codeCopyButtonStyle()
                .accessibilityLabel(copyFeedback.isVisible ? "Code copied" : "Copy code")
                .animation(.smooth(duration: 0.2), value: copyFeedback.isVisible)
                .task(id: copyFeedback.generation) {
                    let generation = copyFeedback.generation
                    guard generation > 0 else { return }
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    copyFeedback.hide(ifGeneration: generation)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .codeBlockDragSource(code)

            Divider()
                .opacity(0.3)

            ViewThatFits(in: .horizontal) {
                codeText.frame(maxWidth: .infinity, alignment: .leading)
                codeText.transcriptHorizontalScroll()
            }
            if presentation.showsStreamingTail || presentation.isCollapsible {
                Button(footerTitle) {
                    showsAllLines.toggle()
                }
                .disabled(presentation.isStreaming)
                .appButtonFeedback()
                .scaledFont(.caption)
                .padding(12)
            }
        }
        .transcriptContentCard()
        .codeBlockActions(code: code, language: language)
        .onChange(of: presentation.isStreaming, initial: true) { _, isStreaming in
            if let rowPresentation, let blockIndex {
                rowPresentation.synchronizeCode(blockIndex, isStreaming: isStreaming)
            } else {
                localShowsAllLines = false
            }
        }
    }

    private var isFolded: Bool { !presentation.isStreaming && presentation.isCollapsible && !showsAllLines }

    private var footerTitle: String {
        if presentation.isStreaming {
            return "↑ \(presentation.lineCount - RenderedCodePresentation.previewLineCount) earlier lines"
        }
        return showsAllLines ? "Show fewer lines" : "Show all \(presentation.lineCount) lines"
    }

    private var codeText: some View {
        Text(isFolded ? presentation.preview : presentation.content)
            .scaledFont(TypeMetrics.code)
            .lineLimit(isFolded || presentation.showsStreamingTail ? RenderedCodePresentation.previewLineCount : presentation.lineCount,
                       reservesSpace: isFolded || presentation.showsStreamingTail)
            .transcriptTextSelection()
            .fixedSize(horizontal: true, vertical: false)
            .padding(12)
    }
}

struct TranscriptContentCard: ViewModifier {
    static let cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        content.themedSurface(cornerRadius: Self.cornerRadius)
    }
}

extension View {
    func transcriptContentCard() -> some View { modifier(TranscriptContentCard()) }
}
