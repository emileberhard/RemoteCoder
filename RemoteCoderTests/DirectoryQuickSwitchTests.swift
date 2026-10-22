import CoreGraphics
import Foundation
import Testing
@testable import RemoteCoder

@MainActor
struct DirectoryQuickSwitchTests {
    @Test func hoverIsLocalAndReleaseCommitsTheFinalContactExactlyOnce() throws {
        let feedback = HapticFixture()
        defer { feedback.cleanUp() }
        let picker = DirectoryQuickSwitchPresentation(haptics: feedback.service)
        var actions: [DirectoryQuickSwitchPresentation.Action] = []
        let session = try open(picker) { actions.append($0) }
        picker.update(session, at: point(in: session, index: 0))
        #expect(session.hovered?.favoritePath == "/work/A")
        #expect(actions.isEmpty)
        let player = try #require(feedback.players.first)
        #expect(player.events == [.lift, .selection])
        picker.finish(session, at: point(in: session, index: 2))
        picker.finish(session, at: point(in: session, index: 1))
        #expect(actions.map(\.favoritePath) == ["/work/C"])
        #expect(player.events == [.lift, .selection, .commit])
        #expect(player.finished)
        #expect(picker.session == nil)
    }

    @Test func returningToSourceOrLeavingPanelCancelsWithoutAWrite() throws {
        let feedback = HapticFixture()
        defer { feedback.cleanUp() }
        let picker = DirectoryQuickSwitchPresentation(haptics: feedback.service)
        var actions: [DirectoryQuickSwitchPresentation.Action] = []
        let first = try open(picker) { actions.append($0) }
        picker.update(first, at: point(in: first, index: 1))
        picker.finish(first, at: CGPoint(x: first.source.midX, y: first.source.midY))
        let second = try open(picker) { actions.append($0) }
        picker.update(second, at: point(in: second, index: 1))
        picker.finish(second, at: CGPoint(x: second.layout.frame.maxX + 20, y: second.layout.rows.midY))
        #expect(actions.isEmpty)
        #expect(feedback.players.allSatisfy { $0.events == [.lift, .selection] && $0.cancelled })
    }

    @Test func boundaryJitterDoesNotAlternateSelectionOrHaptics() throws {
        let feedback = HapticFixture()
        defer { feedback.cleanUp() }
        let picker = DirectoryQuickSwitchPresentation(haptics: feedback.service)
        let session = try open(picker)
        picker.update(session, at: point(in: session, index: 0))
        let layout = session.layout
        let leftColumn = layout.rows.minX + layout.columnWidth / 2
        let firstRow = layout.rows.minY + layout.rowHeight / 2
        let rowBoundary = layout.rows.minY + layout.rowHeight
        let columnBoundary = layout.rows.minX + layout.columnWidth
        for offset in [-1.0, 1, 3, -2] {
            picker.update(session, at: CGPoint(x: leftColumn, y: rowBoundary + offset))
            #expect(session.hovered?.favoritePath == "/work/A")
            picker.update(session, at: CGPoint(x: columnBoundary + offset, y: firstRow))
            #expect(session.hovered?.favoritePath == "/work/A")
        }
        picker.update(session, at: CGPoint(x: columnBoundary + 5, y: firstRow))
        #expect(session.hovered?.favoritePath == "/work/B")
        picker.update(session, at: CGPoint(x: leftColumn, y: rowBoundary + 5))
        #expect(session.hovered?.favoritePath == "/work/C")
        #expect(feedback.players.first?.events == [.lift, .selection, .selection, .selection])
    }

    @Test func unchangedFavoriteDoesNotStartAnotherConversation() throws {
        let feedback = HapticFixture()
        defer { feedback.cleanUp() }
        let picker = DirectoryQuickSwitchPresentation(haptics: feedback.service)
        var changed = false
        let session = try open(picker) { _ in changed = true }
        picker.finish(session, at: point(in: session, index: 0))
        #expect(!changed)
        #expect(feedback.players.first?.events == [.lift, .disclosure])
    }

    @Test func replacementRejectsOldMoveReleaseCancelAndAnimationCompletion() throws {
        let feedback = HapticFixture()
        defer { feedback.cleanUp() }
        let picker = DirectoryQuickSwitchPresentation(haptics: feedback.service)
        var actions: [DirectoryQuickSwitchPresentation.Action] = []
        let old = try open(picker) { actions.append($0) }
        let current = try open(picker) { actions.append($0) }
        #expect(old.hostID != current.hostID)
        picker.update(old, at: point(in: old, index: 1))
        picker.finish(old, at: point(in: old, index: 1))
        picker.dismiss(owner: old.owner)
        picker.completeDismissal(of: old)
        #expect(actions.isEmpty)
        #expect(picker.session === current)
        #expect(picker.presentedSession === current)
        #expect(feedback.players.first?.cancelled == true)
        #expect(feedback.players.last?.events == [.lift])
    }

    @Test func resizingOrContextCancellationInvalidatesInputImmediately() throws {
        let feedback = HapticFixture()
        defer { feedback.cleanUp() }
        let picker = DirectoryQuickSwitchPresentation(haptics: feedback.service)
        var actions: [DirectoryQuickSwitchPresentation.Action] = []
        let session = try open(picker) { actions.append($0) }
        picker.update(session, at: point(in: session, index: 1))
        picker.updateViewport(CGRect(x: 0, y: 0, width: 800, height: 390))
        picker.finish(session, at: point(in: session, index: 1))
        #expect(picker.presentedSession == nil)
        #expect(actions.isEmpty)
        let next = try open(picker) { actions.append($0) }
        picker.dismiss(owner: next.owner)
        picker.finish(next, at: point(in: next, index: 1))
        #expect(picker.session == nil)
        #expect(picker.presentedSession === next)
        picker.completeDismissal(of: next)
        #expect(picker.presentedSession == nil)
        #expect(actions.isEmpty)
    }

    @Test func edgeScrollUsesVisibleBoundsAndReleaseResolvesTheScrolledRow() throws {
        let feedback = HapticFixture()
        defer { feedback.cleanUp() }
        let picker = DirectoryQuickSwitchPresentation(haptics: feedback.service)
        var actions: [DirectoryQuickSwitchPresentation.Action] = []
        let paths = (0..<40).map { "/work/\($0)" }
        let session = try open(picker, paths: paths) { actions.append($0) }
        let bottom = CGPoint(x: session.layout.rows.minX + 10, y: session.layout.rows.maxY - 10)
        picker.update(session, at: bottom)
        #expect(session.scrollDirection == 1)
        #expect(session.nextScrollOffset > 0)
        picker.updateScrollOffset(session, to: session.maximumScrollOffset)
        #expect(session.scrollDirection == 0)
        #expect(session.hovered?.favoritePath == "/work/38")
        picker.finish(session, at: bottom)
        #expect(actions.map(\.favoritePath) == ["/work/38"])
        let offset = session.scrollOffset
        picker.updateScrollOffset(session, to: 0)
        #expect(session.scrollOffset == offset)
    }

    @Test func edgeScrollStopsOutsideTheListAndCanReverse() throws {
        let feedback = HapticFixture()
        defer { feedback.cleanUp() }
        let picker = DirectoryQuickSwitchPresentation(haptics: feedback.service)
        let session = try open(picker, paths: (0..<40).map { "/work/\($0)" })
        picker.updateScrollOffset(session, to: 200)
        picker.update(session, at: CGPoint(x: session.layout.rows.midX, y: session.layout.rows.minY + 8))
        #expect(session.scrollDirection == -1)
        #expect(session.nextScrollOffset < 200)
        picker.update(session, at: CGPoint(x: session.layout.rows.minX - 1, y: session.layout.rows.minY + 8))
        #expect(session.scrollDirection == 0)
        #expect(session.hovered == nil)
    }

    @Test func emptyFavoritesStillOfferTheBrowserAndCopyRespectsRightToLeft() throws {
        let feedback = HapticFixture()
        defer { feedback.cleanUp() }
        let picker = DirectoryQuickSwitchPresentation(haptics: feedback.service)
        var actions: [DirectoryQuickSwitchPresentation.Action] = []
        let empty = try open(picker, paths: [], currentPath: nil) { actions.append($0) }
        picker.update(empty, at: CGPoint(x: empty.layout.rows.midX, y: empty.layout.rows.midY))
        #expect(empty.hovered == nil)
        picker.finish(empty, at: CGPoint(x: empty.layout.footer.minX + 20, y: empty.layout.footer.midY))
        #expect(actions == [.browse])
        let rtl = try open(picker, rtl: true) { actions.append($0) }
        picker.finish(rtl, at: CGPoint(x: rtl.layout.footer.minX + 20, y: rtl.layout.footer.midY))
        #expect(actions == [.browse, .copyPath])
        #expect(feedback.players.last?.events == [.lift])
    }

    @Test func audioPolicySuppressesFeedbackButNotFolderSelection() throws {
        let feedback = HapticFixture()
        defer { feedback.cleanUp() }
        feedback.callActive = true
        let picker = DirectoryQuickSwitchPresentation(haptics: feedback.service)
        var actions: [DirectoryQuickSwitchPresentation.Action] = []
        let session = try open(picker) { actions.append($0) }
        picker.update(session, at: point(in: session, index: 1))
        picker.finish(session, at: point(in: session, index: 1))
        #expect(actions.map(\.favoritePath) == ["/work/B"])
        #expect(feedback.players.isEmpty)
    }

    @Test func layoutFitsTheViewportAtBothEdgesAndLargerTextSizes() throws {
        let viewport = CGRect(x: 0, y: 47, width: 393, height: 610)
        for source in [CGRect(x: 0, y: 51, width: 100, height: 44), CGRect(x: 280, y: 530, width: 100, height: 44)] {
            for height in [44.0, 120] {
                let layout = try #require(DirectoryQuickSwitchLayout(viewport: viewport, source: source, count: 30,
                                                                     rowHeight: height, columnCount: 2))
                #expect(viewport.contains(layout.frame))
                #expect(layout.frame.contains(layout.rows))
                #expect(layout.frame.contains(layout.footer))
                #expect(layout.rows.height >= height)
                #expect(layout.rows.height <= height * 10)
                #expect(layout.rows.height.truncatingRemainder(dividingBy: height) == 0)
            }
        }
        #expect(DirectoryQuickSwitchLayout(viewport: .zero, source: .zero, count: 3, rowHeight: 44, columnCount: 2) == nil)
    }

    @Test func compactGridShowsTwentyFavoritesWithoutScrolling() throws {
        let viewport = CGRect(x: 0, y: 47, width: 393, height: 740)
        let source = CGRect(x: 96, y: 55, width: 200, height: 44)
        let layout = try #require(DirectoryQuickSwitchLayout(viewport: viewport, source: source, count: 30,
                                                             rowHeight: 40, columnCount: 2))
        #expect(layout.frame.width == 360)
        #expect(layout.columnWidth == 172)
        #expect(layout.rowHeight == 40)
        #expect(layout.rows.height == 400)
        #expect(layout.contentHeight == 600)
        #expect(layout.footer.height == 40)
        #expect(layout.frame.height == 492)
        #expect(layout.rows.minY >= source.maxY)

        let smallText = try #require(DirectoryQuickSwitchLayout(viewport: viewport, source: source, count: 3,
                                                                rowHeight: 32, columnCount: 2))
        #expect(smallText.rowHeight == 40)
        #expect(smallText.rows.height == 80)
        #expect(smallText.frame.height == 172)

        let largeText = try #require(DirectoryQuickSwitchLayout(viewport: viewport, source: source, count: 3,
                                                                rowHeight: 40, columnCount: 1))
        #expect(largeText.columnWidth == 344)
        #expect(largeText.rows.height == 120)
    }

    @Test func gridSelectsByColumnLeavesTheTrailingGapEmptyAndMirrorsRightToLeft() throws {
        let feedback = HapticFixture()
        defer { feedback.cleanUp() }
        let picker = DirectoryQuickSwitchPresentation(haptics: feedback.service)
        var actions: [DirectoryQuickSwitchPresentation.Action] = []
        let session = try open(picker) { actions.append($0) }
        let secondRow = session.layout.rows.minY + session.layout.rowHeight * 1.5
        picker.update(session, at: CGPoint(x: session.layout.rows.maxX - 10, y: secondRow))
        #expect(session.hovered == nil)
        picker.finish(session, at: point(in: session, index: 1))
        #expect(actions.map(\.favoritePath) == ["/work/B"])

        let rtl = try open(picker, rtl: true) { actions.append($0) }
        picker.update(rtl, at: CGPoint(x: rtl.layout.rows.minX + 10, y: secondRow))
        #expect(rtl.hovered == nil)
        picker.update(rtl, at: CGPoint(x: rtl.layout.rows.maxX - 10, y: secondRow))
        #expect(rtl.hovered?.favoritePath == "/work/C")
        picker.finish(rtl, at: CGPoint(x: rtl.layout.rows.minX + 10, y: rtl.layout.rows.minY + 10))
        #expect(actions.map(\.favoritePath) == ["/work/B", "/work/B"])
    }

    @Test func theSamePathOnAnotherHostIsADistinctFavorite() throws {
        let feedback = HapticFixture()
        defer { feedback.cleanUp() }
        let picker = DirectoryQuickSwitchPresentation(haptics: feedback.service)
        picker.updateViewport(CGRect(x: 0, y: 47, width: 393, height: 740))
        let mini = UUID()
        let book = UUID()
        let favorites = FavoriteFolder.list([
            .init(id: mini, name: "Mini", paths: ["/work/A"], remoteHomePath: "/work"),
            .init(id: book, name: "Book", paths: ["/work/A"], remoteHomePath: "/work"),
        ])
        var actions: [DirectoryQuickSwitchPresentation.Action] = []
        let open = {
            try #require(picker.present(owner: UUID(), hostID: mini, favorites: favorites, currentPath: "/work/A",
                source: CGRect(x: 96, y: 55, width: 200, height: 44), rowHeight: 40, columnCount: 2,
                isRightToLeft: false) { actions.append($0) })
        }

        let current = try open()
        picker.finish(current, at: point(in: current, index: 0))
        #expect(actions.isEmpty)
        let other = try open()
        picker.finish(other, at: point(in: other, index: 1))
        #expect(actions == [.favorite(favorites[1])])
    }

    private func open(_ picker: DirectoryQuickSwitchPresentation,
                      paths: [String] = ["/work/A", "/work/B", "/work/C"],
                      currentPath: String? = "/work/A", rtl: Bool = false,
                      perform: @escaping (DirectoryQuickSwitchPresentation.Action) -> Void = { _ in }) throws
        -> DirectoryQuickSwitchPresentation.Session {
        picker.updateViewport(CGRect(x: 0, y: 47, width: 393, height: 740))
        let hostID = UUID()
        let favorites = FavoriteFolder.list([.init(id: hostID, name: "Test host", paths: paths, remoteHomePath: "/work")])
        return try #require(picker.present(owner: UUID(), hostID: hostID, favorites: favorites, currentPath: currentPath,
            source: CGRect(x: 96, y: 55, width: 200, height: 44), rowHeight: 40, columnCount: 2,
            isRightToLeft: rtl, perform: perform))
    }

    private func point(in session: DirectoryQuickSwitchPresentation.Session, index: Int) -> CGPoint {
        let layout = session.layout
        return CGPoint(x: layout.rows.minX + (CGFloat(index % layout.columnCount) + 0.5) * layout.columnWidth,
                       y: layout.rows.minY + (CGFloat(index / layout.columnCount) + 0.5) * layout.rowHeight
                           - session.scrollOffset)
    }
}

private extension DirectoryQuickSwitchPresentation.Action {
    var favoritePath: String? {
        if case .favorite(let favorite) = self { favorite.path } else { nil }
    }
}
