import OSLog
import SwiftUI

/// The scroll view mounts with its first content so the initial bottom anchor
/// applies to messages rather than an empty placeholder.
/// The bounded layout stays eager: lazy height estimates previously stranded
/// bottom-anchored transcripts in blank space beyond tall Markdown rows.
struct ChatTranscriptView<QuestionContent: View, BottomBar: View>: View {
    private let isEmpty: Bool
    private let onBackgroundTap: () -> Void
    private let content: () -> TranscriptContentView<QuestionContent, BottomBar>

    init(items: [ChatStreamItem], readingPosition: TranscriptReadingPosition, rowPresentations: TranscriptRowPresentations, readingScope: UUID, retainedSurfaces: TranscriptSurfaceRetention.Scope?, renderedMessages: RenderedMessageStore,
         forkableMessageIDs: Set<UUID>, scrollToRow: TranscriptRowRequest?, onFork: @escaping (ChatMessage) -> Void,
         queuedActions: QueuedMessageActions, onToggleTimeline: @escaping (String) -> Void,
         questionCard: @escaping (QuestionPrompt) -> QuestionContent, onRefreshCompaction: (() -> Void)? = nil,
         onBackgroundTap: @escaping () -> Void, historyEdgeStatus: [HistoryEdge.Kind: HistoryEdge.Status],
         canPrefetchOlderHistory: Bool, canLoadHistory: Bool,
         onLoadHistory: @escaping @MainActor (HistoryEdge.Kind) -> Task<Void, Never>?,
         onShowLatest: @escaping @MainActor () -> Void, onFirstContent: @escaping () -> Void, bottomBar: BottomBar?) {
        isEmpty = items.isEmpty
        self.onBackgroundTap = onBackgroundTap
        content = {
            TranscriptContentView(items: items, readingPosition: readingPosition, rowPresentations: rowPresentations,
                readingScope: readingScope, retainedSurfaces: retainedSurfaces, renderedMessages: renderedMessages,
                forkableMessageIDs: forkableMessageIDs, scrollToRow: scrollToRow, onFork: onFork,
                queuedActions: queuedActions, onToggleTimeline: onToggleTimeline, questionCard: questionCard,
                onRefreshCompaction: onRefreshCompaction, onBackgroundTap: onBackgroundTap,
                historyEdgeStatus: historyEdgeStatus, canPrefetchOlderHistory: canPrefetchOlderHistory,
                canLoadHistory: canLoadHistory, onLoadHistory: onLoadHistory, onShowLatest: onShowLatest, onFirstContent: onFirstContent,
                bottomBar: bottomBar)
        }
    }

    var body: some View {
        ZStack {
            #if os(iOS)
            TranscriptColumnWidthReporter()
            #endif
            if isEmpty {
                Color.clear.contentShape(Rectangle())
                    #if os(iOS)
                    .onTapGesture(perform: onBackgroundTap)
                    #endif
            } else {
                content()
            }
        }
        .animation(.smooth(duration: 0.2), value: isEmpty)
    }
}

private struct TranscriptColumn: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scaledFrame(maxWidth: ReadableContentWidth.transcript, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
    }
}

#if os(iOS)
private struct TranscriptColumnWidthReporter: View {
    @Environment(\.htmlVisualSource) private var htmlVisualSource
    @State private var width: Int?

    var body: some View {
        Color.clear
            .frame(height: 0)
            .onGeometryChange(for: Int.self, of: { Int($0.size.width.rounded()) }) { _, width in
                self.width = width
                report()
            }
            .onChange(of: htmlVisualSource.map { ObjectIdentifier($0.preparation) }) { report() }
            .modifier(TranscriptColumn())
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func report() {
        guard let width else { return }
        htmlVisualSource?.preparation.updateLayoutContext { $0.width = width }
    }
}
#endif

private struct TranscriptContentView<QuestionContent: View, BottomBar: View>: View {
    let items: [ChatStreamItem]
    let readingPosition: TranscriptReadingPosition
    let rowPresentations: TranscriptRowPresentations
    let readingScope: UUID
    let retainedSurfaces: TranscriptSurfaceRetention.Scope?
    /// Pre-parsed presentation per message id; bubbles never parse.
    let renderedMessages: RenderedMessageStore
    let forkableMessageIDs: Set<UUID>
    /// A one-shot send/question request; each request owns its anchor and token.
    let scrollToRow: TranscriptRowRequest?
    let onFork: (ChatMessage) -> Void
    let queuedActions: QueuedMessageActions
    let onToggleTimeline: (String) -> Void
    let questionCard: (QuestionPrompt) -> QuestionContent
    var onRefreshCompaction: (() -> Void)? = nil
    let onBackgroundTap: () -> Void
    let historyEdgeStatus: [HistoryEdge.Kind: HistoryEdge.Status]
    let canPrefetchOlderHistory: Bool
    let canLoadHistory: Bool
    let onLoadHistory: @MainActor (HistoryEdge.Kind) -> Task<Void, Never>?
    let onShowLatest: @MainActor () -> Void
    let onFirstContent: () -> Void
    @State private var visibleHeight: CGFloat = 0
    @State private var bottomBarHeight: CGFloat = 0
    let bottomBar: BottomBar?

    #if os(macOS)
    @State private var nativePresentation: TranscriptNativePresentation
    private var follow: TranscriptFollow { nativePresentation.follow }
    private var visibility: TranscriptVisibility { nativePresentation.visibility }
    private var native: TranscriptNativeEndpoint { nativePresentation.endpoint }
    private var scrollHalt: TranscriptScrollHalt { nativePresentation.halt }
    private var rowProjection: TranscriptRowProjection { nativePresentation.rowProjection }
    #else
    @State private var follow: TranscriptFollow
    @State private var visibility = TranscriptVisibility()
    @State private var scrollHalt = TranscriptScrollHalt()
    @State private var rowProjection = TranscriptRowProjection()
    #endif
    #if os(iOS)
    @State private var mounting: TranscriptMounting
    @State private var batchFloorRowID: String?
    @State private var scrollPhase = TranscriptScrollPhase()
    #endif
    @Environment(\.htmlVisualSource) private var htmlVisualSource
    @State private var isNearTop = false
    @State private var isRunwayShort = false
    @State private var appliedRowRequest: Int?
    #if os(iOS)
    @State private var position: TranscriptPosition
    #endif
    @State private var historyRead: TranscriptHistoryRead?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.visualsVisible) private var visualsVisible
    #if os(iOS)
    @Environment(\.appEnergyPolicy) private var energyPolicy
    #endif
    #if os(iOS)
    @State private var selectingMessage: TranscriptTextSelection?
    #endif
    @State private var openingAttachment: MessageAttachment?

    init(items: [ChatStreamItem], readingPosition: TranscriptReadingPosition, rowPresentations: TranscriptRowPresentations, readingScope: UUID, retainedSurfaces: TranscriptSurfaceRetention.Scope?, renderedMessages: RenderedMessageStore,
         forkableMessageIDs: Set<UUID>, scrollToRow: TranscriptRowRequest?, onFork: @escaping (ChatMessage) -> Void,
         queuedActions: QueuedMessageActions, onToggleTimeline: @escaping (String) -> Void,
         questionCard: @escaping (QuestionPrompt) -> QuestionContent, onRefreshCompaction: (() -> Void)? = nil,
         onBackgroundTap: @escaping () -> Void, historyEdgeStatus: [HistoryEdge.Kind: HistoryEdge.Status],
         canPrefetchOlderHistory: Bool, canLoadHistory: Bool,
         onLoadHistory: @escaping @MainActor (HistoryEdge.Kind) -> Task<Void, Never>?,
         onShowLatest: @escaping @MainActor () -> Void, onFirstContent: @escaping () -> Void, bottomBar: BottomBar?) {
        self.items = items
        self.readingPosition = readingPosition
        self.rowPresentations = rowPresentations
        self.readingScope = readingScope
        self.retainedSurfaces = retainedSurfaces
        self.renderedMessages = renderedMessages
        self.forkableMessageIDs = forkableMessageIDs
        self.scrollToRow = scrollToRow
        self.onFork = onFork
        self.queuedActions = queuedActions
        self.onToggleTimeline = onToggleTimeline
        self.questionCard = questionCard
        self.onRefreshCompaction = onRefreshCompaction
        self.onBackgroundTap = onBackgroundTap
        self.historyEdgeStatus = historyEdgeStatus
        self.canPrefetchOlderHistory = canPrefetchOlderHistory
        self.canLoadHistory = canLoadHistory
        self.onLoadHistory = onLoadHistory
        self.onShowLatest = onShowLatest
        self.onFirstContent = onFirstContent
        self.bottomBar = bottomBar
        #if os(macOS)
        let saved = retainedSurfaces?.surface(for: readingPosition) as? AppKitTranscriptContainer
        saved?.presentation.restoreFollowing(readingPosition.isFollowingLatest)
        _nativePresentation = State(initialValue: saved?.presentation ?? TranscriptNativePresentation(readingPosition: readingPosition))
        #else
        _follow = State(initialValue: TranscriptFollow(isFollowingLatest: readingPosition.isFollowingLatest))
        #endif
        #if os(iOS)
        _position = State(initialValue: TranscriptPosition(anchor: readingPosition.anchor))
        _mounting = State(initialValue: TranscriptMounting(startRowID: readingPosition.mountedStartRowID ?? readingPosition.anchor?.rowID))
        #endif
    }

    #if os(iOS)
    private var reveal: TranscriptReveal {
        get { mounting.value }
        nonmutating set { mounting.value = newValue }
    }
    #endif

    var body: some View {
        let _ = PerfBuild.count("transcriptBody")
        ZStack {
            #if os(macOS)
            TranscriptViewport() { TranscriptPolicyContent { transcript } }
                .transition(.opacity)
            #else
            transcript
                .transition(.opacity)
            #endif
        }
        .sheet(item: $openingAttachment) { attachment in
            MessageAttachmentViewer(attachment: attachment)
        }
        #if os(macOS)
        .transcriptCodeExportPresentation(presenter: nativePresentation.codeExport)
        #endif
        #if os(iOS)
        .sheet(item: $selectingMessage) { selection in
            NavigationStack {
                ScrollView {
                    Text(selection.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("Select Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", role: .close) { selectingMessage = nil }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        #endif
    }

    private var transcript: some View {
        let reservedBottom = bottomBar == nil ? 0 : bottomBarHeight
        let allRows = rowProjection.rows(for: items)
        #if os(macOS)
        #if RC_PERF_HARNESS
        let rows = PerfBuild.mountCap.map { Array(allRows.suffix($0)) } ?? allRows
        #else
        let rows = allRows
        #endif
        #else
        let start = mountedStart(of: allRows)
        #if RC_PERF_HARNESS
        let rows = PerfBuild.mountCap.map { Array(mountedRows(from: start, of: allRows).suffix($0)) } ?? mountedRows(from: start, of: allRows)
        #else
        let rows = mountedRows(from: start, of: allRows)
        #endif
        #endif
        let readyRowRequest = scrollToRow.flatMap { request in
            visibleHeight > 0 && request.token != appliedRowRequest && rows.contains { $0.id == request.rowID }
                ? request.token : nil
        }
        return transcriptSurface(rows, reservedBottom: reservedBottom)
            #if os(iOS)
            .modifier(TranscriptRevealTask(reveal: reveal, isRunwayShort: isRunwayShort, hasEarlierRows: start > 0,
                                           isLoadingOlder: isLoadingOlder, phase: scrollPhase, action: revealEarlierRows))
            #endif
            .onChange(of: rows.map(\.id), initial: true) { _, ids in
                visibility.retainRows(Set(ids))
            }
            #if os(iOS)
            .onChange(of: rowPresentations.sourceIdentity, initial: true) { visibility.sourceMembershipChanged() }
            .task(id: scrollToRow?.token) { await revealRequestedRow() }
            #endif
            .onChange(of: readyRowRequest, initial: true) { _, token in
                if token != nil { applyRowRequest() }
            }
            #if os(iOS)
            .onChange(of: TranscriptRow.exceedsFollowingBudget(rows)) { _, exceeds in
                if exceeds { trimToLatest() }
            }
            .onChange(of: allRows.first(where: \.isMessage)?.id) { _, firstMessageID in
                if case .complete(firstMessageID: nil) = reveal { reveal = .complete(firstMessageID: firstMessageID) }
            }
            #endif
            .task(id: historyRead?.id) {
                guard let read = historyRead else { return }
                await read.task.value
                guard !Task.isCancelled, historyRead?.id == read.id else { return }
                historyRead?.isLoaded = true
            }
            .onChange(of: historyRead?.isLoaded == true) { _, loaded in
                if loaded { settleHistoryRead() }
            }
            .onChange(of: historyEdgeStatus) { demandHistory() }
            .onChange(of: isRunwayShort) { demandHistory() }
            .onChange(of: canLoadHistory) { _, canLoad in
                if canLoad { demandHistory() }
            }
            #if os(iOS)
            .onChange(of: start) {
                updateRunway(rows)
                demandHistory()
            }
            #endif
            .overlay(alignment: .bottom) { transcriptBottomBar }
            .overlay(alignment: .bottomTrailing) {
                ScrollToBottomButton(visibility: visibility, action: scrollToBottom)
            }
            #if os(macOS)
            .onDisappear { native.suspend() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { native.suspend() } else { native.resume() }
            }
            .onChange(of: visualsVisible) { _, visible in
                if !visible { native.suspend() } else { native.resume() }
            }
            #endif
    }

    @ViewBuilder
    private func transcriptSurface(_ rows: [TranscriptRow], reservedBottom: CGFloat) -> some View {
        #if os(macOS)
        let actions = nativePresentation.actions
        let _ = actions.bind(openAttachment: { [selection = $openingAttachment] in selection.wrappedValue = $0 },
            loadHistory: { edge in
                follow.readHistory()
                loadHistory(edge)
            },
            toggleTimeline: { [read = $historyRead, follow, native, onToggleTimeline] jobID, rowID in
                read.wrappedValue = nil
                follow.revealRow()
                native.scrollTo(id: rowID, anchor: nil, animated: false, completion: {})
                onToggleTimeline(jobID)
            }, onFork: onFork, queuedActions: queuedActions, refreshCompaction: onRefreshCompaction)
        AppKitTranscriptScrollView(presentation: nativePresentation, retention: retainedSurfaces, readingPosition: readingPosition, rowPresentations: rowPresentations, readingScope: readingScope,
            rows: rows.map(rowInputs), renderedMessages: renderedMessages, reservedBottom: reservedBottom,
            isFollowingLatest: { follow.isFollowingLatest },
            onEvent: nativeEvent,
            onNavigate: { navigation in
                historyRead = nil
                if navigation == .end {
                    follow.followLatest()
                    onShowLatest()
                } else {
                    follow.readHistory()
                }
            }) { inputs in
                nativeRow(inputs.row)
            }
        #else
        ScrollView {
            transcriptRows(rows, reservedBottom: reservedBottom,
                           layout: TranscriptLayout(minimumTurnHeight: visibleHeight - reservedBottom,
                                                    latestTurnIndex: rows.lastIndex(where: \.startsTurn)))
                .modifier(TranscriptTailAnimation(follow: follow, animatesDecorations: animatesDecorations, latestRowID: rows.last?.id))
                .animation(animatesDecorations ? .smooth(duration: 0.3) : nil, value: expandedTimelineIDs)
                .transcriptPerfFeature("scrollTargets") { $0.scrollTargetLayout() }
                .background(alignment: .top) {
                    TranscriptScrollHaltAnchor(halt: scrollHalt)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
                .modifier(TranscriptColumn())
                .padding(.top, 12)
                .coordinateSpace(name: TranscriptAnchor.content)
        }
        .transcriptPerfFeature("scrollPosition") { $0.modifier(TranscriptPositionBinding(position: position)) }
        .transcriptPerfFeature("visibility") { view in
            view.onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { ids in
                let visible = Set(ids).subtracting([TranscriptAnchor.bottom])
                guard visible != visibility.visibleRowIDs else { return }
                visibleRowsChanged(rows.filter { visible.contains($0.id) })
                updateRunway(rows)
            }
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .modifier(TranscriptSizeChangeAnchor(follow: follow))
        .defaultScrollAnchor(.topLeading, for: .alignment)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .transcriptPerfFeature("geometryProjections") { view in
            view
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.containerSize.height }) { _, height in
                    visibleHeight = height
                }
                .onScrollGeometryChange(for: Bool.self, of: { geometry in
                    geometry.visibleRect.minY < geometry.containerSize.height * 2
                }) { _, nearTop in
                    isNearTop = nearTop
                    updateRunway(rows)
                }
                .onScrollGeometryChange(for: TranscriptViewportState.self, of: { geometry in
                    TranscriptViewportState(viewport: geometry.viewport,
                                            readingBottom: geometry.visibleRect.maxY - geometry.contentInsets.bottom,
                                            readingHeight: geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom)
                }) { _, state in
                    visibility.updateViewport(state.viewport)
                    visibility.setReadingEdge(bottom: state.readingBottom, height: state.readingHeight)
                }
                .onScrollGeometryChange(for: Bool.self, of: { $0.distanceToBottom <= 1 }) { _, atBottom in
                    if !position.isRestoring { follow.userScrollMoved(atBottom: atBottom) }
                }
        }
        .scrollDismissesKeyboard(.interactively)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { onBackgroundTap() }, including: .all)
        .onAppear {
            visibility.attachReadingPosition(readingPosition, source: rowPresentations, scope: readingScope, follow: follow, mounting: mounting)
            visibility.bindScrollPosition(position)
        }
        .onChange(of: ObjectIdentifier(readingPosition)) {
            visibility.attachReadingPosition(readingPosition, source: rowPresentations, scope: readingScope, follow: follow, mounting: mounting)
        }
        .onDisappear {
            visibility.detachReadingPosition()
            visibility.setScrollPhase(.idle)
        }
        .onScrollPhaseChange { _, phase, context in
            phaseChanged(phase, atBottom: context.geometry.distanceToBottom <= 1)
        }
        #endif
    }

    #if os(macOS)
    private func nativeRow(_ row: TranscriptRow) -> some View {
        PerfBuild.count("transcriptRowBody")
        let content = rowView(row)
        return TranscriptRowLayout { content }
            .environment(\.transcriptRowVisibility, TranscriptRowVisibility(rowID: row.id, visibility: visibility))
            #if RC_PERF_HARNESS
            .accessibilityHidden(PerfBuild.isDisabled("accessibility"))
            #endif
    }
    #endif

    #if os(macOS)
    private func nativeEvent(_ event: TranscriptNativeEvent) {
        switch event {
        case .geometry(let geometry):
            PerfBuild.count("transcriptGeometryActions")
            if visibleHeight != geometry.height { visibleHeight = geometry.height }
            if let width = geometry.columnWidth { htmlVisualSource?.preparation.updateLayoutContext { $0.width = width } }
            if isNearTop != geometry.isNearTop { isNearTop = geometry.isNearTop }
            if let runwayIsShort = geometry.isRunwayShort {
                let isShort = geometry.isNearTop || runwayIsShort
                if isRunwayShort != isShort {
                    PerfBuild.count("updateRunway")
                    isRunwayShort = isShort
                }
            }
            if let isFar = geometry.isFarFromLatest { visibility.setFarFromLatest(isFar) }
        case .visibility(let ids):
            let previous = visibility.visibleRowIDs
            guard ids != previous else { return }
            PerfBuild.count("visibleRowsChanged")
            let appeared = ids.subtracting(previous)
            visibility.setVisibleRowIDs(ids)
            if appeared.contains(where: { rowProjection.row(for: $0)?.isMessage == true }) { onFirstContent() }
            if ids.symmetricDifference(previous).contains(where: { rowProjection.row(for: $0)?.isHistoryEdge == true }) {
                demandHistory()
            }
            demandNearVisuals()
        case .phase(let phase, let atBottom):
            phaseChanged(phase, atBottom: atBottom)
        case .userMoved(let atBottom):
            follow.userScrollMoved(atBottom: atBottom)
        case .userCancelled:
            follow.cancelUserScroll()
        }
    }
    #endif

    private func phaseChanged(_ phase: ScrollPhase, atBottom: Bool) {
        PerfBuild.count("phase.\(phase)")
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-html-visual-fixture") {
            AppLogger(category: "HTMLVisual").notice("html visual fixture scroll phase=\(String(describing: phase)) uptime=\(ProcessInfo.processInfo.systemUptime)")
            #if os(iOS)
            AppPerformanceDiagnostics.pointsOfInterest.emitEvent("HTMLVisualFixtureScroll",
                "phase=\(String(describing: phase), privacy: .public) uptime=\(ProcessInfo.processInfo.systemUptime, privacy: .public) lowPower=\(energyPolicy.isLowPowerModeEnabled, privacy: .public) thermal=\(energyPolicy.thermalState.rawValue, privacy: .public)")
            #else
            AppPerformanceDiagnostics.pointsOfInterest.emitEvent("HTMLVisualFixtureScroll",
                "phase=\(String(describing: phase), privacy: .public) uptime=\(ProcessInfo.processInfo.systemUptime, privacy: .public)")
            #endif
        }
        #endif
        #if os(iOS)
        scrollPhase.changed(to: phase)
        htmlVisualSource?.preparation.setInteracting(phase != .idle)
        #endif
        visibility.setScrollPhase(phase)
        switch phase {
        case .tracking, .interacting:
            #if os(iOS)
            position.cancelRestoration()
            #endif
            if historyRead != nil { historyRead = nil }
            follow.beginUserScroll()
            #if os(iOS)
            follow.userScrollMoved(atBottom: atBottom)
            #endif
        #if os(macOS)
        case .decelerating:
            follow.beginUserScroll()
        #endif
        case .idle:
            #if os(iOS)
            position.finishRestoration()
            #endif
            if follow.endUserScroll(atBottom: atBottom, of: items) {
                #if os(macOS)
                native.latest(animated: false)
                #else
                position.scrollTo(id: TranscriptAnchor.bottom, anchor: .bottom)
                #endif
            }
            #if os(iOS)
            if var read = historyRead, read.target == nil, !follow.isFollowingLatest {
                read.target = readingTarget()
                historyRead = read
            }
            trimToLatest()
            trimReadingRunway()
            saveReadingPosition()
            #endif
        default: break
        }
    }

    #if os(iOS)
    private func saveReadingPosition() {
        visibility.captureReadingPosition()
    }

    private func transcriptRows(_ rows: [TranscriptRow], reservedBottom: CGFloat, layout: TranscriptLayout) -> some View {
        let latestRowID = rows.last?.id
        return layout {
            ForEach(rows) { row in
                TranscriptRowContent(inputs: rowInputs(row), presentations: rowPresentations) { mountedRow(row) }
                    .equatable()
                    .background {
                        if row.id == latestRowID { TranscriptLatestEdge(visibility: visibility) }
                    }
                    .transition(.opacity)
                    .environment(\.transcriptRowVisibility, TranscriptRowVisibility(rowID: row.id, visibility: visibility))
            }
            Color.clear
                .frame(height: 20 + reservedBottom)
                .id(TranscriptAnchor.bottom)
        }
    }
    #endif

    private var transcriptBottomBar: some View {
        ZStack {
            if let bottomBar {
                bottomBar
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { _, height in
                        bottomBarHeight = height
                    }
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(.smooth, value: bottomBar != nil)
    }

    #if os(iOS)
    private var animatesDecorations: Bool {
        energyPolicy.animatesDecorations(sceneActive: scenePhase == .active, visible: visualsVisible, reduceMotion: reduceMotion)
    }

    private var expandedTimelineIDs: Set<String> {
        Set(items.compactMap { if case .timeline(let timeline) = $0, timeline.isExpanded { timeline.id } else { nil } })
    }

    private func mountedStart(of rows: [TranscriptRow]) -> Int {
        switch reveal {
        case .opening: TranscriptRow.openingStart(of: rows)
        case .opened(let rowID), .revealing(let rowID): rows.lastIndex { $0.id == rowID } ?? 0
        case .complete(let firstMessageID): TranscriptRow.completeStart(firstMessageID: firstMessageID, in: rows)
        }
    }

    private func mountedRows(from start: Int, of rows: [TranscriptRow]) -> [TranscriptRow] {
        guard start > 0, case .complete = reveal else { return Array(rows[start...]) }
        return [.content(.historyEdge(HistoryEdge(kind: .older, cursor: nil)))] + rows[start...]
    }

    private func revealEarlierRows() async {
        let delay: Duration
        switch reveal {
        case .opening:
            let rows = rowProjection.rows(for: items)
            let start = TranscriptRow.openingStart(of: rows)
            reveal = start == 0 ? .complete(firstMessageID: rows.first(where: \.isMessage)?.id) : .opened(rows[start].id)
            return
        case .opened:
            delay = .milliseconds(350)
        case .revealing, .complete:
            delay = .milliseconds(16)
        }
        guard isRunwayShort || batchFloorRowID != nil, scrollPhase.canReveal else { return }
        do { try await Task.sleep(for: delay) } catch { return }
        var htmlWaited = false
        while !Task.isCancelled {
            guard scrollPhase.canReveal else { return }
            let rows = rowProjection.rows(for: items)
            let end = mountedStart(of: rows)
            let floor = max(batchFloor(before: end, in: rows), follow.isFollowingLatest ? TranscriptRow.followingStart(of: rows) : 0)
            guard floor < end, batchFloorRowID != nil || batchIsReady(before: end, in: rows) else {
                batchFloorRowID = nil
                return
            }
            let batch = rows[floor..<end].compactMap(\.message)
            if renderedMessages.hasRendered(batch) {
                guard isRunwayShort || batchFloorRowID != nil, scrollPhase.canReveal else { return }
                let start = max(TranscriptRow.sliceStart(before: end, in: rows), floor)
                if let html = htmlVisualSource, !htmlWaited {
                    let slice = renderedMessages.htmlVisualReferences(in: rows[start..<end].reversed())
                    html.preparation.warm(renderedMessages.htmlVisualReferences(in: rows[floor..<end].reversed()), documents: html.documents)
                    if await html.preparation.awaitMeasured(slice, documents: html.documents,
                                                            atMost: TranscriptReadingRestoration.renderReadinessTimeout) {
                        htmlWaited = true
                        continue
                    }
                }
                batchFloorRowID = start > floor ? rows[floor].id : nil
                if follow.isFollowingLatest {
                    revealRows(from: start, of: rows, restoring: nil)
                } else if let target = readingTarget() {
                    revealRows(from: start, of: rows, restoring: target)
                } else {
                    batchFloorRowID = nil
                }
                return
            }
            await renderedMessages.prepareMounting(batch)
        }
    }

    private func batchFloor(before end: Int, in rows: [TranscriptRow]) -> Int {
        if let batchFloorRowID, let floor = rows.lastIndex(where: { $0.id == batchFloorRowID }), floor < end { return floor }
        return TranscriptRow.batchStart(before: end, in: rows)
    }

    private var isLoadingOlder: Bool {
        historyRead?.edge.kind == .older || historyEdgeStatus[.older] == .loading
    }

    private func batchIsReady(before end: Int, in rows: [TranscriptRow]) -> Bool {
        !isLoadingOlder || !TranscriptRow.backlogIsShort(before: end, in: rows) || (isNearTop && !follow.isFollowingLatest)
    }

    private func updateRunway(_ rows: [TranscriptRow]) {
        let span = PerfBuild.span("chat.runway"); defer { span.end() }
        PerfBuild.count("updateRunway")
        let isShort = isNearTop || TranscriptRow.runwayIsShort(above: visibility.visibleRowIDs, in: rows) == true
        if isRunwayShort != isShort { isRunwayShort = isShort }
    }

    private func visibleRowsChanged(_ visibleRows: [TranscriptRow]) {
        let span = PerfBuild.span("chat.visibility"); defer { span.end() }
        PerfBuild.count("visibleRowsChanged")
        let appeared = visibleRows.filter { !visibility.visibleRowIDs.contains($0.id) }
        visibility.setVisibleRowIDs(Set(visibleRows.map(\.id)))
        if appeared.contains(where: \.isMessage) { onFirstContent() }
        demandHistory()
        demandNearVisuals()
    }
    #endif

    private func demandNearVisuals() {
        guard let html = htmlVisualSource else { return }
        let rows = rowProjection.rows(for: items)
        guard let first = rows.firstIndex(where: { visibility.visibleRowIDs.contains($0.id) }),
              let last = rows.lastIndex(where: { visibility.visibleRowIDs.contains($0.id) }) else { return }
        let outward = (1...TranscriptRow.nearVisualRows).flatMap { [first - $0, last + $0] }.filter { rows.indices.contains($0) }
        let near = (Array(first...last) + outward).map { rows[$0] }
        html.preparation.updateNear(renderedMessages.htmlVisualReferences(in: near), documents: html.documents)
    }

    private func demandHistory() {
        let span = PerfBuild.span("chat.history"); defer { span.end() }
        PerfBuild.count("demandHistory")
        let rows = rowProjection.rows(for: items)
        #if os(iOS)
        let start = mountedStart(of: rows)
        #endif
        for row in rows {
            guard case .content(.historyEdge(let edge)) = row.kind, visibility.visibleRowIDs.contains(row.id) else { continue }
            #if os(iOS)
            if edge.kind == .older, start > 0 { continue }
            #endif
            requestHistory(edge)
        }
        guard !follow.isFollowingLatest, isRunwayShort, canPrefetchOlderHistory,
              case .content(.historyEdge(let edge)) = rows.first?.kind, edge.kind == .older else { return }
        #if os(iOS)
        guard TranscriptRow.backlogIsShort(before: start, in: rows) else { return }
        #endif
        requestHistory(edge)
    }

    private func requestHistory(_ edge: HistoryEdge) {
        guard historyRead == nil, historyEdgeStatus[edge.kind] == nil else { return }
        loadHistory(edge)
    }

    private func settleHistoryRead() {
        guard historyRead != nil else { return }
        #if os(iOS)
        let target = follow.isUserScrolling ? nil : historyRead?.target
        #endif
        historyRead = nil
        #if os(iOS)
        if let target { position.scrollTo(id: target.rowID, anchor: target.anchor) }
        #endif
        demandHistory()
        #if os(iOS)
        if let target, historyRead != nil { historyRead?.target = target }
        #endif
    }

    #if os(iOS)
    private func trimToLatest() {
        PerfBuild.count("trimToLatest")
        guard follow.isFollowingLatest, !follow.isUserScrolling else { return }
        let rows = rowProjection.rows(for: items)
        let start = mountedStart(of: rows)
        guard TranscriptRow.exceedsFollowingBudget(rows[start...]) else { return }
        let latest = TranscriptRow.followingStart(of: rows)
        guard latest > start else { return }
        reveal = .opened(rows[latest].id)
    }

    private func trimReadingRunway() {
        guard !follow.isFollowingLatest, historyRead == nil, !position.isRestoring else { return }
        let rows = rowProjection.rows(for: items)
        let start = mountedStart(of: rows)
        guard let firstVisible = rows.firstIndex(where: { visibility.visibleRowIDs.contains($0.id) }),
              firstVisible > start, TranscriptRow.exceedsFollowingBudget(rows[start..<firstVisible]),
              let target = readingTarget() else { return }
        let retainedStart = TranscriptRow.batchStart(before: firstVisible, in: rows)
        guard retainedStart > start, visibility.canTrimReadingPrefix(rows[retainedStart..<firstVisible]) else { return }
        batchFloorRowID = nil
        revealRows(from: retainedStart, of: rows, restoring: target)
    }

    private func revealRequestedRow() async {
        guard let request = scrollToRow else { return }
        var rows = rowProjection.rows(for: items)
        guard let index = rows.firstIndex(where: { $0.id == request.rowID }),
              index < mountedStart(of: rows) else { return }
        if let html = htmlVisualSource {
            let revealed = renderedMessages.htmlVisualReferences(in: rows[index..<mountedStart(of: rows)])
            if await html.preparation.awaitPresentable(revealed, documents: html.documents,
                                                       atMost: TranscriptReadingRestoration.renderReadinessTimeout) {
                guard !Task.isCancelled, scrollToRow?.token == request.token else { return }
                rows = rowProjection.rows(for: items)
            }
        }
        guard let index = rows.firstIndex(where: { $0.id == request.rowID }),
              index < mountedStart(of: rows) else { return }
        revealRows(from: index, of: rows, restoring: follow.isFollowingLatest ? nil : readingTarget())
    }

    private func revealRows(from start: Int, of rows: [TranscriptRow], restoring target: TranscriptReadingTarget?) {
        let span = PerfBuild.span("chat.reveal"); defer { span.end() }
        PerfBuild.count("revealRows")
        reveal = start == 0 ? .complete(firstMessageID: rows.first(where: \.isMessage)?.id) : .revealing(rows[start].id)
        if let target { position.scrollTo(id: target.rowID, anchor: target.anchor) }
    }

    #endif

    private func loadHistory(_ edge: HistoryEdge) {
        guard historyRead == nil, historyEdgeStatus[edge.kind] != .loading, let task = onLoadHistory(edge.kind) else { return }
        #if os(macOS)
        historyRead = TranscriptHistoryRead(edge: edge, task: task)
        #else
        let isResting = scrollPhase.value == .idle && !follow.isFollowingLatest
        historyRead = TranscriptHistoryRead(edge: edge, task: task, target: isResting ? readingTarget() : nil)
        #endif
    }

    #if os(iOS)
    private func readingTarget() -> TranscriptReadingTarget? { visibility.readingTarget() }
    #endif

    private func applyRowRequest() {
        guard let request = scrollToRow else { return }
        historyRead = nil
        follow.revealRow()
        #if os(macOS)
        native.scrollTo(id: request.rowID, anchor: request.anchor,
                        animated: request.motion == .animated && !reduceMotion) {
            appliedRowRequest = request.token
        }
        #else
        appliedRowRequest = request.token
        let animates = request.motion == .animated && !reduceMotion
        var transaction = Transaction(animation: animates ? .smooth(duration: 0.5) : nil)
        transaction.disablesAnimations = !animates
        withTransaction(transaction) {
            position.scrollTo(id: request.rowID, anchor: request.anchor)
        }
        #endif
    }

    private func scrollToBottom() {
        scrollHalt.stop()
        historyRead = nil
        follow.followLatest()
        onShowLatest()
        #if os(macOS)
        native.latest(animated: !reduceMotion)
        #else
        withAnimation(reduceMotion ? nil : .smooth) {
            position.scrollTo(id: TranscriptAnchor.bottom, anchor: .bottom)
        }
        #endif
    }

    private func rowInputs(_ row: TranscriptRow) -> TranscriptRowInputs {
        switch row.kind {
        case .content(.message(let message)):
            TranscriptRowInputs(row: row, isForkable: forkableMessageIDs.contains(message.id), edgeStatus: nil,
                                canSendQueuedMessage: message.delivery == .queued && queuedActions.sendNow != nil)
        case .content(.historyEdge(let edge)):
            TranscriptRowInputs(row: row, isForkable: false, edgeStatus: historyEdgeStatus[edge.kind], canSendQueuedMessage: false)
        default:
            TranscriptRowInputs(row: row, isForkable: false, edgeStatus: nil, canSendQueuedMessage: false)
        }
    }

    #if os(iOS)
    @ViewBuilder
    private func mountedRow(_ row: TranscriptRow) -> some View {
        if row.isReadingTarget {
            rowView(row).transcriptPerfFeature("readingFrames") {
                $0.modifier(TranscriptReadingFrame(rowID: row.id,
                    renderedMessageID: row.message.flatMap { $0.inlineContent == nil ? $0.id : nil },
                    renderedMessages: renderedMessages, visibility: visibility))
            }
        } else {
            rowView(row)
        }
    }
    #endif

    @ViewBuilder
    private func rowView(_ row: TranscriptRow) -> some View {
        switch row.kind {
        case .activity(let event, let isLast):
            TimelineEventRow(event: event, isLast: isLast)
                .accessibilityIdentifier(row.id)
        case .content(let item):
            contentRow(item)
        }
    }

    private func textSelectionAction(for message: ChatMessage) -> ((String) -> Void)? {
        #if os(iOS)
        return { [selection = $selectingMessage] text in
            selection.wrappedValue = TranscriptTextSelection(id: message.id, text: text)
        }
        #else
        return nil
        #endif
    }

    @ViewBuilder private func contentRow(_ item: ChatStreamItem) -> some View {
        switch item {
        case .historyEdge(let edge):
            #if os(macOS)
            let load: (HistoryEdge) -> Void = { [actions = nativePresentation.actions] in actions.loadHistory($0) }
            #else
            let load = { (edge: HistoryEdge) in
                follow.readHistory()
                loadHistory(edge)
            }
            #endif
            TranscriptHistoryEdgeRow(edge: edge, status: historyEdgeStatus[edge.kind]) {
                HapticService.shared.play(.buttonPress)
                load(edge)
            }
        case .message(let message):
            messageRow(message)
        case .question(let prompt):
            questionCard(prompt)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .timeline(let timeline):
            #if os(macOS)
            let toggle = { [actions = nativePresentation.actions] in
                actions.toggleTimeline(timeline.id, rowID: item.id)
            }
            #else
            let positionRow = { [position] in position.scrollTo(id: item.id, anchor: nil) }
            let toggle = { [read = $historyRead, follow, onToggleTimeline] in
                read.wrappedValue = nil
                follow.revealRow()
                positionRow()
                onToggleTimeline(timeline.id)
            }
            #endif
            AgentTimelineHeader(timeline: timeline, onToggle: toggle)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .turnOutcome(let outcome):
            TurnOutcomeRow(outcome: outcome)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .viewedMedia(let media):
            ViewedMediaRow(media: media)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .publishedVisual(let visual):
            HTMLVisualInline(url: visual.publication.reference.url, title: visual.publication.title)
                .environment(\.transcriptBlockIndex, 0)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .compaction(let marker):
            #if os(macOS)
            let refresh: (() -> Void)? = onRefreshCompaction == nil ? nil : { [actions = nativePresentation.actions] in
                actions.refreshCompaction()
            }
            #else
            let refresh = onRefreshCompaction
            #endif
            CompactionDivider(marker: marker, visibility: visibility, refresh: refresh)
        }
    }

    private func messageRow(_ message: ChatMessage) -> some View {
        #if os(macOS)
        let fork: (ChatMessage) -> Void = { [actions = nativePresentation.actions] in actions.fork($0) }
        let queued = nativePresentation.actions.queuedActions
        let attachment: (MessageAttachment) -> Void = { [actions = nativePresentation.actions] in actions.openAttachment($0) }
        #else
        let fork = onFork
        let queued = queuedActions
        let attachment: (MessageAttachment) -> Void = { [selection = $openingAttachment] in selection.wrappedValue = $0 }
        #endif
        return ChatBubble(
            message: message,
            renderedMessages: renderedMessages,
            visibility: visibility,
            onFork: forkableMessageIDs.contains(message.id) ? fork : nil,
            queuedActions: message.delivery == .queued ? queued : nil,
            onSelectText: textSelectionAction(for: message),
            onOpenAttachment: attachment
        )
        .frame(
            maxWidth: .infinity,
            alignment: message.role == .user ? .trailing : .leading
        )
    }

}

/// Identifies one scroll request; equal requests are ignored, so every request gets a new token.
struct TranscriptRowRequest: Equatable {
    let rowID: String
    let token: Int
    let anchor: UnitPoint
    let motion: Motion

    enum Motion: Equatable { case animated, instant }
}

private struct ScrollToBottomButton: View {
    let visibility: TranscriptVisibility
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if visibility.isFarFromLatest {
                Button {
                    HapticService.shared.play(.disclosure)
                    action()
                } label: {
                    Image(systemName: "arrow.down")
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(Color.appLabel)
                        .scaledFont(TypeMetrics.symbol(20, weight: .semibold))
                        .scaledFrame(width: ControlMetrics.minimumTarget, height: ControlMetrics.minimumTarget + 6)
                }
                .buttonStyle(.appGlassActionFeedback)
                .accessibilityLabel("Scroll to latest message")
                .transcriptPerfFeature("tooltips") { $0.tooltip("Scroll to latest message") }
                .accessibilityIdentifier("transcript-jump-to-latest")
                .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .padding(.trailing, 16)
        .padding(.bottom, 8)
        .animation(.smooth(duration: 0.25), value: visibility.isFarFromLatest)
    }
}

#if os(iOS)
private struct TranscriptLatestEdge: View {
    let visibility: TranscriptVisibility

    var body: some View {
        Color.clear
            .transcriptPerfFeature("latestEdge") { view in
                view.onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named(TranscriptAnchor.content)).maxY }) { _, end in
                    visibility.setLatestEnd(end)
                }
            }
    }
}


private struct TranscriptViewportState: Equatable {
    let viewport: CGRect
    let readingBottom: CGFloat
    let readingHeight: CGFloat
}

@MainActor
@Observable
private final class TranscriptScrollPhase {
    private(set) var value = ScrollPhase.idle

    func changed(to phase: ScrollPhase) {
        guard phase != value else { return }
        value = phase
    }

    var canReveal: Bool { value == .idle }

}
#endif

@MainActor
@Observable
final class TranscriptFollow {
    @ObservationIgnored private var state: TranscriptFollowState
    private(set) var isFollowingLatest: Bool

    init(isFollowingLatest: Bool) {
        var state = TranscriptFollowState()
        if !isFollowingLatest { state.readHistory() }
        self.state = state
        self.isFollowingLatest = state.isFollowingLatest
    }

    var isUserScrolling: Bool { state.isUserScrolling }

    func beginUserScroll() { state.beginUserScroll() }
    func cancelUserScroll() {
        if isFollowingLatest { followLatest() } else { revealRow() }
    }
    func userScrollMoved(atBottom: Bool) { apply { $0.userScrollMoved(atBottom: atBottom) } }
    func readHistory() { apply { $0.readHistory() } }
    func revealRow() { apply { $0.revealRow() } }
    func followLatest() { apply { $0.followLatest() } }

    func endUserScroll(atBottom: Bool, of items: [ChatStreamItem]) -> Bool {
        apply { $0.endUserScroll(atBottom: atBottom, of: items) }
    }

    private func apply<Result>(_ operation: (inout TranscriptFollowState) -> Result) -> Result {
        let result = operation(&state)
        if isFollowingLatest != state.isFollowingLatest { isFollowingLatest = state.isFollowingLatest }
        return result
    }
}

#if os(iOS)
private struct TranscriptTailAnimation: ViewModifier {
    let follow: TranscriptFollow
    let animatesDecorations: Bool
    let latestRowID: String?

    func body(content: Content) -> some View {
        content.animation(follow.isFollowingLatest && animatesDecorations ? .smooth(duration: 0.25) : nil,
                          value: latestRowID)
    }
}

private struct TranscriptSizeChangeAnchor: ViewModifier {
    let follow: TranscriptFollow

    func body(content: Content) -> some View {
        content.defaultScrollAnchor(follow.isFollowingLatest ? .bottom : .top, for: .sizeChanges)
    }
}

#endif

#if os(iOS)
private struct TranscriptRevealTask: ViewModifier {
    let reveal: TranscriptReveal
    let isRunwayShort: Bool
    let hasEarlierRows: Bool
    let isLoadingOlder: Bool
    let phase: TranscriptScrollPhase
    let action: @MainActor () async -> Void

    func body(content: Content) -> some View {
        return content.task(id: TranscriptRevealStep(reveal: reveal, isRunwayShort: isRunwayShort,
                                              isPaused: !phase.canReveal, hasEarlierRows: hasEarlierRows,
                                              isLoadingOlder: isLoadingOlder)) {
            await action()
        }
    }
}

#endif

#if os(iOS)
@MainActor
@Observable
private final class TranscriptPosition {
    @ObservationIgnored private var value: ScrollPosition
    private(set) var requestRevision = 0
    @ObservationIgnored private var initialAnchor: TranscriptReadingAnchor?
    @ObservationIgnored private weak var capture: TranscriptReadingCapture?
    @ObservationIgnored private var hasReportedClamp = false
    private static let logger = AppLogger(category: "Transcript")

    init(anchor: TranscriptReadingAnchor?) {
        if let anchor {
            value = ScrollPosition(id: anchor.rowID, anchor: UnitPoint(x: 0, y: anchor.rowFraction))
            initialAnchor = anchor
        } else {
            value = ScrollPosition(idType: String.self)
        }
    }

    var isRestoring: Bool { capture?.isRestoring ?? (initialAnchor != nil) }

    func bind(to capture: TranscriptReadingCapture) {
        self.capture = capture
        guard let anchor = initialAnchor else { return }
        initialAnchor = nil
        capture.beginRestoration(anchor, now: .now, request: { [weak self] rowID, alignment in
            self?.applyRestoration(rowID: rowID, alignment: alignment)
        }, completed: { [weak self] result in
            self?.restorationEnded(result)
        })
    }

    private func applyRestoration(rowID: String, alignment: TranscriptReadingAnchor.Alignment) {
        value.scrollTo(id: rowID, anchor: UnitPoint(x: 0, y: alignment.fraction))
        requestRevision += 1
        if alignment.isClamped, !hasReportedClamp {
            hasReportedClamp = true
            Self.logger.notice("Reading position restored to nearest supported identity anchor for row=\(rowID)")
        }
    }

    private func restorationEnded(_ result: TranscriptReadingRestoration.Result) {
        if result.outcome.preservesBookmark {
            value = ScrollPosition(idType: String.self)
            requestRevision += 1
            Self.logger.notice("Reading position unavailable row=\(result.rowID) outcome=\(result.outcome.rawValue); kept known bookmark")
        }
    }

    func finishRestoration() { capture?.finishRestoration() }

    func cancelRestoration() {
        initialAnchor = nil
        capture?.cancelRestoration()
    }

    var binding: Binding<ScrollPosition> {
        Binding(get: { self.value }, set: { self.value = $0 })
    }

    func scrollTo(id: String, anchor: UnitPoint?) {
        cancelRestoration()
        value.scrollTo(id: id, anchor: anchor)
        requestRevision += 1
    }
}

private struct TranscriptPositionBinding: ViewModifier {
    let position: TranscriptPosition

    func body(content: Content) -> some View {
        let _ = position.requestRevision
        PerfBuild.count("transcriptPositionBinding")
        return content.scrollPosition(position.binding)
    }
}

#endif

enum TranscriptAnchor {
    static let bottom = "transcript-bottom"
    static let content = "transcript-content"
}

#if os(iOS)
private extension ScrollGeometry {
    var distanceToBottom: CGFloat {
        contentSize.height - (visibleRect.maxY - contentInsets.bottom)
    }

    var viewport: CGRect {
        CGRect(origin: CGPoint(x: contentOffset.x + contentInsets.leading, y: contentOffset.y + contentInsets.top),
            size: containerSize)
    }
}

private struct TranscriptReadingFrame: ViewModifier {
    let rowID: String
    let renderedMessageID: UUID?
    let renderedMessages: RenderedMessageStore
    let visibility: TranscriptVisibility

    func body(content: Content) -> some View {
        let isRendered = renderedMessageID.map { renderedMessages.hasPresentation(for: $0) } ?? true
        return content
            .onGeometryChange(for: CGRect?.self, of: { geometry in
                isRendered ? geometry.frame(in: .named(TranscriptAnchor.content)) : nil
            }) { _, frame in
                visibility.setFrame(frame, rowID: rowID)
            }
            .onDisappear { visibility.setFrame(nil, rowID: rowID) }
    }
}

#endif

@MainActor
@Observable
final class TranscriptVisibility {
    @ObservationIgnored private let readingCapture = TranscriptReadingCapture()
    @ObservationIgnored private var rowStates: [String: TranscriptRowVisibilityState] = [:]
    @ObservationIgnored private var latestEnd: CGFloat?
    @ObservationIgnored private var readingEdge: (bottom: CGFloat, height: CGFloat)?
    @ObservationIgnored fileprivate private(set) var visibleRowIDs: Set<String> = []
    fileprivate private(set) var isFarFromLatest = false
    @ObservationIgnored private var scrollPhase = ScrollPhase.idle
    @ObservationIgnored private var motion: TranscriptScrollSignpost?
    private var isScrolling: Bool { scrollPhase != .idle }
    #if os(iOS)
    fileprivate func attachReadingPosition(_ position: TranscriptReadingPosition, source: TranscriptRowPresentations, scope: UUID,
                                           follow: TranscriptFollow, mounting: TranscriptMounting) {
        readingCapture.attach(position, scope: scope) {
            if follow.isFollowingLatest { return .latest }
            let start: String? = switch mounting.value {
            case .opening, .complete: nil
            case .opened(let id), .revealing(let id): id
            }
            return .reading(mountedStartRowID: start)
        }
        readingCapture.bindSource(source)
    }

    fileprivate func detachReadingPosition() {
        readingCapture.detach()
    }
    func captureReadingPosition() { readingCapture.captureReadingPosition() }
    fileprivate func updateViewport(_ viewport: CGRect) {
        readingCapture.updateViewport(viewport)
    }
    fileprivate func sourceMembershipChanged() { readingCapture.sourceMembershipChanged() }
    fileprivate func bindScrollPosition(_ position: TranscriptPosition) { position.bind(to: readingCapture) }
    #endif

    fileprivate func rowState(for id: String) -> TranscriptRowVisibilityState {
        if let state = rowStates[id] { return state }
        let state = TranscriptRowVisibilityState()
        state.update(visible: visibleRowIDs.contains(id), phase: scrollPhase)
        rowStates[id] = state
        return state
    }

    func retainRows(_ ids: Set<String>) {
        readingCapture.retainRows(ids)
        for id in rowStates.keys where !ids.contains(id) {
            rowStates.removeValue(forKey: id)?.update(visible: false, phase: scrollPhase)
        }
    }

    func shows(rowID: String) -> Bool { rowState(for: rowID).isVisible }

    fileprivate func setFrame(_ frame: CGRect?, rowID: String) {
        readingCapture.setFrame(frame, rowID: rowID)
    }

    fileprivate func readingTarget() -> TranscriptReadingTarget? {
        readingCapture.readingTarget().flatMap(TranscriptReadingTarget.init)
    }

    fileprivate func canTrimReadingPrefix(_ rows: ArraySlice<TranscriptRow>) -> Bool {
        guard let viewports = readingCapture.runwayViewportCount(from: rows.lazy.map(\.id)) else { return false }
        return viewports >= 2.5
    }

    func setVisibleRowIDs(_ ids: Set<String>) {
        guard ids != visibleRowIDs else { return }
        let changed = ids.symmetricDifference(visibleRowIDs)
        visibleRowIDs = ids
        for id in changed { rowStates[id]?.update(visible: ids.contains(id), phase: scrollPhase) }
    }

    func setScrollPhase(_ phase: ScrollPhase) {
        guard phase != scrollPhase else { return }
        scrollPhase = phase
        signpostMotion(phase)
        for id in visibleRowIDs { rowStates[id]?.update(visible: true, phase: phase) }
    }

    private func signpostMotion(_ phase: ScrollPhase) {
        guard phase != .idle, phase != .tracking else { return endMotion() }
        guard motion == nil else { return }
        motion = TranscriptScrollSignpost()
    }

    private func endMotion() {
        motion?.end()
        motion = nil
    }

    fileprivate func setLatestEnd(_ end: CGFloat) {
        latestEnd = end
        #if os(macOS)
        if !isScrolling { updateFarFromLatest() }
        #else
        updateFarFromLatest()
        #endif
    }

    fileprivate func setReadingEdge(bottom: CGFloat, height: CGFloat) {
        readingEdge = (bottom, height)
        updateFarFromLatest()
    }

    private func updateFarFromLatest() {
        guard let latestEnd, let readingEdge else { return }
        let isFar = TranscriptLayout.isFarFromLatest(latestEnd: latestEnd, visibleBottom: readingEdge.bottom, viewportHeight: readingEdge.height)
        setFarFromLatest(isFar)
    }

    fileprivate func isFarFromLatest(in geometry: ScrollGeometry) -> Bool? {
        guard let latestEnd else { return nil }
        let bottom = geometry.visibleRect.maxY - geometry.contentInsets.bottom
        let height = geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom
        return TranscriptLayout.isFarFromLatest(latestEnd: latestEnd, visibleBottom: bottom, viewportHeight: height)
    }

    fileprivate func setFarFromLatest(_ isFar: Bool) {
        if isFar != isFarFromLatest { isFarFromLatest = isFar }
    }
}

struct TranscriptRowInputs: Equatable {
    let row: TranscriptRow
    let isForkable: Bool
    let edgeStatus: HistoryEdge.Status?
    let canSendQueuedMessage: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row.id == rhs.row.id && lhs.row.revision == rhs.row.revision && lhs.isForkable == rhs.isForkable
            && lhs.edgeStatus == rhs.edgeStatus && lhs.canSendQueuedMessage == rhs.canSendQueuedMessage
    }
}

#if os(iOS)
private struct TranscriptRowContent<Content: View>: View, Equatable {
    let inputs: TranscriptRowInputs
    let presentationOwner: ObjectIdentifier
    private let presentations: TranscriptRowPresentations
    @State private var presentation: TranscriptRowPresentation
    @ViewBuilder let content: () -> Content

    init(inputs: TranscriptRowInputs, presentations: TranscriptRowPresentations, @ViewBuilder content: @escaping () -> Content) {
        self.inputs = inputs
        self.presentations = presentations
        presentationOwner = ObjectIdentifier(presentations)
        self.content = content
        _presentation = State(initialValue: TranscriptRowPresentation(store: presentations, rowID: inputs.row.id))
    }

    var body: some View {
        let _ = PerfBuild.count("transcriptRowBody")
        let _ = presentation.bind(to: presentations)
        content().environment(\.transcriptRowPresentation, presentation)
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.inputs == rhs.inputs && lhs.presentationOwner == rhs.presentationOwner
    }
}
#endif

/// Activity remains a sibling scroll target even when a message splits its section.
struct TranscriptRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case content(ChatStreamItem)
        case activity(JobTimelineEvent, isLast: Bool)
    }

    let id: String
    let kind: Kind
    fileprivate(set) var revision: UInt64 = 0

    private init(kind: Kind) {
        self.kind = kind
        id = switch kind {
        case .content(let item): item.id
        case .activity(let event, _): ChatStreamItem.activityRowID(eventID: event.id)
        }
    }

    static func content(_ item: ChatStreamItem) -> Self { Self(kind: .content(item)) }

    static func activity(_ event: JobTimelineEvent, isLast: Bool) -> Self {
        Self(kind: .activity(event, isLast: isLast))
    }

    var startsTurn: Bool {
        if case .content(.message(let message)) = kind { return message.role == .user }
        return false
    }

    var isReadingTarget: Bool {
        switch kind {
        case .activity, .content(.message), .content(.question), .content(.compaction), .content(.publishedVisual): true
        default: false
        }
    }

    var isHistoryEdge: Bool {
        if case .content(.historyEdge) = kind { return true }
        return false
    }

    var isMessage: Bool { message != nil }

    var message: ChatMessage? {
        if case .content(.message(let message)) = kind { return message }
        return nil
    }

    #if os(iOS)
    private static let openingBudget = 4_000
    private static let sliceTurns = 2
    private static let sliceBudget = 8_000
    private static let batchRowLimit = 80
    private static let followingTurnLimit = HistoryEdgeReader.turnBatch * 3 / 2
    private static let followingBudget = batchBudget * 3 / 2
    private static let followingRowLimit = batchRowLimit * 3 / 2
    #endif
    private static let sliceRowLimit = 16
    static let nearVisualRows = sliceRowLimit
    private static let batchBudget = 160_000
    private static let rowCost = 150

    var mountCost: Int {
        if case .content(.message(let message)) = kind { return Self.rowCost + message.text.utf8.count }
        return Self.rowCost
    }

    #if os(iOS)
    static func openingStart(of rows: [Self]) -> Int {
        start(before: rows.endIndex, in: rows, turns: 1, budget: openingBudget)
    }

    static func followingStart(of rows: [Self]) -> Int {
        batchStart(before: rows.endIndex, in: rows)
    }

    static func completeStart(firstMessageID: String?, in rows: [Self]) -> Int {
        guard let firstMessageID, let first = rows.lastIndex(where: { $0.id == firstMessageID }) else { return 0 }
        return rows[..<first].lastIndex(where: \.isMessage).map { $0 + 1 } ?? 0
    }

    static func sliceStart(before end: Int, in rows: [Self]) -> Int {
        max(start(before: end, in: rows, turns: sliceTurns, budget: sliceBudget), end - sliceRowLimit)
    }

    static func batchStart(before end: Int, in rows: [Self]) -> Int {
        max(start(before: end, in: rows, turns: HistoryEdgeReader.turnBatch, budget: batchBudget), end - batchRowLimit)
    }

    static func backlogIsShort(before end: Int, in rows: [Self]) -> Bool {
        !reaches(turns: HistoryEdgeReader.turnBatch, budget: batchBudget, rowLimit: batchRowLimit, rows[..<end])
    }

    static func exceedsFollowingBudget(_ rows: some Collection<Self>) -> Bool {
        reaches(turns: followingTurnLimit, budget: followingBudget, rowLimit: followingRowLimit, rows)
    }

    #endif

    static func runwayIsShort(turns: Int, cost: Int) -> Bool {
        turns < HistoryEdgeReader.turnBatch / 2 && cost < batchBudget / 2
    }

    #if os(iOS)
    static func runwayIsShort(above visibleRowIDs: Set<String>, in rows: [Self]) -> Bool? {
        guard let first = rows.firstIndex(where: { visibleRowIDs.contains($0.id) }) else { return nil }
        var turns = 0
        var cost = 0
        var rowCount = 0
        for row in rows[..<first] {
            rowCount += 1
            turns += row.startsTurn ? 1 : 0
            cost += row.mountCost
            if rowCount >= batchRowLimit / 2 || !runwayIsShort(turns: turns, cost: cost) { return false }
        }
        return true
    }

    private static func reaches(turns: Int, budget: Int, rowLimit: Int, _ rows: some Collection<Self>) -> Bool {
        var cost = 0
        var turnCount = 0
        var rowCount = 0
        for row in rows {
            rowCount += 1
            cost += row.mountCost
            if row.startsTurn { turnCount += 1 }
            if rowCount >= rowLimit || cost >= budget || turnCount >= turns { return true }
        }
        return false
    }

    private static func start(before end: Int, in rows: [Self], turns: Int, budget: Int) -> Int {
        var cost = 0
        var turnCount = 0
        for index in rows[..<end].indices.reversed() {
            cost += rows[index].mountCost
            if rows[index].startsTurn { turnCount += 1 }
            if turnCount >= turns || (cost >= budget && rows[index].isMessage) { return index }
        }
        return 0
    }

    #endif

    static func make(_ items: [ChatStreamItem]) -> [Self] {
        var rows: [Self] = []
        rows.reserveCapacity(items.count)
        for item in items {
            rows.append(.content(item))
            guard case .timeline(let timeline) = item, timeline.isExpanded else { continue }
            for (index, event) in timeline.events.enumerated() {
                rows.append(.activity(event, isLast: index == timeline.events.count - 1))
            }
        }
        return rows
    }
}

@MainActor
final class TranscriptRowProjection {
    private static let logger = AppLogger(category: "Transcript")
    private static var latestRevision: UInt64 = 0
    private var items: [ChatStreamItem] = []
    private var itemRevisions: [UInt64] = []
    private var projected: [TranscriptRow] = []
    private var positions: [String: Int] = [:]

    func row(for id: String) -> TranscriptRow? {
        positions[id].map { projected[$0] }
    }

    func rows(for items: [ChatStreamItem]) -> [TranscriptRow] {
        guard !items.span.isIdentical(to: self.items.span) else { return projected }
        let revisions = revisions(of: items)
        if revisions != itemRevisions {
            self.items = items
            itemRevisions = revisions
            PerfBuild.count("transcriptRowProjections")
            var rows = TranscriptRow.make(items)
            var positions: [String: Int] = [:]
            var item = -1
            for position in rows.indices {
                if case .content = rows[position].kind { item += 1 }
                rows[position].revision = revisions[item]
                guard positions.updateValue(position, forKey: rows[position].id) == nil else {
                    PerfBuild.count("transcriptProjectionRejected")
                    Self.logger.error("Rejected transcript projection with duplicate row identities")
                    return projected
                }
            }
            projected = rows
            self.positions = positions
        } else {
            self.items = items
        }
        return projected
    }

    private func revisions(of items: [ChatStreamItem]) -> [UInt64] {
        var previousPositions: [String: Int]?
        return items.indices.map { position in
            let item = items[position]
            var previous = self.items.indices.contains(position) && self.items[position].id == item.id ? position : nil
            if previous == nil {
                let lookup = previousPositions ?? Dictionary(
                    self.items.indices.map { (self.items[$0].id, $0) }, uniquingKeysWith: { first, _ in first })
                previousPositions = lookup
                previous = lookup[item.id]
            }
            if let previous, self.items[previous] == item { return itemRevisions[previous] }
            Self.latestRevision += 1
            return Self.latestRevision
        }
    }
}

#if os(iOS)
@MainActor
@Observable
private final class TranscriptMounting {
    var value: TranscriptReveal

    init(startRowID: String?) {
        value = startRowID.map(TranscriptReveal.opened) ?? .opening
    }
}
#endif

#if os(macOS)
private struct TranscriptPolicyContent<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        let _ = PerfBuild.count("transcriptPolicyBody")
        content()
    }
}
#endif

#if os(iOS)
private enum TranscriptReveal: Hashable {
    case opening
    case opened(String)
    case revealing(String)
    case complete(firstMessageID: String?)
}

private struct TranscriptRevealStep: Hashable {
    let reveal: TranscriptReveal
    let isRunwayShort: Bool
    let isPaused: Bool
    let hasEarlierRows: Bool
    let isLoadingOlder: Bool
}
#endif

/// One explicit page action. User scrolling, a new row request, or leaving the
/// transcript cancels its restoration; saved targets retain identity and alignment.
private struct TranscriptHistoryRead: Identifiable {
    let id = UUID()
    let edge: HistoryEdge
    let task: Task<Void, Never>
    #if os(iOS)
    var target: TranscriptReadingTarget?
    #endif
    var isLoaded = false
}

private struct TurnOutcomeRow: View {
    let outcome: TurnOutcome

    #if os(macOS)
    @Environment(\.transcriptSurfaceActivity) private var surfaceActivity
    #endif

    var body: some View {
        #if os(macOS)
        let _ = surfaceActivity?.recordBody()
        #endif
        Label(text, systemImage: symbol)
            .scaledFont(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .accessibilityIdentifier("transcript-\(ChatStreamItem.turnOutcome(outcome).id)")
    }

    private var text: String {
        switch outcome.kind {
        case .failed(let message): message ?? "The agent stopped with an error."
        case .noReply: "The agent finished without a reply."
        }
    }

    private var symbol: String {
        switch outcome.kind {
        case .failed: "exclamationmark.triangle"
        case .noReply: "ellipsis.bubble"
        }
    }
}

private struct ViewedMediaRow: View {
    let media: ViewedMedia

    var body: some View {
        let url = URL(fileURLWithPath: media.path)
        VStack(alignment: .leading, spacing: 6) {
            Label(media.caption, systemImage: "eye")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityHidden(true)
            ChatImageView(url: url, alt: "Viewed \(media.caption)")
        }
        .padding(.vertical, ChatBubble.messageVerticalInset)
    }
}

private struct TranscriptHistoryEdgeRow: View {
    let edge: HistoryEdge
    let status: HistoryEdge.Status?
    let retry: () -> Void

    #if os(macOS)
    @Environment(\.transcriptSurfaceActivity) private var surfaceActivity
    #endif

    var body: some View {
        #if os(macOS)
        let _ = surfaceActivity?.recordBody()
        #endif
        ZStack {
            switch status {
            case .loading:
                ProgressView()
            case .failed:
                HStack(spacing: 12) {
                    Text(edge.kind == .newer ? "Couldn’t load later messages" : "Couldn’t load earlier messages")
                        .foregroundStyle(.secondary)
                    Button("Retry", action: retry)
                }
                .scaledFont(.callout)
            case nil:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, minHeight: ControlMetrics.minimumTarget)
        .accessibilityIdentifier("transcript-\(edge.id)")
    }
}

struct TranscriptReadingTarget {
    let rowID: String
    let anchor: UnitPoint
    init?(_ reading: TranscriptReadingAnchor) {
        guard let alignment = reading.identityAlignment else { return nil }
        rowID = reading.rowID
        anchor = UnitPoint(x: 0, y: alignment)
    }
}

struct TranscriptTextSelection: Identifiable {
    let id: UUID
    let text: String
}

@MainActor
@Observable
fileprivate final class TranscriptRowVisibilityState {
    private(set) var isVisible = false
    private(set) var isScrolling = false
    private(set) var isMoving = false
    @ObservationIgnored private(set) var isSteadilyVisible = false

    fileprivate func update(visible: Bool, phase: ScrollPhase) {
        let scrolling = phase != .idle
        let moving = scrolling && phase != .tracking
        if isScrolling != scrolling { isScrolling = scrolling }
        if isMoving != moving { isMoving = moving }
        if isVisible != visible {
            PerfBuild.count("row.visible")
            isVisible = visible
        }
        let steady = visible && phase == .idle
        if isSteadilyVisible != steady {
            PerfBuild.count("row.steady")
            isSteadilyVisible = steady
        }
    }
}

struct TranscriptRowVisibility: Equatable {
    private let state: TranscriptRowVisibilityState

    @MainActor init(rowID: String, visibility: TranscriptVisibility) {
        state = visibility.rowState(for: rowID)
    }

    @MainActor var isVisible: Bool { state.isVisible }
    @MainActor var isScrolling: Bool { state.isScrolling }
    @MainActor var isMoving: Bool { state.isMoving }
    @MainActor var isSteadilyVisible: Bool { state.isSteadilyVisible }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.state === rhs.state }
}

extension EnvironmentValues {
    @Entry var transcriptRowVisibility: TranscriptRowVisibility?
}
