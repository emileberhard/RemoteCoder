#if RC_PERF_HARNESS
import Foundation
import os

/// Records every notification frame the gateway client receives, with its
/// arrival offset, so a real turn can be replayed deterministically later.
final class PerfFrameRecorder: Sendable {
    static let shared = PerfFrameRecorder()
    private static let byteBudget = 32 * 1_048_576

    enum RecordingError: Error {
        case exceededByteBudget
        case notStarted
    }

    private struct State {
        var start: ContinuousClock.Instant?
        var frames: [(Double, String)] = []
        var bytes = 0
        var exceededBudget = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func start() {
        state.withLock { $0 = State(start: .now) }
    }

    func record(_ text: String) {
        state.withLock { state in
            guard let start = state.start, !state.exceededBudget else { return }
            state.bytes += text.utf8.count
            guard state.bytes <= Self.byteBudget else {
                state.exceededBudget = true
                state.frames = []
                return
            }
            let offset = start.duration(to: .now)
            state.frames.append((Double(offset.components.seconds) + Double(offset.components.attoseconds) / 1e18, text))
        }
    }

    func stop(writingTo url: URL) -> Result<Int, any Error> {
        let recorded = state.withLock { state -> State in
            defer { state = State() }
            return state
        }
        guard recorded.start != nil else { return .failure(RecordingError.notStarted) }
        guard !recorded.exceededBudget else { return .failure(RecordingError.exceededByteBudget) }
        var output = Data()
        for (offset, text) in recorded.frames {
            guard let line = try? JSONSerialization.data(withJSONObject: ["t": offset, "raw": text]) else { continue }
            output.append(line)
            output.append(0x0A)
        }
        return Result { try output.write(to: url) }.map { recorded.frames.count }
    }
}

/// A recorded frame rewritten onto the conversation being measured: the source
/// thread becomes the open thread, and turn and item ids get a fresh suffix so
/// repeated replays create new turns instead of merging into earlier ones.
struct PerfReplayFrame: Sendable {
    let offset: Double
    let text: String

    @concurrent
    static func load(_ url: URL, targetThread: String, suffix: String) async throws -> [PerfReplayFrame] {
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        var recorded: [(Double, String, [String: Any])] = []
        for line in lines {
            guard let entry = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let offset = entry["t"] as? Double, let raw = entry["raw"] as? String,
                  let frame = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { continue }
            recorded.append((offset, raw, frame))
        }
        guard let first = recorded.first(where: { ($0.2["method"] as? String) == "turn/started" }),
              let params = first.2["params"] as? [String: Any],
              let sourceThread = params["threadId"] as? String else { return [] }
        var turnIDs = Set<String>()
        var itemIDs = Set<String>()
        var selected: [(Double, String)] = []
        for (offset, raw, frame) in recorded where offset >= first.0 {
            let method = frame["method"] as? String ?? ""
            let params = frame["params"] as? [String: Any] ?? [:]
            if method == "daemon/activeTurns/changed" {
                guard raw.contains(sourceThread) else { continue }
            } else if (params["threadId"] as? String) != sourceThread {
                continue
            }
            if let turn = params["turn"] as? [String: Any], let id = turn["id"] as? String { turnIDs.insert(id) }
            if let id = params["turnId"] as? String { turnIDs.insert(id) }
            if let item = params["item"] as? [String: Any], let id = item["id"] as? String { itemIDs.insert(id) }
            if let id = params["itemId"] as? String { itemIDs.insert(id) }
            selected.append((offset - first.0, raw))
        }
        let replacements = [("\"\(sourceThread)\"", "\"\(targetThread)\"")]
            + turnIDs.map { ("\"\($0)\"", "\"\($0)\(suffix)\"") }
            + itemIDs.map { ("\"\($0)\"", "\"\($0)\(suffix)\"") }
        let sequence = try Regex(#","rcSequence":\d+|"rcSequence":\d+,"#)
        return selected.map { offset, raw in
            var text = raw.replacing(sequence, with: "")
            for (from, to) in replacements { text = text.replacing(from, with: to) }
            return PerfReplayFrame(offset: offset, text: text)
        }
    }
}
#endif
