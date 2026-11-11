import Foundation
import Synchronization
import Testing
@testable import RemoteCoderCore

@MainActor
struct ConversationSearchSessionTests {
    private let mini = UUID()
    private let book = UUID()
    private let linux = UUID()
    private let clock = ManualClock()
    private let requests = SearchRequests()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theFirstPaintWaitsForTheFirstAnswerAndLandsBothSectionsOrdered() async throws {
        let session = session(hosts: [host(mini, "Mini", headers: [try header("local", "Drawer flicker fix", at: 100)])])
        try await ask(session, "drawer", hosts: 1)
        #expect(!session.results.isPainted)
        #expect(session.results.status.isSearching)

        requests.answer(mini, with: [
            hit("message", on: mini, title: "Sidebar work", excerpt: "the drawer still flickers"),
            hit("newer", on: mini, title: "Drawer polish", titleMatch: true, lastAt: 200),
        ])
        #expect(await waitUntil { session.results.isPainted })
        #expect(ids(session.results.titles) == ["newer", "local"])
        #expect(ids(session.results.messages) == ["message"])
        #expect(session.results.status == ConversationSearchStatus())
        #expect(requests.limits == [ConversationSearchSession.resultLimit])
    }

    @Test func titleMatchesPaintAloneWhenNoHostAnswersInTimeAndLaterAnswersAppend() async throws {
        let session = session(hosts: [
            host(mini, "Mini", headers: [try header("local", "Release notes", at: 100)]),
            host(book, "MacBook"),
        ])
        try await ask(session, "release", hosts: 2)
        clock.advance(by: ConversationSearchSession.firstPaintHold)
        #expect(await waitUntil { session.results.isPainted })
        #expect(ids(session.results.titles) == ["local"])
        #expect(session.results.messages.rows.isEmpty)
        #expect(session.results.status.isSearching)

        requests.answer(book, with: [
            hit("book-title", on: book, title: "Release plan", titleMatch: true, lastAt: 900),
            hit("book-message", on: book, excerpt: "cut the release"),
        ])
        #expect(await waitUntil { session.results.messages.rows.count == 1 })
        requests.answer(mini, with: [hit("mini-message", on: mini, excerpt: "release checklist")])
        #expect(await waitUntil { session.results.messages.rows.count == 2 })
        #expect(ids(session.results.titles) == ["local", "book-title"])
        #expect(ids(session.results.messages) == ["book-message", "mini-message"])
        #expect(!session.results.status.isSearching)
    }

    @Test func aConversationAlreadyListedIsNeverAddedOrMovedAgain() async throws {
        let session = session(hosts: [
            host(mini, "Mini", headers: [try header("local", "Drawer cleanup", at: 100)]),
            host(linux, "Linux"),
        ])
        try await ask(session, "drawer", hosts: 2)
        requests.answer(mini, with: [hit("shared", on: mini, sessionKey: "mini:claude:home:shared", excerpt: "drawer state")])
        #expect(await waitUntil { session.results.isPainted })

        requests.answer(linux, with: [
            hit("shared", on: mini, sessionKey: "mini:claude:home:shared", title: "Drawer state", titleMatch: true),
            hit("local", on: mini, title: "Drawer cleanup", titleMatch: true),
            hit("renamed", on: linux, sessionKey: "mini:claude:home:shared", excerpt: "same session, other address"),
            hit("fresh", on: linux, excerpt: "drawer motion"),
        ])
        #expect(await waitUntil { !session.results.status.isSearching })
        #expect(ids(session.results.titles) == ["local"])
        #expect(ids(session.results.messages) == ["shared", "fresh"])
    }

    @Test func anEmptyTruncatedAnswerKeepsCoverageIncomplete() async throws {
        let decoder = JSONDecoder()
        let partial = try decoder.decode(ConversationSearchResponse.self,
            from: Data(#"{"schemaVersion":1,"truncated":true,"conversations":[]}"#.utf8))
        let session = session(hosts: [host(mini, "Mini")])
        try await ask(session, "drawer", hosts: 1)
        requests.answer(mini, truncated: partial.truncated, with: partial.conversations)
        try #require(await waitUntil { session.results.isPainted && !session.results.status.isSearching })
        #expect(session.results.isEmpty)
        #expect(!session.results.status.isComplete)
        #expect(session.results.status.partialHosts == ["Mini"])
        #expect(session.results.status.summary == "Search incomplete on Mini")
    }

    @Test func aPartialHostKeepsItsRowsBesideAnotherHostsCompleteAnswer() async throws {
        let session = session(hosts: [host(mini, "Mini"), host(book, "MacBook")])
        try await ask(session, "drawer", hosts: 2)
        requests.answer(mini, truncated: true, with: [hit("partial", on: mini)])
        try #require(await waitUntil { ids(session.results.messages) == ["partial"] })
        #expect(session.results.status.isSearching)
        #expect(session.results.status.summary == "Searching… · Search incomplete on Mini")

        requests.answer(book, with: [hit("complete", on: book)])
        try #require(await waitUntil { !session.results.status.isSearching })
        #expect(ids(session.results.messages) == ["partial", "complete"])
        #expect(session.results.status.partialHosts == ["Mini"])
        #expect(session.results.status.unansweredHosts.isEmpty)
        #expect(session.results.status.unsupportedHosts.isEmpty)
        #expect(!session.results.status.isComplete)
    }

    @Test func sectionsShowAFixedNumberOfRowsUntilRevealed() async throws {
        let titles = try (0..<6).map { try header("title-\($0)", "Search \($0)", at: Int64(100 - $0)) }
        let session = session(hosts: [host(mini, "Mini", headers: titles)])
        try await ask(session, "search", hosts: 1)
        requests.answer(mini, with: (0..<12).map { hit("hit-\($0)", on: mini, excerpt: "search result \($0)") })
        #expect(await waitUntil { session.results.isPainted })

        #expect(session.results.titles.visibleRows.count == ConversationSearchSection.Kind.titles.visibleRowLimit)
        #expect(session.results.titles.hiddenRowCount == 2)
        #expect(session.results.messages.visibleRows.count == ConversationSearchSection.Kind.messages.visibleRowLimit)
        #expect(session.results.messages.hiddenRowCount == 2)
        session.reveal(.messages)
        #expect(session.results.messages.visibleRows.count == 12)
        #expect(session.results.messages.hiddenRowCount == 0)
        #expect(session.results.titles.hiddenRowCount == 2)
    }

    @Test func aSupersededQueryIsCancelledAndItsLateAnswerNeverPublishes() async throws {
        let session = session(hosts: [host(mini, "Mini")])
        try await ask(session, "alpha", hosts: 1)
        session.query = "beta"
        #expect(await waitUntil { requests.cancelledQueries == ["alpha"] })

        requests.answer(mini, query: "alpha", with: [hit("late", on: mini, excerpt: "alpha")])
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { session.results.isPainted }))
        #expect(await waitUntil { clock.sleeperCount == 1 })
        clock.advance(by: ConversationSearchSession.debounce)
        #expect(await waitUntil { requests.pendingQueries == ["beta"] })
        requests.answer(mini, query: "beta", with: [hit("current", on: mini, excerpt: "beta")])
        #expect(await waitUntil { session.results.isPainted })
        #expect(ids(session.results.messages) == ["current"])
        #expect(requests.sentQueries == ["alpha", "beta"])
    }

    @Test func hostsThatCannotAnswerAreNamedAndTitleMatchesPaintWithoutWaiting() async throws {
        let session = session(hosts: [
            host(mini, "Mini", headers: [try header("local", "Fix hitch", at: 100)]),
            ConversationSearchHost(id: book, name: "MacBook", gatewayID: book, headers: [], marks: marks(),
                                   availability: .connected(keyword: { _ in .unsupported }, meaning: nil)),
            ConversationSearchHost(id: linux, name: "Linux", gatewayID: linux, headers: [], marks: marks(),
                                   availability: .unreachable),
        ])
        try await ask(session, "hitch", hosts: 1)
        requests.fail(mini)
        #expect(await waitUntil { session.results.isPainted })
        #expect(ids(session.results.titles) == ["local"])
        #expect(session.results.status == ConversationSearchStatus(isSearching: false, unansweredHosts: ["Linux", "Mini"],
                                                                   unsupportedHosts: ["MacBook"]))
        #expect(requests.sentQueries == ["hitch"])
    }

    @Test func clearingTheQueryCancelsTheSearchAndEmptiesTheResults() async throws {
        let session = session(hosts: [host(mini, "Mini", headers: [try header("local", "Drawer", at: 1)])])
        try await ask(session, "drawer", hosts: 1)
        #expect(session.isActive)
        session.query = "  "
        #expect(!session.isActive)
        #expect(session.results == ConversationSearchResults())
        #expect(await waitUntil { requests.cancelledQueries == ["drawer"] })
    }

    @Test func answersNameTheOriginHostDropProbesAndUnknownHostsAndFallBackToKnownTitles() throws {
        let query = try #require(ConversationSearchQuery("flicker"))
        let hosts = [
            host(mini, "Mini", headers: [try header("titled", "Known title", at: 1)],
                 marks: marks(purposes: ["probe": .probe])),
            ConversationSearchHost(id: book, name: "MacBook", gatewayID: linux, headers: [], marks: marks(), availability: .unreachable),
        ]
        let response = ConversationSearchResponse(schemaVersion: 1, truncated: false, conversations: [
            hit("titled", on: mini, title: nil, hitCount: 400, excerpt: "a flicker"),
            hit("untitled", on: mini, title: nil, hitCount: 1, excerpt: "the flicker"),
            hit("probe", on: mini, excerpt: "flicker"),
            hit("unknown", on: UUID(), excerpt: "flicker"),
            hit("migrated", on: linux, title: "Mirror", hitCount: 4, excerpt: nil),
        ])
        let rows = ConversationSearchMerge.candidates(from: response, hosts: hosts, query: query, generation: 1, now: now).map(\.row)

        #expect(rows.map(\.address) == [ConversationAddress(hostID: mini, threadID: "titled"),
                                        ConversationAddress(hostID: mini, threadID: "untitled"),
                                        ConversationAddress(hostID: book, threadID: "migrated")])
        guard case .title("Known title") = rows[0].headline else { Issue.record("expected the local title"); return }
        #expect(rows[0].excerpt.map { String($0.characters) } == "a flicker")
        #expect(rows[0].additionalHitCount == 399)
        #expect(rows[0].additionalHitLabel == "9+ more")
        guard case let .excerpt(excerpt) = rows[1].headline else { Issue.record("expected the excerpt headline"); return }
        #expect(String(excerpt.characters) == "the flicker")
        #expect(rows[1].excerpt == nil)
        #expect(rows[1].additionalHitCount == 0)
        #expect(rows[1].additionalHitLabel == nil)
        #expect(rows.map(\.hostName) == ["Mini", "Mini", "MacBook"])
        #expect(rows[2].excerpt == nil)
        #expect(rows[2].additionalHitLabel == "+4 more")
    }

    @Test func excerptsFocusOnTheFirstMatchAndEmphasizeEveryEligibleTerm() throws {
        let query = try #require(ConversationSearchQuery("ui Flicker drawer"))
        let excerpt = query.emphasizedExcerpt("We looked at many things before\nnoticing that the ui drawer FLICKER happens on open")
        #expect(String(excerpt.characters) == "…noticing that the ui drawer FLICKER happens on open")
        let emphasized = excerpt.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map { String(excerpt[$0.range].characters) }
        #expect(emphasized == ["drawer", "FLICKER"])
    }

    @Test func excerptsFocusAndEmphasizeDiacriticInsensitiveMatches() throws {
        let query = try #require(ConversationSearchQuery("malmo"))
        let text = "We spent most of the afternoon discussing the new deployment plan for Malmö."
        let excerpt = query.emphasizedExcerpt(text)
        #expect(query.bestTerm(in: text) == "malmo")
        #expect(String(excerpt.characters) == "…deployment plan for Malmö.")
        #expect(excerpt.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map { String(excerpt[$0.range].characters) } == ["Malmö"])
    }

    @Test func queriesFollowTheContractTermRule() throws {
        let query = try #require(ConversationSearchQuery("  Drawer drawer DRAWER flicker  "))
        #expect(query.terms == ["Drawer", "flicker"])
        #expect(query.text == "Drawer flicker")
        #expect(query.titleContainsEveryTerm("Fix the FLICKER in the drawer"))
        #expect(!query.titleContainsEveryTerm("Fix the drawer"))
        #expect(!query.titleContainsEveryTerm("Fix the drawér flicker"))
        #expect(ConversationSearchQuery(" \n ") == nil)
        let phrase = "where did we test the new drawer with reduced motion enabled"
        let parsed = try #require(ConversationSearchQuery(phrase))
        #expect(parsed.terms.count == 8)
        #expect(parsed.meaningText == phrase)
        let long = String(repeating: "a", count: 300) + " " + String(repeating: "b", count: 300)
        #expect(ConversationSearchQuery(long)?.terms == [String(repeating: "a", count: 300)])
    }

    @Test func decodesTheContractResult() throws {
        let json = Data("""
        {"schemaVersion":1,"truncated":true,"conversations":[
          {"sessionKey":"\(mini.uuidString):claude:home:claude_1","hostId":"\(mini.uuidString)","provider":"claude",
           "threadId":"claude_1","title":"Fix sidebar open hitch","cwd":"/Users/emil/RemoteCoder",
           "lastAt":"2026-11-03T14:02:11Z","titleMatch":false,"hitCount":5,
           "hits":[{"itemKey":"k@item:1","kind":"assistant","at":"2026-11-03T13:58:40.250Z",
                    "excerpt":"…the drawer still shows a flicker…","agentThreadId":"child-thread"}]},
          {"sessionKey":"\(mini.uuidString):codex:home:t2","hostId":"\(mini.uuidString)","provider":"codex",
           "threadId":"t2","title":null,"cwd":null,"lastAt":null,"titleMatch":true,"hitCount":0,"hits":[]}
        ]}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = ConversationSearchResponse.dateDecoding
        let response = try decoder.decode(ConversationSearchResponse.self, from: json)
        #expect(response.schemaVersion == 1)
        #expect(response.truncated)
        #expect(response.conversations.map(\.threadId) == ["claude_1", "t2"])
        let first = response.conversations[0]
        #expect(first.hostId == mini && first.provider == .claude && first.hitCount == 5 && !first.titleMatch)
        #expect(first.lastAt == Date(timeIntervalSince1970: 1_793_714_531))
        #expect(first.hits.first?.agentThreadId == "child-thread")
        #expect(first.hits.map(\.excerpt) == ["…the drawer still shows a flicker…"])
        let second = response.conversations[1]
        #expect(second.title == nil && second.cwd == nil && second.lastAt == nil && second.titleMatch && second.hits.isEmpty)
    }

    @Test func aPaintedQueryIsReplacedRatherThanMixedWithTheNextQuery() async throws {
        let session = session(hosts: [host(mini, "Mini")])
        try await ask(session, "alpha", hosts: 1)
        requests.answer(mini, with: [hit("alpha", on: mini)])
        #expect(await waitUntil { session.results.isPainted })
        try await ask(session, "beta", hosts: 1)
        requests.answer(mini, with: [hit("beta", on: mini)])
        #expect(await waitUntil { ids(session.results.messages) == ["beta"] })
    }

    @Test func meaningSearchKeepsTheStatusActiveAndAppendsDeduplicatedProviderOrder() async throws {
        let meaning = MeaningRequests()
        let session = session(hosts: [host(mini, "Mini", meaning: meaning.search)])
        try await ask(session, "drawer", hosts: 1, meaning: true)
        requests.answer(mini, with: [hit("literal", on: mini)])
        #expect(await waitUntil { ids(session.results.messages) == ["literal"] })
        #expect(session.results.status.isSearching)
        clock.advance(by: .milliseconds(399))
        #expect(meaning.queries.isEmpty)
        #expect(clock.sleeperCount == 1)
        clock.advance(by: .milliseconds(1))
        try #require(await waitUntil { meaning.queries == ["drawer"] })
        meaning.answer("drawer", with: [meaningHit("literal"), meaningHit("second"), meaningHit("first")])
        #expect(await waitUntil { !session.results.status.isSearching })
        #expect(ids(session.results.messages) == ["literal"])
        #expect(ids(session.results.meaning) == ["second", "first"])
        #expect(session.results.meaning.rows.first?.excerpt.map { String($0.characters) } == "Remembered sidebar motion")
        #expect(session.results.meaning.rows.first?.section == .meaning)
    }

    @Test func lateMeaningAnswersCannotPublishAfterCancellationOrAReplacementQuery() async throws {
        let meaning = MeaningRequests()
        let session = session(hosts: [host(mini, "Mini", meaning: meaning.search)])
        try await ask(session, "alpha", hosts: 1, meaning: true)
        clock.advance(by: .milliseconds(400))
        try #require(await waitUntil { meaning.queries == ["alpha"] })
        requests.answer(mini, with: [])
        #expect(await waitUntil { session.results.isPainted })
        session.query = "beta"
        #expect(await waitUntil { meaning.cancelled == ["alpha"] })
        meaning.answer("alpha", with: [meaningHit("stale")])
        #expect(await waitUntil { clock.sleeperCount == 1 })
        clock.advance(by: ConversationSearchSession.debounce)
        try #require(await waitUntil { requests.pendingQueries == ["beta"] && clock.sleeperCount == 2 })
        clock.advance(by: .milliseconds(400))
        try #require(await waitUntil { meaning.queries == ["beta"] })
        requests.answer(mini, with: [hit("current", on: mini)])
        meaning.fail("beta")
        #expect(await waitUntil { !session.results.status.isSearching })
        #expect(ids(session.results.messages) == ["current"])
        #expect(session.results.meaning.rows.isEmpty)
        #expect(session.results.status.unansweredHosts.isEmpty)
        #expect(session.results.status.failedMeaningHosts == ["Mini"])
        #expect(session.results.status.summary == "By meaning failed on Mini")
        #expect(!session.results.status.isComplete)
    }

    @Test func aKeystrokeBeforeTheMeaningDeadlinePreventsTheOldRequest() async throws {
        let meaning = MeaningRequests()
        let session = session(hosts: [host(mini, "Mini", meaning: meaning.search)])
        try await ask(session, "alpha", hosts: 1, meaning: true)
        requests.answer(mini, with: [])
        try #require(await waitUntil { session.results.isPainted })
        clock.advance(by: .milliseconds(399))

        try await ask(session, "beta", hosts: 1, meaning: true)
        #expect(meaning.queries.isEmpty)
        clock.advance(by: .milliseconds(400))
        try #require(await waitUntil { meaning.queries == ["beta"] })
        requests.answer(mini, with: [])
        meaning.answer("beta", with: [])
        #expect(await waitUntil { !session.results.status.isSearching })
        #expect(meaning.cancelled.isEmpty)
    }

    @Test func suspensionRejectsLateAnswersAndRestartsOnlyAnInterruptedRun() async throws {
        let meaning = MeaningRequests()
        let session = session(hosts: [host(mini, "Mini", meaning: meaning.search)])
        try await ask(session, "drawer", hosts: 1, meaning: true)
        requests.answer(mini, with: [hit("painted", on: mini)])
        try #require(await waitUntil { session.results.isPainted })
        clock.advance(by: .milliseconds(400))
        try #require(await waitUntil { meaning.queries == ["drawer"] })
        let retained = session.results

        session.suspend()
        try #require(await waitUntil { meaning.cancelled == ["drawer"] })
        meaning.answer("drawer", with: [meaningHit("late")])
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { session.results != retained }))
        #expect(session.query == "drawer")

        session.resume()
        try #require(await waitUntil { clock.sleeperCount == 1 })
        clock.advance(by: ConversationSearchSession.debounce)
        try #require(await waitUntil { requests.pendingQueries == ["drawer"] && clock.sleeperCount == 2 })
        requests.answer(mini, with: [hit("current", on: mini)])
        clock.advance(by: .milliseconds(400))
        try #require(await waitUntil { meaning.queries == ["drawer"] })
        meaning.answer("drawer", with: [])
        try #require(await waitUntil { !session.results.status.isSearching })
        #expect(ids(session.results.messages) == ["current"])
        #expect(requests.sentQueries == ["drawer", "drawer"])

        let complete = session.results
        session.suspend()
        session.resume()
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { requests.sentQueries.count != 2 }))
        #expect(session.results == complete)
        #expect(clock.sleeperCount == 0)
    }

    @Test func messageHitsCarryTheExactItemKeyAndTheLongestMatchingFindTerm() throws {
        let response = ConversationSearchResponse(schemaVersion: 1, truncated: false, conversations: [hit("one", on: mini, excerpt: "the drawer flickered")])
        let query = try #require(ConversationSearchQuery("drawer flicker absent"))
        let row = try #require(ConversationSearchMerge.candidates(from: response, hosts: [host(mini, "Mini")],
            query: query, generation: 1, now: now).first?.row)
        #expect(row.itemKey == "fixture@item:1")
        #expect(row.findTerm == "flicker")
    }

    @Test(arguments: [AgentProvider.codex, .claude])
    func foldedChildHitsKeepTheRootCardAndOpenTheExactWireDestination(_ provider: AgentProvider) async throws {
        let root = provider == .codex ? "codex-root" : "claude_root"
        let child = provider == .codex ? "codex-child" : nil
        let destination = child ?? root
        let item = provider == .codex ? "u0" : "c0"
        let json = Data("""
        {"schemaVersion":1,"truncated":false,"conversations":[
          {"sessionKey":"root-session","hostId":"\(mini.uuidString)","provider":"\(provider.rawValue)",
           "threadId":"\(root)","title":"Root conversation","cwd":null,"lastAt":null,"titleMatch":false,"hitCount":1,
           "hits":[{"itemKey":"child-session@item:0","excerpt":"drawer result","agentThreadId":\(child.map { "\"\($0)\"" } ?? "null")}]}
        ]}
        """.utf8)
        let response = try JSONDecoder().decode(ConversationSearchResponse.self, from: json)
        let query = try #require(ConversationSearchQuery("drawer"))
        let candidates = ConversationSearchMerge.candidates(from: response, hosts: [host(mini, "Mini")],
            query: query, generation: 1, now: now)
        let row = try #require(candidates.first?.row)
        #expect(row.address == ConversationAddress(hostID: mini, threadID: root))
        #expect(row.openingAddress == ConversationAddress(hostID: mini, threadID: destination))
        #expect(row.id == row.address.id)
        guard case .title("Root conversation") = row.headline else {
            Issue.record("The root title was lost")
            return
        }
        let painted = ConversationSearchMerge.firstPaint(of: .init(), titleMatches: [], answer: candidates)
        #expect(ConversationSearchMerge.appending(candidates, to: painted).messages.rows.count == 1)

        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryGatewayFixture(threadID: row.openingAddress.threadID)
        await gateway.setLocateReply(.init(threadId: destination, turnId: "t0", turnsCursor: "0", itemsCursor: "0", itemId: item))
        let history = GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(directory: directory))
        let opened = try await history.openSearchHit(header: gateway.header, itemKey: try #require(row.itemKey),
            fallback: .openTail(base: nil, bypassCache: false))
        let snapshot = try #require(opened.snapshot)
        #expect(snapshot.header.id == destination)
        #expect(opened.location?.itemId == item)
        #expect(snapshot.window.turns.first?.entries.first?.item.id == "u0")
        #expect(await gateway.tailReads == 0)
    }

    private func meaningHit(_ id: String) -> ConversationMeaningResponse.Conversation {
        .init(sessionKey: "\(mini.uuidString):codex:home:\(id)", hostId: mini, provider: .codex,
              threadId: id, title: "Remembered work", cwd: nil, lastAt: nil, excerpt: "Remembered sidebar motion")
    }

    private func session(hosts: [ConversationSearchHost]) -> ConversationSearchSession {
        ConversationSearchSession(clock: clock) { hosts }
    }

    private func ask(_ session: ConversationSearchSession, _ query: String, hosts: Int, meaning: Bool = false) async throws {
        session.query = query
        try #require(await waitUntil { clock.sleeperCount == 1 })
        clock.advance(by: ConversationSearchSession.debounce)
        try #require(await waitUntil { requests.pendingQueries.count == hosts && clock.sleeperCount == (meaning ? 2 : 1) })
    }

    private func host(_ id: UUID, _ name: String, headers: [ConversationHeader] = [],
                      marks: ConversationMarks? = nil,
                      meaning: ConversationSearchHost.Search<ConversationMeaningResponse>? = nil) -> ConversationSearchHost {
        ConversationSearchHost(id: id, name: name, gatewayID: id, headers: headers, marks: marks ?? self.marks(),
                               availability: .connected(keyword: requests.handler(for: id), meaning: meaning))
    }

    private func marks(purposes: [String: ConversationPurpose] = [:]) -> ConversationMarks {
        ConversationMarks(schemaVersion: 5, revision: 1, readBaseline: 0,
                          threads: purposes.mapValues { ThreadMarks(revision: 1, purpose: $0) })
    }

    private func header(_ id: String, _ title: String, at time: Int64) throws -> ConversationHeader {
        try ThreadFixture.basic(id, updatedAt: time, fields: ["name": title, "lastTurnCompletedAt": time])
    }

    private func hit(_ thread: String, on host: UUID, sessionKey: String? = nil, title: String? = "Untitled work",
                     titleMatch: Bool = false, hitCount: Int = 1, excerpt: String? = "match",
                     lastAt: Int64? = 50) -> ConversationSearchResponse.Conversation {
        ConversationSearchResponse.Conversation(
            sessionKey: sessionKey ?? "\(host.uuidString):codex:home:\(thread)", hostId: host, provider: .codex,
            threadId: thread, title: title, cwd: "/Users/developer/RemoteCoder",
            lastAt: lastAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }, titleMatch: titleMatch,
            hitCount: hitCount, hits: excerpt.map { [.init(itemKey: "fixture@item:1", excerpt: $0, agentThreadId: nil)] } ?? [])
    }

    private func ids(_ section: ConversationSearchSection) -> [String] {
        section.rows.map(\.address.threadID)
    }
}

private nonisolated final class SearchRequests: Sendable {
    private struct Pending {
        let id: UUID
        let host: UUID
        let query: String
        let continuation: CheckedContinuation<ConversationSearchHost.Answer<ConversationSearchResponse>, any Error>
    }

    private struct State {
        var pending: [Pending] = []
        var sent: [String] = []
        var cancelled: [String] = []
        var limits: [Int] = []
    }

    private let state = Mutex(State())

    var pendingQueries: [String] { state.withLock { $0.pending.map(\.query) } }
    var sentQueries: [String] { state.withLock { $0.sent } }
    var cancelledQueries: [String] { state.withLock { $0.cancelled } }
    var limits: [Int] { state.withLock { $0.limits } }

    func handler(for host: UUID) -> @Sendable (ConversationSearchParams) async throws -> ConversationSearchHost.Answer<ConversationSearchResponse> {
        { [self] params in
            let id = UUID()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    state.withLock { state in
                        state.sent.append(params.query)
                        state.limits.append(params.limit)
                        state.pending.append(Pending(id: id, host: host, query: params.query, continuation: continuation))
                    }
                }
            } onCancel: {
                state.withLock { $0.cancelled.append(params.query) }
            }
        }
    }

    func answer(_ host: UUID, query: String? = nil, truncated: Bool = false,
                with conversations: [ConversationSearchResponse.Conversation]) {
        take(host, query: query)?.continuation.resume(
            returning: .results(ConversationSearchResponse(schemaVersion: 1, truncated: truncated, conversations: conversations)))
    }

    func fail(_ host: UUID) {
        take(host, query: nil)?.continuation.resume(throwing: GatewayClient.ClientError.notConnected)
    }

    private func take(_ host: UUID, query: String?) -> Pending? {
        state.withLock { state in
            guard let index = state.pending.firstIndex(where: { $0.host == host && (query == nil || $0.query == query) }) else {
                return nil
            }
            return state.pending.remove(at: index)
        }
    }
}

private nonisolated final class MeaningRequests: Sendable {
    private struct State {
        var pending: [String: CheckedContinuation<ConversationSearchHost.Answer<ConversationMeaningResponse>, any Error>] = [:]
        var cancelled: [String] = []
    }
    private let state = Mutex(State())
    var queries: [String] { state.withLock { $0.pending.keys.sorted() } }
    var cancelled: [String] { state.withLock { $0.cancelled } }

    func search(_ params: ConversationSearchParams) async throws -> ConversationSearchHost.Answer<ConversationMeaningResponse> {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { $0.pending[params.query] = continuation }
            }
        } onCancel: { state.withLock { $0.cancelled.append(params.query) } }
    }

    func answer(_ query: String, with conversations: [ConversationMeaningResponse.Conversation]) {
        state.withLock { $0.pending.removeValue(forKey: query) }?.resume(returning: .results(.init(schemaVersion: 1, conversations: conversations)))
    }

    func fail(_ query: String) {
        state.withLock { $0.pending.removeValue(forKey: query) }?.resume(throwing: GatewayClient.ClientError.notConnected)
    }
}
