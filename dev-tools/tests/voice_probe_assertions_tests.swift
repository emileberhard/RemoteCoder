import Foundation

@main
struct VoiceProbeAssertionTests {
    static func main() {
        var failures: [String] = []
        func expect(_ condition: Bool, _ name: String) {
            if !condition { failures.append(name) }
        }
        func throwsMissingMedia(_ body: () throws -> Void, containing text: String) -> Bool {
            do { try body() } catch RealtimeProbeError.missingMedia(let message) {
                return message.contains(text)
            } catch { return false }
            return false
        }
        let handoff: [String: Any] = ["item": ["type": "handoff_request"]]
        func command(status: String, exitCode: Int?) -> [String: Any] {
            var item: [String: Any] = ["type": "commandExecution", "status": status]
            if let exitCode { item["exitCode"] = exitCode }
            return ["item": item]
        }
        func completed(_ status: String?, error: String? = nil) -> [String: Any] {
            var turn: [String: Any] = [:]
            if let status { turn["status"] = status }
            if let error { turn["error"] = ["message": error] }
            return ["turn": turn]
        }
        func delegation() throws -> DelegationTally {
            var tally = DelegationTally()
            _ = try tally.record(method: "thread/realtime/itemAdded", params: handoff)
            _ = try tally.record(method: "turn/started", params: [:])
            return tally
        }

        do {
            var tally = try delegation()
            expect(try tally.record(method: "item/completed", params: command(status: "completed", exitCode: 0)) == .commandSucceeded, "zero exit counts")
            expect(try tally.record(method: "turn/completed", params: completed("completed")) == .agentCompleted, "completed turn counts")
            try tally.verifyDelegation(heardAssistantAfterAgentCompletion: true)
        } catch {
            failures.append("successful delegation passes: \(error.localizedDescription)")
        }

        do {
            var tally = try delegation()
            expect(try tally.record(method: "item/completed", params: command(status: "failed", exitCode: 1)) == .commandFailed, "failed command is failed")
            expect(try tally.record(method: "item/completed", params: command(status: "completed", exitCode: nil)) == .commandFailed, "unknown exit code is not success")
            expect(try tally.record(method: "turn/completed", params: completed("completed")) == .agentCompleted, "turn still completes")
            expect(
                throwsMissingMedia({ try tally.verifyDelegation(heardAssistantAfterAgentCompletion: true) }, containing: "no successful command (2 failed)"),
                "no successful command fails delegation"
            )
        } catch {
            failures.append("failed commands: \(error.localizedDescription)")
        }

        for (status, detail, fragment) in [
            ("failed" as String?, "boom" as String?, "ended failed: boom"),
            ("interrupted", nil, "ended interrupted"),
            (nil, nil, "ended with no status"),
        ] {
            do {
                var tally = try delegation()
                expect(
                    throwsMissingMedia({ _ = try tally.record(method: "turn/completed", params: completed(status, error: detail)) }, containing: fragment),
                    "turn \(status ?? "without status") fails the probe"
                )
            } catch {
                failures.append("turn setup: \(error.localizedDescription)")
            }
        }

        do {
            var tally = DelegationTally()
            expect(try tally.record(method: "turn/completed", params: completed("failed")) == nil, "a completion before any handoff is ignored")
        } catch {
            failures.append("completion before handoff: \(error.localizedDescription)")
        }

        do {
            var tally = try delegation()
            _ = try tally.record(method: "turn/started", params: [:])
            expect(throwsMissingMedia({ try tally.verifyDelegation(heardAssistantAfterAgentCompletion: true) }, containing: "2 delegated agent turns"), "two turns fail")
            var duplicate = try delegation()
            _ = try duplicate.record(method: "thread/realtime/itemAdded", params: handoff)
            expect(throwsMissingMedia({ try duplicate.verifyDelegation(heardAssistantAfterAgentCompletion: true) }, containing: "2 handoff notifications"), "two handoffs fail")
        } catch {
            failures.append("counts: \(error.localizedDescription)")
        }

        expect(
            isMissingRollout(RealtimeProbeError.rpc(method: "thread/archive", message: "no rollout found for thread id abc")),
            "missing rollout on archive is the benign case"
        )
        expect(
            !isMissingRollout(RealtimeProbeError.rpc(method: "thread/archive", message: "permission denied")),
            "other archive failures are cleanup failures"
        )
        expect(
            !isMissingRollout(RealtimeProbeError.rpc(method: "thread/read", message: "no rollout found for thread id abc")),
            "only archive may report a missing rollout"
        )
        expect(!isMissingRollout(RealtimeProbeError.timedOut("thread/archive")), "a timeout is not a missing rollout")

        do {
            let normal = try RealtimeProbeOptions(arguments: [])
            expect(try normal.gatewayURL(port: "8787").absoluteString == "ws://127.0.0.1:8787/ws", "default has no account query")
            expect(try normal.workingDirectory(homeDirectory: "/home/developer") == "/home/developer", "cwd uses the gateway home")
            let overridden = try RealtimeProbeOptions(arguments: ["--cwd", "/workspace"])
            expect(try overridden.workingDirectory(homeDirectory: "/home/developer") == "/workspace", "explicit cwd wins")
            let claude = try RealtimeProbeOptions(arguments: ["--claude", "--fixture", "/fixture.mp3"])
            expect(claude.handoffMode && claude.mediaMode, "Claude uses the host default")
            let context = try RealtimeProbeOptions(arguments: ["--handoff", "--resume-context", "--fixture", "/fixture.mp3"])
            expect(context.contextMode && !context.handoffMode, "resume context overrides delegation")
        } catch {
            failures.append("valid probe options: \(error.localizedDescription)")
        }

        guard failures.isEmpty else {
            for failure in failures { FileHandle.standardError.write(Data("FAIL \(failure)\n".utf8)) }
            exit(1)
        }
    }
}
