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
        components.path = "/conversation"
        components.queryItems?.append(URLQueryItem(name: "account", value: accountID.uuidString))
        #expect(RemoteCoderDeepLinks.conversation(from: try #require(components.url)) == link)
    }

    @Test func aSearchLinkRoundTripsItsExactItemKeyAndRejectsDuplicateIdentities() throws {
        let itemKey = "host:claude:home:thread@item:1/2 & 3"
        let link = RemoteCoderConversationLink(hostID: hostID, threadID: "thread/1 a", itemKey: itemKey)
        let url = RemoteCoderDeepLinks.url(for: link)
        #expect(url.path == "/open")
        #expect(ExternalEvent(url: url) == .open(.conversation(.init(hostID: hostID, threadID: link.threadID)),
            opening: .init(itemKey: itemKey, findTerm: nil)))
        var components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        components.queryItems?.append(URLQueryItem(name: "host", value: UUID().uuidString))
        #expect(ExternalEvent(url: try #require(components.url)) == nil)
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

    @Test func attentionRowsLinkToTheirOwnHostConversation() {
        typealias Attention = RemoteCoderActiveTasksAttributes.ContentState.Attention
        let otherHostID = UUID()
        let attributes = RemoteCoderActiveTasksAttributes(startedAt: .distantPast, coordinatorID: nil)
        let rows = [hostID, otherHostID].map { host in
            Attention(hostID: host, threadID: "same-thread", title: "Result", reason: .finishedUnread,
                      completedAtUnixSeconds: 20)
        }
        #expect(Set(rows.map(\.id)).count == 2)
        #expect(rows.map { attributes.url(for: $0).flatMap(RemoteCoderDeepLinks.conversation(from:)) } == [
            RemoteCoderConversationLink(hostID: hostID, threadID: "same-thread"),
            RemoteCoderConversationLink(hostID: otherHostID, threadID: "same-thread"),
        ])
    }

    @Test func aTapOpensTheLeadAttentionRowElseTheApp() {
        typealias State = RemoteCoderActiveTasksAttributes.ContentState
        func state(_ attention: [State.Attention]?) -> State {
            State(activeTaskCount: 1, attention: attention, attentionCount: attention?.count, unavailableHostIDs: nil,
                  updatedAtUnixSeconds: 0)
        }
        let attributes = RemoteCoderActiveTasksAttributes(startedAt: .distantPast, coordinatorID: nil)
        let lead = State.Attention(hostID: hostID, threadID: "lead", title: nil, reason: .question,
                                   completedAtUnixSeconds: nil)
        let next = State.Attention(hostID: hostID, threadID: "next", title: nil, reason: .finishedUnread,
                                   completedAtUnixSeconds: 10)
        let hostless = State.Attention(hostID: nil, threadID: "lead", title: nil, reason: .question,
                                       completedAtUnixSeconds: nil)

        #expect(RemoteCoderDeepLinks.conversation(from: attributes.tapURL(for: state([lead, next])))
            == RemoteCoderConversationLink(hostID: hostID, threadID: "lead"))
        #expect(attributes.tapURL(for: state(nil)) == RemoteCoderDeepLinks.openApp)
        #expect(attributes.tapURL(for: state([])) == RemoteCoderDeepLinks.openApp)
        #expect(attributes.tapURL(for: state([hostless])) == RemoteCoderDeepLinks.openApp)
    }
}
