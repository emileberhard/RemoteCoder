import Foundation
import Testing

@testable import RemoteCoderCore

struct RealtimeVoiceProtocolTests {
    @Test func errorNotificationRequiresAnExplicitFalseToKeepTheSessionOpen() throws {
        let cases: [(JSONValue?, Bool?, Bool)] = [
            (nil, nil, true), (.null, nil, true),
            (.bool(true), true, true), (.bool(false), false, false),
        ]
        for (terminal, retained, endsSession) in cases {
            var params: [String: JSONValue] = [
                "threadId": .string("thread-1"),
                "message": .string("Provider diagnostic"),
                "providerError": .object(["code": .string("provider_code")]),
            ]
            params["terminal"] = terminal
            let notification = GatewayEventFixture.notification(
                method: "thread/realtime/error", params: .object(params)
            )
            let decoded = try #require(try RealtimeVoiceNotification(notification))
            guard case .error(let event) = decoded else {
                Issue.record("Expected a realtime error")
                return
            }
            #expect(event.threadID == "thread-1")
            #expect(event.message == "Provider diagnostic")
            #expect(event.isTerminal == endsSession)
            #expect(event.terminal == retained)
        }
    }

    @Test func closedNotificationPreservesReasonsAndOnlyRecoversLegacyTransportLoss() throws {
        let cases: [(String?, RealtimeVoiceLifecycle.State)] = [
            ("requested", .idle),
            ("close_requested", .idle),
            ("remote_hangup", .idle),
            ("expired", .failed("The voice session expired.")),
            ("content", .failed("The voice session was closed by the provider.")),
            ("connection_lost", .failed("The voice connection was lost.")),
            ("transport_closed", .reconnecting),
            ("error", .failed("The voice session closed unexpectedly.")),
            ("future_reason", .failed("The voice session closed unexpectedly.")),
            (nil, .failed("The voice session closed unexpectedly.")),
        ]
        for (reason, nextState) in cases {
            var params: [String: JSONValue] = ["threadId": .string("thread-1")]
            params["reason"] = reason.map(JSONValue.string)
            let notification = GatewayEventFixture.notification(
                method: "thread/realtime/closed", params: .object(params)
            )
            let decoded = try #require(try RealtimeVoiceNotification(notification))
            guard case .closed(let event) = decoded else {
                Issue.record("Expected a realtime closure")
                return
            }
            #expect(event.reason == reason)
            #expect(RealtimeVoiceLifecycle.stateAfterClosure(reason: event.reason, providerClosed: event.providerClosed == true) == nextState)
        }
        let nullReason = try JSONDecoder().decode(
            RealtimeVoiceClosedNotification.self,
            from: Data(#"{"threadId":"thread-1","reason":null}"#.utf8)
        )
        #expect(nullReason.reason == nil)
        #expect(RealtimeVoiceLifecycle.stateAfterClosure(reason: nullReason.reason, providerClosed: nullReason.providerClosed == true) == .failed("The voice session closed unexpectedly."))
    }

    @Test func providerClosureProvenanceOverridesReservedLegacyReasons() throws {
        let cases: [(String, RealtimeVoiceLifecycle.State, RealtimeVoiceLifecycle.State)] = [
            ("requested", .idle, .failed("The voice session closed unexpectedly.")),
            ("transport_closed", .reconnecting, .failed("The voice session closed unexpectedly.")),
            ("error", .failed("The voice session closed unexpectedly."), .failed("The voice session closed unexpectedly.")),
            ("close_requested", .idle, .idle),
            ("remote_hangup", .idle, .idle),
        ]
        for (reason, legacyState, providerState) in cases {
            for providerClosed in [nil, false, true] as [Bool?] {
                var params: [String: JSONValue] = [
                    "threadId": .string("thread-1"), "reason": .string(reason),
                ]
                params["providerClosed"] = providerClosed.map(JSONValue.bool)
                let notification = GatewayEventFixture.notification(
                    method: "thread/realtime/closed", params: .object(params)
                )
                let decoded = try #require(try RealtimeVoiceNotification(notification))
                guard case .closed(let event) = decoded else {
                    Issue.record("Expected a realtime closure")
                    return
                }
                #expect(event.reason == reason)
                #expect(event.providerClosed == providerClosed)
                #expect(RealtimeVoiceLifecycle.stateAfterClosure(
                    reason: event.reason, providerClosed: event.providerClosed == true
                ) == (providerClosed == true ? providerState : legacyState))
            }
        }
    }

    @Test func acceptedFutureSettingsCanCarryAnActiveTurnWarning() throws {
        let response = try JSONDecoder().decode(ConversationSettingsUpdateResponse.self, from: Data(
            #"{"status":"nextTurn","warning":"Settings saved for future turns; the running turn could not be updated."}"#.utf8
        ))
        #expect(response.status == .nextTurn)
        #expect(response.warning?.hasPrefix("Settings saved for future turns") == true)
        #expect(response.currentTurnId == nil)
    }

    @Test func startRequestUsesTheGatewayContractExactly() throws {
        let request = RealtimeVoiceStartRequest(
            conversationThreadID: "thread-1",
            realtimeSessionID: "session-1",
            replaceExistingSession: true,
            cwd: "/tmp/project",
            model: "gpt-5.6-luna",
            effort: "medium",
            sdp: "v=0\r\n",
            voice: "cove",
            initialItems: [
                RealtimeVoiceInitialItem(role: .user, text: "Hello"),
            ]
        )

        let data = try JSONEncoder().encode(request)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["conversationThreadId"] as? String == "thread-1")
        #expect(object["realtimeSessionId"] as? String == "session-1")
        #expect(object["replaceExistingSession"] as? Bool == true)
        #expect(object["cwd"] as? String == "/tmp/project")
        #expect(object["model"] as? String == "gpt-5.6-luna")
        #expect(object["effort"] as? String == "medium")
        #expect(object["sdp"] as? String == "v=0\r\n")
        #expect(object["voice"] as? String == "cove")
        let items = try #require(object["initialItems"] as? [[String: Any]])
        #expect(items.count == 1)
        #expect(items[0]["role"] as? String == "user")
        #expect(items[0]["text"] as? String == "Hello")
        #expect(object["conversationThreadID"] == nil)
    }

    @Test func startResponseDecodesTheWireThreadID() throws {
        let response = try JSONDecoder().decode(
            RealtimeVoiceStartResponse.self,
            from: Data(#"{"realtimeThreadId":"thread-2","model":"sonnet","effort":"high"}"#.utf8)
        )

        #expect(response.realtimeThreadID == "thread-2")
    }

    @Test func transcriptNotificationDecodesIntoTypedRoleAndPayload() throws {
        let notification = GatewayEventFixture.notification(
            method: "thread/realtime/transcript/done",
            params: .object([
                "threadId": .string("thread-3"),
                "role": .string("assistant"),
                "text": .string("Hello"),
            ])
        )

        guard let decoded = try RealtimeVoiceNotification(notification) else {
            Issue.record("Expected a realtime voice notification")
            return
        }
        guard case .transcriptDone(let event) = decoded else {
            Issue.record("Expected a typed transcript-done notification")
            return
        }
        #expect(event.threadID == "thread-3")
        #expect(event.role == .assistant)
        #expect(event.text == "Hello")
    }

    @Test func transcriptNotificationRejectsAnUnknownRole() throws {
        let notification = GatewayEventFixture.notification(
            method: "thread/realtime/transcript/done",
            params: .object([
                "threadId": .string("thread-4"),
                "role": .string("system"),
                "text": .string("Hello"),
            ])
        )

        do {
            _ = try RealtimeVoiceNotification(notification)
            Issue.record("Expected the unknown role to fail decoding")
        } catch is DecodingError {
            // Expected: protocol roles are closed and strongly typed.
        }
    }

    @Test func preemptedNotificationCarriesTheLogicalSessionID() throws {
        let notification = GatewayEventFixture.notification(
            method: "voice/session/preempted",
            params: .object([
                "realtimeSessionId": .string("session-1"),
            ])
        )

        let decoded = try #require(try RealtimeVoiceNotification(notification))
        guard case .preempted(let event) = decoded else {
            Issue.record("Expected a typed voice-session-preempted notification")
            return
        }
        #expect(event.realtimeSessionID == "session-1")
    }

    @Test func contextWindowUsageReadsTheLatestRequestNotTheThreadTotal() {
        let threadTotal = CodexAppServerV2.TokenUsageBreakdown(totalTokens: 900_000)
        let latestRequest = CodexAppServerV2.TokenUsageBreakdown(totalTokens: 136_000)
        let usage = CodexAppServerV2.ThreadTokenUsage(
            total: threadTotal,
            last: latestRequest,
            modelContextWindow: 353_000
        )
        let display = ContextWindowUsage(usage)

        #expect(display?.usedTokens == 136_000)
        #expect(display?.availableTokens == 353_000)
        #expect(display?.usedPercent == 39)
    }
}
