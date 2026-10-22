import Foundation
import Testing
@testable import RemoteCoder

struct RemoteCoderDeepLinksTests {
    private let hostID = UUID()
    private let accountID = UUID()

    @Test func legacyEnrollmentLinksResolveToTheirHostAndThread() throws {
        let link = RemoteCoderConversationLink(hostID: hostID, threadID: "thread/1 a")
        let url = RemoteCoderDeepLinks.url(for: link)
        #expect(RemoteCoderDeepLinks.conversation(from: url) == link)
        var components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        components.queryItems?.append(URLQueryItem(name: "account", value: accountID.uuidString))
        #expect(RemoteCoderDeepLinks.conversation(from: try #require(components.url)) == link)
    }

    @Test func aVoiceCallLinkPresentsOnlyThatCall() {
        let callID = UUID()
        let url = RemoteCoderDeepLinks.url(forVoiceCall: callID)
        #expect(ExternalEvent(url: url) == .presentVoiceCall(callID))
        #expect(RemoteCoderDeepLinks.request(from: url) == nil)
    }

    @Test func aLinkWithoutAHostOrThreadIsNotAConversation() {
        #expect(RemoteCoderDeepLinks.conversation(from: RemoteCoderDeepLinks.openApp) == nil)
        #expect(RemoteCoderDeepLinks.conversation(from: URL(string: "remotecoder://chat/conversation?host=nope&thread=t")!) == nil)
        #expect(RemoteCoderDeepLinks.conversation(from: URL(string: "remotecoder://chat/conversation?host=\(hostID)")!) == nil)
    }

    @Test func legacyAttentionRowsLinkToOneHostConversation() {
        typealias Attention = RemoteCoderActiveTasksAttributes.ContentState.Attention
        let attributes = RemoteCoderActiveTasksAttributes(startedAt: .distantPast, hostID: hostID, hostName: "Mini")
        let rows = [nil, accountID].map { account in
            Attention(threadID: "same-thread", accountID: account, title: "Result", reason: .finishedUnread,
                      completedAtUnixSeconds: 20)
        }
        #expect(Set(rows.map(\.id)).count == 1)
        #expect(rows.map { attributes.url(for: $0).flatMap(RemoteCoderDeepLinks.conversation(from:)) } == [
            RemoteCoderConversationLink(hostID: hostID, threadID: "same-thread"),
            RemoteCoderConversationLink(hostID: hostID, threadID: "same-thread"),
        ])
    }

    @Test func aTapOpensTheLeadAttentionRowElseTheApp() {
        typealias State = RemoteCoderActiveTasksAttributes.ContentState
        func state(_ attention: [State.Attention]?) -> State {
            State(activeTaskCount: 1, attention: attention, attentionCount: attention?.count, updatedAtUnixSeconds: 0)
        }
        let attributes = RemoteCoderActiveTasksAttributes(startedAt: .distantPast, hostID: hostID, hostName: "Mini")
        let lead = State.Attention(threadID: "lead", accountID: accountID, title: nil, reason: .question,
                                   completedAtUnixSeconds: nil)
        let next = State.Attention(threadID: "next", accountID: nil, title: nil, reason: .finishedUnread,
                                   completedAtUnixSeconds: 10)

        #expect(RemoteCoderDeepLinks.conversation(from: attributes.tapURL(for: state([lead, next])))
            == RemoteCoderConversationLink(hostID: hostID, threadID: "lead"))
        #expect(attributes.tapURL(for: state(nil)) == RemoteCoderDeepLinks.openApp)
        #expect(attributes.tapURL(for: state([])) == RemoteCoderDeepLinks.openApp)
        #expect(RemoteCoderActiveTasksAttributes(startedAt: .distantPast, hostID: nil, hostName: nil)
            .tapURL(for: state([lead])) == RemoteCoderDeepLinks.openApp)
    }
}
