import Foundation
import Testing
@testable import RemoteCoderCore

struct GatewayFrameDecoderTests {
    @Test func subscriptionDeliveryPreservesWireIntegersAndTheObservationReceipt() async throws {
        let wire = Data(#"{"id":7,"result":{"status":"subscribed","subscriptionId":"sub","thread":{"id":"thread","preview":"","createdAt":9007199254740993,"updatedAt":1,"cwd":"/tmp","source":"cli"},"checkpoint":{"historyUnavailable":false,"liveItems":[]}}}"#.utf8)
        let receipt = GatewayWireReceipt(connection: UUID(), sequence: 42)
        let delivered: (Data, GatewayWireReceipt) = try await withCheckedThrowingContinuation { continuation in
            let request = PendingGatewayRequest(completion: .observed(continuation), timeoutTask: Task {},
                method: "thread/subscribe", startedAt: .now)
            var table = RequestTable()
            table.insert(request, id: 7)
            #expect(table.rawResponseIDs == [7])
            table.remove(id: 7)?.succeed(raw: wire, receipt: receipt)
        }
        #expect(delivered.0 == wire)
        #expect(delivered.1 == receipt)
        let decoded = try await GatewayFrameDecoder.decodeResult(CodexAppServerV2.ThreadSubscribeResponse.self,
            from: delivered.0, dateDecodingStrategy: .deferredToDate)
        guard case .subscribed(let handle, let thread, _) = decoded else {
            Issue.record("Lost subscription response")
            return
        }
        #expect(handle == "sub")
        #expect(thread.createdAt == 9_007_199_254_740_993)
    }

    @Test func aRawSubscriptionDecodedAfterRequestTimeoutStillExposesItsCleanupHandle() async throws {
        let wire = Data(#"{"id":7,"result":{"status":"subscribed","subscriptionId":"late","thread":{},"checkpoint":{}}}"#.utf8)
        var table = RequestTable()
        let expired: (Data, GatewayWireReceipt)? = try? await withCheckedThrowingContinuation { continuation in
            table.insert(.init(completion: .observed(continuation), timeoutTask: Task {},
                method: "thread/subscribe", startedAt: .now), id: 7)
            table.remove(id: 7)?.fail(GatewayClient.ClientError.requestTimedOut(method: "thread/subscribe"))
        }
        #expect(expired == nil)
        let frame = try await GatewayFrameDecoder.decode(wire, rawResponseIDs: [7])
        guard case .rawResponse(let id, let data) = frame else { Issue.record("Expected captured raw reply"); return }
        #expect(table.remove(id: id) == nil)
        #expect(await GatewayFrameDecoder.subscriptionHandle(from: data) == "late")
    }

    @Test func malformedFramesReportTheirDecodeBoundaryWithBoundedRedactedBytes() async throws {
        let binary = try #require(#"{"id":{},"x":"\"{}[]:, "}"#.data(using: .utf16LittleEndian))
        do {
            _ = try await GatewayFrameDecoder.decode(binary, rawResponseIDs: [])
            Issue.record("Malformed binary frame must fail decoding")
        } catch let failure as GatewayFrameDecoder.Failure {
            #expect(failure.prefix == String(repeating: "_", count: min(64, binary.count)))
        }
        for (text, stage) in [
            ("{\"id\":{},\"token\":\"private-secret\"}", GatewayFrameDecoder.DecodePath.header),
            ("{\"token\":\"private-secret\",\"padding\":\"" + String(repeating: "a", count: 256) + "\"}", .envelope),
            ("not-json private-secret\n" + String(repeating: "a", count: 256), .header),
        ] {
            do {
                _ = try await GatewayFrameDecoder.decode(Data(text.utf8), rawResponseIDs: [])
                Issue.record("Malformed gateway frame must fail decoding")
            } catch let failure as GatewayFrameDecoder.Failure {
                #expect(failure.decodePath == stage)
                #expect(failure.kind == "dataCorrupted")
                #expect(failure.prefix.utf8.count <= 64)
                #expect(!failure.prefix.contains("private-secret"))
                #expect(failure.prefix.allSatisfy { "_{}[]:,\" ".contains($0) })
            }
        }
    }

    @Test func decodeDiagnosticsExcludeResponseContentAndUnderlyingErrorText() {
        let diagnostic = GatewayFrameDecoder.diagnostic(.dataCorrupted(.init(
            codingPath: [], debugDescription: "private response contents",
            underlyingError: NSError(domain: "private token", code: 3840))))
        #expect(diagnostic.kind == "dataCorrupted")
        #expect(diagnostic.path.isEmpty)
    }
    @Test func largeNativeResponseRetainsWireBytesWithoutJSONValueRoundTrip() async throws {
        let data = Data(("{\"id\":7,\"result\":{\"data\":[],\"padding\":\"" + String(repeating: "x", count: 17 * 1024 * 1024) + "\"}}").utf8)
        let frame = try await GatewayFrameDecoder.decode(data, rawResponseIDs: [7])
        guard case .rawResponse(let id, let bytes) = frame else { Issue.record("Expected raw native response"); return }
        #expect(id == 7)
        #expect(bytes == data)
    }

    @Test func rawRequestIdentityNeverConsumesServerRequestsOrErrors() async throws {
        let request = try await GatewayFrameDecoder.decode(Data(#"{"id":7,"method":"item/tool/call","params":{}}"#.utf8), rawResponseIDs: [7])
        guard case .request = request else { Issue.record("Lost server request"); return }
        let error = try await GatewayFrameDecoder.decode(Data(#"{"id":7,"error":{"code":-32003,"message":"too large"}}"#.utf8), rawResponseIDs: [7])
        guard case .error(let failure) = error else { Issue.record("Lost request-local error"); return }
        #expect(failure.error.code == -32003)
    }

    @Test func typedResultDecodesFromTheWholeFrameWithTheCallersDateStrategy() async throws {
        struct Stamp: Decodable, Sendable { let at: Date }
        let data = Data(#"{"id":3,"result":{"at":1000}}"#.utf8)
        let stamp = try await GatewayFrameDecoder.decodeResult(Stamp.self, from: data, dateDecodingStrategy: .secondsSince1970)
        #expect(stamp.at == Date(timeIntervalSince1970: 1000))
    }

    @Test func carriesGatewayNotificationSequenceAlongsideTheMessage() async throws {
        let data = Data(#"{"method":"turn/completed","rcSequence":17,"params":{"threadId":"thread-1","turnId":"turn-1"}}"#.utf8)
        let frame = try await GatewayFrameDecoder.decode(data, rawResponseIDs: [])

        guard case .notification(let notification, let server, let sequence) = frame else {
            Issue.record("Expected a stamped gateway notification")
            return
        }
        #expect(notification.method == "turn/completed")
        #expect(sequence == 17)
        guard case .turnCompleted(let completion) = server else { Issue.record("Expected a typed completion"); return }
        #expect(completion.address == .init(threadID: "thread-1", turnID: "turn-1"))
    }
}
