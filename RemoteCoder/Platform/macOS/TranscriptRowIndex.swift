#if os(macOS)
import OSLog
import SwiftUI

struct TranscriptRowIndex {
    struct Row: Equatable {
        enum Role: Equatable { case content, reading, bottom }
        let id: String
        let role: Role
        let startsTurn: Bool
        let mountCost: Int
        let minY: CGFloat
        let maxY: CGFloat
    }

    typealias PreservationAnchor = TranscriptReadingAnchor

    private static let logger = Logger(subsystem: "RemoteCoder", category: "Transcript")
    private let rows: [Row]
    private let positions: [String: Int]
    private let shortRunway: [Bool]
    let latestEnd: CGFloat?

    init?(rows: [Row], bounds: CGRect) {
        let span = PerfBuild.span("native.index"); defer { span.end() }
        guard bounds.minY.isFinite, bounds.maxY.isFinite, bounds.width.isFinite,
              bounds.width > 0, bounds.height.isFinite, bounds.height >= 0 else {
            Self.reject("invalid document dimensions")
            return nil
        }
        var positions: [String: Int] = [:]
        var previousEnd = bounds.minY
        var shortRunway: [Bool] = []
        var turns = 0
        var cost = 0
        for (position, row) in rows.enumerated() {
            guard row.minY.isFinite, row.maxY.isFinite, row.maxY >= row.minY else {
                Self.reject("invalid row dimensions at \(position): \(row.minY)...\(row.maxY)")
                return nil
            }
            guard row.minY >= previousEnd else {
                Self.reject("overlapping row at \(position): \(row.minY) < \(previousEnd)")
                return nil
            }
            guard row.maxY <= bounds.maxY else {
                Self.reject("row exceeds document at \(position): \(row.maxY) > \(bounds.maxY), top \(bounds.minY), height \(bounds.height)")
                return nil
            }
            guard row.mountCost >= 0 else {
                Self.reject("negative row budget at \(position)")
                return nil
            }
            guard positions[row.id] == nil else {
                Self.reject("duplicate row identity")
                return nil
            }
            shortRunway.append(TranscriptRow.runwayIsShort(turns: turns, cost: cost))
            turns += row.startsTurn ? 1 : 0
            let (nextCost, overflow) = cost.addingReportingOverflow(row.mountCost)
            guard !overflow else {
                Self.reject("row budget overflow")
                return nil
            }
            cost = nextCost
            positions[row.id] = position
            previousEnd = row.maxY
        }
        self.rows = rows
        self.positions = positions
        self.shortRunway = shortRunway
        latestEnd = rows.last(where: { $0.role != .bottom })?.maxY
    }

    private static func reject(_ reason: String) {
        PerfBuild.count("native.indexRejected")
        logger.error("Rejected transcript placement: \(reason, privacy: .public)")
    }

    struct Visibility {
        let ids: Set<String>
        let isRunwayShort: Bool?
    }

    func visibility(in viewport: CGRect) -> Visibility {
        var ids: Set<String> = []
        var isRunwayShort: Bool?
        for position in intersecting(viewport).indices {
            let row = rows[position]
            guard row.role != .bottom else { continue }
            let intersection = min(row.maxY, viewport.maxY) - max(row.minY, viewport.minY)
            if intersection > 0, intersection >= 0.01 * min(row.maxY - row.minY, viewport.height) {
                if isRunwayShort == nil { isRunwayShort = shortRunway[position] }
                ids.insert(row.id)
            }
        }
        return Visibility(ids: ids, isRunwayShort: isRunwayShort)
    }

    func preservationAnchor(in viewport: CGRect, among hostedIDs: Set<String>, layout: TranscriptReadingLayout?) -> PreservationAnchor? {
        guard viewport.height > 0 else { return nil }
        let visible = intersecting(viewport).filter { hostedIDs.contains($0.id) }
        guard let row = visible.first(where: { $0.role == .reading && $0.maxY > $0.minY })
                ?? visible.first(where: { $0.role != .bottom && $0.maxY > $0.minY }) else { return nil }
        return PreservationAnchor(rowID: row.id,
            frame: CGRect(x: viewport.minX, y: row.minY, width: viewport.width, height: row.maxY - row.minY),
            viewport: viewport, layout: layout)
    }

    func origin(preserving anchor: PreservationAnchor, viewport: CGRect) -> CGFloat? {
        guard let position = positions[anchor.rowID] else { return nil }
        let row = rows[position]
        return anchor.origin(rowMinY: row.minY, viewportHeight: viewport.height)
    }

    func origin(restoring anchor: PreservationAnchor, viewport: CGRect, layout: TranscriptReadingLayout) -> CGFloat? {
        guard let position = positions[anchor.rowID] else { return nil }
        let row = rows[position]
        return anchor.restoredOrigin(in: CGRect(x: 0, y: row.minY, width: layout.columnWidth, height: row.maxY - row.minY),
            viewport: viewport, layout: layout)
    }

    func origin(reflowing anchor: PreservationAnchor, viewport: CGRect) -> CGFloat? {
        guard let position = positions[anchor.rowID] else { return nil }
        let row = rows[position]
        return row.minY + anchor.rowFraction * (row.maxY - row.minY) - anchor.viewportFraction * viewport.height
    }

    func origin(for id: String, anchor: UnitPoint?, viewport: CGRect) -> CGFloat? {
        guard let position = positions[id] else { return nil }
        let row = rows[position]
        if let anchor { return row.minY + anchor.y * (row.maxY - row.minY - viewport.height) }
        if row.minY < viewport.minY { return row.minY }
        if row.maxY > viewport.maxY { return max(row.minY, row.maxY - viewport.height) }
        return viewport.minY
    }

    func row(for id: String) -> Row? { positions[id].map { rows[$0] } }
    func rows(in viewport: CGRect) -> ArraySlice<Row> { intersecting(viewport) }

    func rowID(at y: CGFloat) -> String? {
        let position = firstRow(endingAfter: y)
        guard position < rows.count, rows[position].minY <= y, rows[position].role != .bottom else { return nil }
        return rows[position].id
    }

    private func firstRow(endingAfter y: CGFloat) -> Int {
        var lower = 0
        var upper = rows.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if rows[middle].maxY <= y { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }

    private func intersecting(_ viewport: CGRect) -> ArraySlice<Row> {
        let start = firstRow(endingAfter: viewport.minY)
        var end = start
        while end < rows.count, rows[end].minY < viewport.maxY { end += 1 }
        return rows[start..<end]
    }
}
#endif
