enum DispatchPolicy {
    static let approvalPolicy = "never"
    static let threadSandbox = "danger-full-access"
    static let turnSandbox = JSONValue.object(["type": .string("dangerFullAccess")])
    static let reasoningSummary = CodexAppServerV2.ReasoningSummary.detailed

    static let declineReplies: [String: JSONValue] = [
        "item/commandExecution/requestApproval": .object(["decision": .string("decline")]),
        "item/fileChange/requestApproval": .object(["decision": .string("decline")]),
        "item/permissions/requestApproval": .object([
            "permissions": .object([:]),
            "scope": .string("turn"),
        ]),
        "item/tool/call": .object([
            "contentItems": .array([]),
            "success": .bool(false),
        ]),
    ]
}
