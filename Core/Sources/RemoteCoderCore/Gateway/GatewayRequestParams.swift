import Foundation

enum GatewayRequestParams {
    struct Empty: Encodable {}

    struct ThreadReference: Encodable {
        let threadId: String
    }

    struct ThreadResume: Encodable {
        let threadId: String
        let excludeTurns: Bool
    }

    struct Limit: Encodable {
        let limit: Int
    }

    struct Subscription: Encodable {
        let subscriptionId: String
    }

    struct Initialize: Encodable {
        struct ClientInfo: Encodable {
            let name: String
            let title: String
            let version: String
        }
        struct Capabilities: Encodable {
            let experimentalApi: Bool
        }
        let clientInfo: ClientInfo
        let capabilities: Capabilities
    }

    struct ReplayNotifications: Encodable {
        let afterSequence: UInt64
        let epoch: String?
        let threadId: String?
        let limit: Int?
    }

    struct AgentRead: Encodable {
        let threadId: String
        let agentId: String
    }

    struct AgentAction: Encodable {
        let threadId: String
        let agentId: String
        let executionId: String?
        let action: String
        let text: String
        let mutationId: String

        private enum CodingKeys: String, CodingKey {
            case threadId, agentId, executionId, action, text, mutationId
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(threadId, forKey: .threadId)
            try container.encode(agentId, forKey: .agentId)
            try container.encode(executionId, forKey: .executionId)
            try container.encode(action, forKey: .action)
            try container.encode(text, forKey: .text)
            try container.encode(mutationId, forKey: .mutationId)
        }
    }

    struct Device: Encodable {
        let deviceId: String
    }

    struct Call: Encodable {
        let callId: String
    }

    struct CallRinging: Encodable {
        let callId: String
        let deviceId: String
    }

    struct CallAnswer: Encodable {
        let callId: String
        let deviceId: String
        let realtimeSessionId: String
        let sdp: String
        let voice: String?
    }

    struct CallConnected: Encodable {
        let callId: String
        let deviceId: String
        let realtimeSessionId: String
    }

    struct CallEnd: Encodable {
        let callId: String
        let deviceId: String
        let reason: String
    }

    struct VoiceSessionConnected: Encodable {
        let realtimeSessionId: String
    }
}
