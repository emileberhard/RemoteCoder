import Foundation
import Testing

@testable import RemoteCoderCore

struct CodexRequestShapeFixtureTests {
    private static let tiers: [(CodexAppServerV2.ServiceTierOverride?, String)] = [
        (nil, ""),
        (.clear, #","serviceTier":null"#),
        (.set(.fast), #","serviceTier":"fast""#),
    ]

    @Test(arguments: CodexRequestShapeFixtureTests.tiers)
    func turnStartKeepsItsRequestShape(tier: CodexAppServerV2.ServiceTierOverride?, tierField: String) throws {
        let request = CodexAppServerV2.TurnStartParams(
            threadId: "thread-1", input: [.text(text: "hello", textElements: [])],
            cwd: "/repo", approvalPolicy: DispatchPolicy.approvalPolicy, sandboxPolicy: DispatchPolicy.turnSandbox,
            model: "gpt", cyberAccessProgram: nil, effort: .high, serviceTier: tier, additionalContext: nil, clientUserMessageId: "message-1"
        )
        try expectShape(request, #"""
            {"threadId":"thread-1","input":[{"type":"text","text":"hello"}],"cwd":"/repo","approvalPolicy":"never",\#
            "sandboxPolicy":{"type":"dangerFullAccess"},"model":"gpt","effort":"high","summary":"detailed",\#
            "clientUserMessageId":"message-1"\#(tierField)}
            """#)
    }

    @Test(arguments: CodexRequestShapeFixtureTests.tiers)
    func threadStartKeepsItsRequestShape(tier: CodexAppServerV2.ServiceTierOverride?, tierField: String) throws {
        let request = CodexAppServerV2.ThreadStartParams(
            model: "gpt", cwd: "/repo", approvalPolicy: DispatchPolicy.approvalPolicy,
            sandbox: DispatchPolicy.threadSandbox, serviceName: "RemoteCoder", serviceTier: tier, config: nil
        )
        try expectShape(request, #"""
            {"model":"gpt","cwd":"/repo","approvalPolicy":"never","sandbox":"danger-full-access",\#
            "persistExtendedHistory":true,"serviceName":"RemoteCoder"\#(tierField)}
            """#)
    }

    @Test
    func threadStartOmitsAnUnsetWorkingDirectory() throws {
        let request = CodexAppServerV2.ThreadStartParams(
            model: "gpt", cwd: nil, approvalPolicy: DispatchPolicy.approvalPolicy,
            sandbox: DispatchPolicy.threadSandbox, serviceName: "RemoteCoder Voice", serviceTier: nil, config: nil
        )
        try expectShape(request, #"""
            {"model":"gpt","approvalPolicy":"never","sandbox":"danger-full-access",\#
            "persistExtendedHistory":true,"serviceName":"RemoteCoder Voice"}
            """#)
    }

    @Test
    func threadStartCarriesItsInitialReasoningConfig() throws {
        let request = CodexAppServerV2.ThreadStartParams(
            model: "gpt", cwd: "/repo", approvalPolicy: DispatchPolicy.approvalPolicy,
            sandbox: DispatchPolicy.threadSandbox, serviceName: "RemoteCoder Voice", serviceTier: .set(.fast),
            config: .init(modelReasoningEffort: .medium)
        )
        try expectShape(request, #"""
            {"model":"gpt","cwd":"/repo","approvalPolicy":"never","sandbox":"danger-full-access",\#
            "persistExtendedHistory":true,"serviceName":"RemoteCoder Voice","serviceTier":"fast",\#
            "config":{"model_reasoning_effort":"medium","model_reasoning_summary":"detailed"}}
            """#)
    }

    @Test
    func threadResumeKeepsItsRequestShape() throws {
        try expectShape(CodexAppServerV2.ThreadResumeParams(
            threadId: "thread-1", model: "gpt", cwd: nil, approvalPolicy: DispatchPolicy.approvalPolicy,
            sandbox: DispatchPolicy.threadSandbox, serviceTier: .clear
        ), #"""
            {"threadId":"thread-1","model":"gpt","approvalPolicy":"never","sandbox":"danger-full-access",\#
            "serviceTier":null,"persistExtendedHistory":true,"excludeTurns":true}
            """#)
    }

    @Test
    func threadForkKeepsItsRequestShape() throws {
        try expectShape(CodexAppServerV2.ThreadForkParams(threadId: "thread-1", lastTurnId: nil, serviceTier: nil),
            #"{"threadId":"thread-1","threadSource":"user","persistExtendedHistory":true,"excludeTurns":true}"#)
        try expectShape(CodexAppServerV2.ThreadForkParams(threadId: "thread-1", lastTurnId: "turn-1", serviceTier: .set(.fast)),
            #"{"threadId":"thread-1","lastTurnId":"turn-1","serviceTier":"fast","threadSource":"user","persistExtendedHistory":true,"excludeTurns":true}"#)
    }

    @Test
    func otherRequestsKeepTheirShapes() throws {
        try expectShape(CodexAppServerV2.ModelListParams(cursor: "next"),
            #"{"cursor":"next","includeHidden":true}"#)
        try expectShape(CodexAppServerV2.ModelListParams(cursor: nil), #"{"includeHidden":true}"#)
        try expectShape(CodexAppServerV2.FsReadDirectoryParams(path: "/repo"),
            #"{"path":"/repo"}"#)
        try expectShape(CodexAppServerV2.CommandExecParams(command: ["pwd"], cwd: "/repo"),
            #"{"command":["pwd"],"cwd":"/repo"}"#)
        try expectShape(CodexAppServerV2.ThreadListParams(cursor: nil, limit: 50, useStateDbOnly: false),
            #"{"limit":50,"sortKey":"updated_at","useStateDbOnly":false,"includeCompletionTimes":true,"boundedPreview":true}"#)
        try expectShape(CodexAppServerV2.ThreadListParams(cursor: "c", limit: 200, useStateDbOnly: true),
            #"{"cursor":"c","limit":200,"sortKey":"updated_at","useStateDbOnly":true,"includeCompletionTimes":true,"boundedPreview":true}"#)
        try expectShape(CodexAppServerV2.ThreadReadParams(threadId: "thread-1", includeTurns: false),
            #"{"threadId":"thread-1","includeTurns":false}"#)
        try expectShape(CodexAppServerV2.TurnSteerParams(
            threadId: "thread-1", input: [.text(text: "hello", textElements: [])],
            expectedTurnId: "turn-1", additionalContext: nil, clientUserMessageId: nil
        ), #"{"threadId":"thread-1","input":[{"type":"text","text":"hello"}],"expectedTurnId":"turn-1"}"#)
        try expectShape(CodexAppServerV2.TurnInterruptParams(threadId: "thread-1", turnId: "turn-1"),
            #"{"threadId":"thread-1","turnId":"turn-1"}"#)
    }

    private func expectShape<T: Encodable>(_ request: T, _ fixture: String) throws {
        let decoder = JSONDecoder()
        let expected = try decoder.decode(JSONValue.self, from: Data(fixture.utf8))
        let encoded = try decoder.decode(JSONValue.self, from: JSONEncoder().encode(request))
        #expect(encoded == expected)
    }
}
