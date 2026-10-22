import CoreGraphics
import Foundation
import Observation

/// A hold previews locally. Only its final contact may invoke the captured action.
@Observable @MainActor
final class DirectoryQuickSwitchPresentation {
    enum Action: Equatable {
        case favorite(FavoriteFolder), browse, copyPath
    }

    private(set) var session: Session?
    private(set) var presentedSession: Session?
    private var viewport = CGRect.zero
    private let haptics: HapticService

    init(haptics: HapticService = .shared) { self.haptics = haptics }

    func updateViewport(_ frame: CGRect) {
        guard viewport != frame else { return }
        dismissImmediately()
        viewport = frame
    }

    func present(owner: UUID, hostID: UUID, favorites: [FavoriteFolder], currentPath: String?,
                 source: CGRect, rowHeight: CGFloat, columnCount: Int,
                 isRightToLeft: Bool, perform: @escaping (Action) -> Void) -> Session? {
        dismissImmediately()
        guard !source.isEmpty,
              let layout = DirectoryQuickSwitchLayout(viewport: viewport, source: source, count: favorites.count,
                                                       rowHeight: rowHeight, columnCount: columnCount) else { return nil }
        let newSession = Session(owner: owner, hostID: hostID, favorites: favorites, currentPath: currentPath,
                                 source: source, layout: layout, isRightToLeft: isRightToLeft, perform: perform)
        session = newSession
        presentedSession = newSession
        haptics.beginInteraction(owner: owner)
        haptics.playInteraction(.lift, owner: owner)
        return newSession
    }

    func update(_ session: Session, at point: CGPoint) {
        guard self.session === session else { return }
        session.pointer = point
        updateHover(session, reportsFeedback: true)
    }

    func updateScrollOffset(_ session: Session, to offset: CGFloat) {
        guard self.session === session else { return }
        session.scrollOffset = min(max(0, offset), session.maximumScrollOffset)
        updateHover(session, reportsFeedback: true)
    }

    private func updateHover(_ session: Session, reportsFeedback: Bool) {
        let next = session.target(at: session.pointer)
        if next != session.hovered {
            session.hovered = next
            if reportsFeedback, next != nil { haptics.playInteraction(.selection, owner: session.owner) }
        }
        session.scrollDirection = session.edgeScrollDirection
    }

    func finish(_ session: Session, at point: CGPoint) {
        guard self.session === session else { return }
        session.pointer = point
        // The release owns the last contact; don't layer a late hover tick onto it.
        updateHover(session, reportsFeedback: false)
        let action = session.hovered
        self.session = nil
        session.scrollDirection = 0
        guard let action else {
            haptics.cancelInteraction(owner: session.owner)
            return
        }
        switch action {
        case .favorite(let favorite):
            haptics.playInteraction(session.isCurrent(favorite) ? .disclosure : .commit, owner: session.owner)
        case .browse:
            haptics.playInteraction(.disclosure, owner: session.owner)
        case .copyPath:
            break // The clipboard write owns its acknowledgement.
        }
        haptics.finishInteraction(owner: session.owner)
        if case .favorite(let favorite) = action, session.isCurrent(favorite) { return }
        session.perform(action)
    }

    func dismiss(owner: UUID) {
        guard session?.owner == owner else { return }
        dismiss()
    }

    func dismiss() {
        if let session {
            session.scrollDirection = 0
            haptics.cancelInteraction(owner: session.owner)
        }
        session = nil
    }

    func dismissImmediately() {
        dismiss()
        presentedSession = nil
    }

    func completeDismissal(of session: Session) {
        guard self.session == nil, presentedSession === session else { return }
        presentedSession = nil
    }

    @Observable @MainActor
    final class Session: Identifiable {
        let id = UUID()
        let owner: UUID
        let hostID: UUID
        let favorites: [FavoriteFolder]
        let currentPath: String?
        let source: CGRect
        let layout: DirectoryQuickSwitchLayout
        let isRightToLeft: Bool
        fileprivate let perform: (Action) -> Void
        fileprivate(set) var hovered: Action?
        fileprivate(set) var scrollOffset: CGFloat = 0
        fileprivate(set) var scrollDirection = 0
        @ObservationIgnored fileprivate var pointer = CGPoint(x: -1, y: -1)

        init(owner: UUID, hostID: UUID, favorites: [FavoriteFolder], currentPath: String?,
             source: CGRect, layout: DirectoryQuickSwitchLayout,
             isRightToLeft: Bool, perform: @escaping (Action) -> Void) {
            self.owner = owner
            self.hostID = hostID
            self.favorites = favorites
            self.currentPath = currentPath
            self.source = source
            self.layout = layout
            self.isRightToLeft = isRightToLeft
            self.perform = perform
        }

        func isCurrent(_ favorite: FavoriteFolder) -> Bool {
            favorite.hostID == hostID && favorite.path == currentPath
        }

        var maximumScrollOffset: CGFloat {
            max(0, layout.contentHeight - layout.rows.height)
        }

        var nextScrollOffset: CGFloat {
            min(max(0, scrollOffset + CGFloat(scrollDirection) * layout.rowHeight * 0.3), maximumScrollOffset)
        }

        fileprivate func target(at point: CGPoint) -> Action? {
            if layout.rows.contains(point), !favorites.isEmpty {
                let content = CGPoint(x: point.x - layout.rows.minX, y: point.y - layout.rows.minY + scrollOffset)
                // A small dead band prevents finger jitter from alternating cells and ticks.
                if case .favorite(let favorite) = hovered, let index = favorites.firstIndex(of: favorite),
                   cell(at: index).insetBy(dx: -4, dy: -4).contains(content) { return hovered }
                let column = displayColumn(min(Int(content.x / layout.columnWidth), layout.columnCount - 1))
                let index = Int(content.y / layout.rowHeight) * layout.columnCount + column
                return favorites.indices.contains(index) ? .favorite(favorites[index]) : nil
            }
            if layout.footer.contains(point) {
                let isLeading = isRightToLeft ? point.x >= layout.footer.midX : point.x < layout.footer.midX
                return isLeading ? .browse : currentPath == nil ? nil : .copyPath
            }
            return nil
        }

        private func cell(at index: Int) -> CGRect {
            CGRect(x: CGFloat(displayColumn(index % layout.columnCount)) * layout.columnWidth,
                   y: CGFloat(index / layout.columnCount) * layout.rowHeight,
                   width: layout.columnWidth, height: layout.rowHeight)
        }

        private func displayColumn(_ column: Int) -> Int {
            isRightToLeft ? layout.columnCount - 1 - column : column
        }

        fileprivate var edgeScrollDirection: Int {
            guard !favorites.isEmpty, layout.rows.contains(pointer) else { return 0 }
            let edge = min(22, layout.rowHeight / 3)
            if pointer.y < layout.rows.minY + edge, scrollOffset > 0 { return -1 }
            if pointer.y > layout.rows.maxY - edge, scrollOffset < maximumScrollOffset { return 1 }
            return 0
        }
    }
}

/// The rendered rows and hit testing share these exact global-coordinate bounds.
struct DirectoryQuickSwitchLayout {
    static let minimumRowHeight: CGFloat = 40

    let frame: CGRect
    let rows: CGRect
    let footer: CGRect
    let rowHeight: CGFloat
    let headerHeight: CGFloat
    let columnCount: Int
    let contentHeight: CGFloat

    var columnWidth: CGFloat { rows.width / CGFloat(columnCount) }

    init?(viewport: CGRect, source: CGRect, count: Int, rowHeight: CGFloat, columnCount: Int) {
        guard rowHeight > 0, count >= 0, columnCount > 0 else { return nil }
        let rowHeight = max(Self.minimumRowHeight, rowHeight)
        let width = min(360, viewport.width - 32)
        // Keep the original header entirely in the cancellation zone.
        let headerHeight = max(source.height, rowHeight * 0.75)
        let footerHeight = rowHeight
        let availableRows = viewport.height - 32 - headerHeight - footerHeight - 8
        guard width >= 200, availableRows >= rowHeight else { return nil }
        let rowCount = (count + columnCount - 1) / columnCount
        let visibleRows = min(CGFloat(max(1, rowCount)), 10, (availableRows / rowHeight).rounded(.down))
        let rowsHeight = visibleRows * rowHeight
        let height = headerHeight + rowsHeight + footerHeight + 8
        let x = min(max(source.midX - width / 2, viewport.minX + 16), viewport.maxX - 16 - width)
        let y = min(max(source.minY, viewport.minY + 8), viewport.maxY - 16 - height)
        frame = CGRect(x: x, y: y, width: width, height: height)
        rows = CGRect(x: x + 8, y: y + headerHeight, width: width - 16, height: rowsHeight)
        footer = CGRect(x: x + 8, y: rows.maxY, width: width - 16, height: footerHeight)
        self.headerHeight = headerHeight
        self.rowHeight = rowHeight
        self.columnCount = columnCount
        contentHeight = CGFloat(rowCount) * rowHeight
    }
}
