import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class ChatWindowModel {
    let id: UUID
    let isPrimary: Bool
    private(set) var selectedTarget: ExecutionTarget?
    private(set) var isAttached = false
    private(set) var isVisible = true
    private(set) var isHistoryDrawerOpen = false
    var showsHistoryDrawer: Bool { isHistoryDrawerOpen && isVisible }
    @ObservationIgnored private var historyDrawerOverlaysTranscript = true
    var drawerQuery = ""
    private(set) var revealedProjects: Set<String> = []
    private(set) var revealsAllDrafts = false
    private(set) var revealsAllAutomations = false
    private(set) var settledRowLimit = ConversationDrawerArrangement.initialSettledRowLimit
    private var screens: [ExecutionTarget: ChatScreenModel] = [:]
    @ObservationIgnored private let focusTasks = OwnedTasks<FocusTask>()
    @ObservationIgnored private let logger = AppLogger(category: "ChatWindow")
    #if RC_PERF_HARNESS
    @ObservationIgnored var performanceSidebar: PerformanceReplaySidebarControl?
    #endif

    private enum FocusTask: Hashable { case composer }

    var composerFocusCompletion: Task<Void, Never>? { focusTasks.task(.composer) }

    init(id: UUID, isPrimary: Bool, selectedTarget: ExecutionTarget?) {
        self.id = id
        self.isPrimary = isPrimary
        self.selectedTarget = selectedTarget
    }

    var logID: String { String(id.uuidString.prefix(8)) }

    var selectedScreen: ChatScreenModel? {
        selectedTarget.flatMap { screens[$0] }
    }

    func screen(for target: ExecutionTarget) -> ChatScreenModel? {
        screens[target]
    }

    func install(_ screen: ChatScreenModel) {
        screens[screen.executionTarget] = screen
    }

    func removeScreen(for target: ExecutionTarget) {
        if selectedTarget == target { cancelComposerFocus() }
        if let screen = screens.removeValue(forKey: target) { screen.target.releaseScreen(screen) }
    }

    func removeAllScreens() -> [ChatScreenModel] {
        cancelComposerFocus()
        let removed = Array(screens.values)
        screens.removeAll()
        for screen in removed { screen.target.releaseScreen(screen) }
        return removed
    }

    func setVisible(_ visible: Bool) {
        if !visible { cancelComposerFocus() }
        if isVisible != visible { isVisible = visible }
    }

    func attach() {
        isAttached = true
    }

    func detach() {
        cancelComposerFocus()
        isAttached = false
    }

    func select(_ target: ExecutionTarget?) {
        guard selectedTarget != target else { return }
        cancelComposerFocus()
        logger.notice("window select id=\(self.logID) from=\(self.selectedTarget?.id ?? "none") to=\(target?.id ?? "none")")
        selectedTarget = target
    }

    func requestComposerFocus(for screen: ChatScreenModel, _ focus: @escaping @MainActor () -> Void) {
        let transcriptIdentity = screen.transcriptIdentity
        focusTasks.start(.composer) { [weak self, weak screen] in
            do { try await Task.sleep(for: .milliseconds(180)) }
            catch { return }
            guard !Task.isCancelled, let self, let screen, !screen.isRetired, self.isAttached, self.isVisible,
                  self.selectedScreen === screen, screen.transcriptIdentity == transcriptIdentity else { return }
            focus()
        }
    }

    func cancelComposerFocus() {
        focusTasks.cancel(.composer)
    }

    func setHistoryDrawerOpen(_ isOpen: Bool, overlaysTranscript: Bool) {
        historyDrawerOverlaysTranscript = overlaysTranscript
        if isOpen, !isHistoryDrawerOpen {
            revealedProjects = []
            revealsAllDrafts = false
            revealsAllAutomations = false
            settledRowLimit = ConversationDrawerArrangement.initialSettledRowLimit
        }
        isHistoryDrawerOpen = isOpen
    }

    func reveal(project key: String) {
        revealedProjects.insert(key)
    }

    func revealAllDrafts() {
        revealsAllDrafts = true
    }

    func revealAllAutomations() {
        revealsAllAutomations = true
    }

    func revealMoreSettled() {
        settledRowLimit += ConversationDrawerArrangement.settledRowsRevealedPerStep
    }

    func setPresentation(presenting: Bool, isKey: Bool) {
        for (target, screen) in screens {
            let presented = presenting && target == selectedTarget
            screen.setPresentation(TargetPresentation(presented: presented, key: presented && isKey,
                drawerOpen: showsHistoryDrawer, drawerOverlaysTranscript: historyDrawerOverlaysTranscript))
        }
    }
}
