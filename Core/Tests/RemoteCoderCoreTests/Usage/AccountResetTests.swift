import Foundation
import Testing
@testable import RemoteCoderCore

struct AccountResetTests {
    private let hostID = UUID()
    @Test(arguments: [
        (#"null"#, nil, nil),
        (#"{"state":"unavailable","observedAt":null,"available":null,"offers":null,"error":"reauthorization_required"}"#, nil, nil),
        (#"{"state":"known","observedAt":1792236840,"available":3,"offers":null,"error":null}"#, 3, nil),
        (#"{"state":"known","observedAt":1792236840,"available":0,"offers":[],"error":null}"#, 0, 0),
        (#"{"state":"known","observedAt":1792236840,"available":3,"offers":[{"id":"offer","title":"Full reset","remaining":1,"expiresAt":null,"usableNow":null,"requiresLimit":null,"clears":null}],"error":null}"#, 3, 1)
    ] as [(String, Int?, Int?)])
    func bothAccountPayloadsPreserveResetCoverage(_ json: String, count: Int?, offers: Int?) throws {
        let codex = try JSONDecoder().decode(ProviderAccountSnapshot.self, from: Data("""
        {"id":"default-codex","provider":"codex","label":"Default","enabled":true,"generation":0,"isDefault":true,"identity":null,"plan":null,"state":"ready","windows":[],"observedAt":null,"stale":false,"error":null,"activeTurns":0,"incomingCallRoutingId":null,"resets":\(json)}
        """.utf8))
        let claude = try JSONDecoder().decode(ClaudeRouterAccount.self, from: Data("""
        {"id":"claude-one","label":"one@example.com","plan":"max","shared":false,"credential":"ready","availability":"available","availableAt":null,"windows":[],"observedAt":null,"resets":\(json)}
        """.utf8))
        #expect(codex.resets == claude.resets)
        #expect(codex.resets?.knownCount == count)
        #expect(codex.resets?.offers?.count == offers)
        if json == "null" { #expect(codex.resets == nil) }
        if json.contains("reauthorization_required") {
            #expect(codex.resets?.state == .unavailable)
            #expect(codex.resets?.error == "reauthorization_required")
        }
        if let offer = codex.resets?.offers?.first {
            #expect(offer.expiresAt == nil)
            #expect(offer.usableNow == nil)
            #expect(offer.clears == nil)
            #expect(offer.canUse(now: Date(timeIntervalSince1970: 1792236840)))
        }
    }

    @Test func expiryAndProviderEligibilityControlUseWithoutGuessingUnknownFlags() throws {
        let data = Data(#"{"id":"grant","title":null,"remaining":2,"expiresAt":1793300000,"usableNow":true,"requiresLimit":true,"clears":["five_hour","seven_day"]}"#.utf8)
        let offer = try JSONDecoder().decode(AccountResetOffer.self, from: data)
        #expect(offer.remaining == 2)
        #expect(offer.requiresLimit == true)
        #expect(offer.clears == ["five_hour", "seven_day"])
        #expect(offer.canUse(now: Date(timeIntervalSince1970: 1793299999)))
        #expect(!offer.canUse(now: Date(timeIntervalSince1970: 1793300000)))
        let blocked = try JSONDecoder().decode(AccountResetOffer.self, from:
            Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"usableNow\":true", with: "\"usableNow\":false").utf8))
        #expect(!blocked.canUse(now: Date(timeIntervalSince1970: 1793299999)))
    }

    @Test(arguments: [
        ("rejected", "null", "known", "1799999940", false),
        ("ready", "1800000000", "known", "1799999099", true),
        ("ready", "1800000000", "known", "null", true),
        ("ready", "1800000000", "unavailable", "1800000000", true),
        ("ready", "1799990000", "known", "1799999100", false)
    ])
    func claudeResetFreshnessUsesItsOwnObservation(credential: String, usageTime: String,
                                                   resetState: String, resetTime: String, expectedStale: Bool) throws {
        let account = try JSONDecoder().decode(ClaudeRouterAccount.self, from: Data("""
        {"id":"claude-one","label":"one@example.com","plan":"max","shared":false,"credential":"\(credential)","availability":"available","availableAt":null,"windows":[],"observedAt":\(usageTime),"resets":{"state":"\(resetState)","observedAt":\(resetTime),"available":1,"offers":null,"error":null}}
        """.utf8))
        #expect(account.resets?.isStale(now: Date(timeIntervalSince1970: 1_800_000_000)) == expectedStale)
    }

    @Test func pendingResetKeyUsesCanonicalLowercaseAndPreservesItsIdentityOnRead() throws {
        let canonical = "e1741c43-3d9a-4448-9f4a-3c7e5906e852"
        let key = try #require(UUID(uuidString: canonical))
        let attempt = ResetRedemptionAttempt(resetId: "one", title: "Full reset", idempotencyKey: key,
                                             hostID: hostID, gatewayAccountID: "gateway-one", accountName: "One",
                                             createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let encoded = try JSONEncoder().encode(attempt)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["idempotencyKey"] as? String == canonical)
        #expect(attempt.canonicalIdempotencyKey == canonical)
        #expect(try JSONDecoder().decode(ResetRedemptionAttempt.self, from: encoded) == attempt)
        var previous = object
        previous["idempotencyKey"] = canonical.uppercased()
        let restored = try JSONDecoder().decode(ResetRedemptionAttempt.self, from: JSONSerialization.data(withJSONObject: previous))
        #expect(restored == attempt)
        #expect(restored.canonicalIdempotencyKey == canonical)
        previous.removeValue(forKey: "createdAt")
        let undated = try JSONDecoder().decode(ResetRedemptionAttempt.self, from: JSONSerialization.data(withJSONObject: previous))
        #expect(undated.createdAt == nil)
        #expect(!undated.canResume(now: .now))
    }

    @Test @MainActor func failoverSkipsGatewaysThatNeverSubmitted() async throws {
        var tried: [String] = []
        let result = try await ResetRedemptionFailover.submit(through: ["book", "linux", "mini"], name: { $0 }) { gateway in
            tried.append(gateway)
            switch gateway {
            case "book": throw ResetRedemptionError.unavailable("Timed out before connecting")
            case "linux": throw ResetRedemptionError.unconfirmed("Reply lost")
            default: return .init(outcome: .alreadyRedeemed, reason: nil)
            }
        }
        #expect(tried == ["book", "linux", "mini"])
        #expect(result.outcome == .alreadyRedeemed)
    }

    @Test @MainActor func failoverNeverTurnsAPossibleSubmissionIntoARefusal() async {
        let thrown = await failure(["book", "mini"]) { gateway in
            if gateway == "book" { throw ResetRedemptionError.unconfirmed("Reply lost") }
            throw ResetRedemptionError.rejected("Another reset is pending.")
        }
        #expect(thrown?.isUnconfirmed == true)
        let answered = await failure(["book", "mini"]) { gateway in
            if gateway == "book" { throw ResetRedemptionError.unconfirmed("Reply lost") }
            return .init(outcome: .refused, reason: "already_used")
        }
        #expect(answered?.isUnconfirmed == true)
        var tried: [String] = []
        let refused = await failure(["book", "mini"]) { gateway in
            tried.append(gateway)
            throw ResetRedemptionError.rejected("No resets left.")
        }
        #expect(refused.map { !$0.isUnconfirmed && !$0.isUnavailable } == true)
        #expect(tried == ["book"])
        let unreachable = await failure(["book", "mini"]) { _ in throw ResetRedemptionError.unavailable("Offline") }
        #expect(unreachable?.isUnavailable == true)
    }

    @Test @MainActor func aLostReplyThenARefusalKeepsTheSavedKey() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = HostStorage(root: root)
        let redemptions = AccountResetRedemptions(storage: storage, provider: .claude, beginBackgroundExecution: { _ in {} })
        var keys: Set<String> = []
        await redemptions.redeem(accountID: "claude-one", accountName: "One", hostID: hostID, gatewayAccountID: "claude-one",
                                 offer: offer("one"), operation: { attempt in
            try await ResetRedemptionFailover.submit(through: ["book", "mini"], name: { $0 }) { gateway in
                keys.insert(attempt.canonicalIdempotencyKey + "|" + attempt.resetId)
                if gateway == "book" { throw ResetRedemptionError.unconfirmed("Reply lost") }
                return .init(outcome: .refused, reason: "already_used")
            }
        }, refresh: {})
        #expect(keys.count == 1)
        #expect(redemptions.states["claude-one"]?.canRetry == true)
        #expect(try await ResetRedemptionStore(storage: storage, provider: .claude).load()["claude-one"] != nil)
    }

    @Test @MainActor func connectedGatewaysAreTriedFirstThenTheAttemptsOwnHost() {
        let book = UUID(), linux = UUID(), mini = UUID()
        let ranked = ResetRedemptionFailover.ranked([book, linux, mini], preferred: book, id: { $0 },
                                                    isConnected: { $0 != book })
        #expect(ranked == [linux, mini, book])
        #expect(ResetRedemptionFailover.ranked([linux, book, mini], preferred: book, id: { $0 }, isConnected: { _ in true })
                == [book, linux, mini])
    }

    @Test @MainActor func onlyRecentUnconfirmedAttemptsResumeAndOnlyAFewTimes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = HostStorage(root: root)
        let store = ResetRedemptionStore(storage: storage, provider: .codex)
        let now = Date.now
        for (account, created) in [("codex:recent", now.addingTimeInterval(-60)), ("codex:old", now.addingTimeInterval(-3_600))] {
            try await store.save(ResetRedemptionAttempt(resetId: "one", title: "Full reset", idempotencyKey: UUID(), hostID: hostID,
                                                        gatewayAccountID: "default-codex", accountName: "One", createdAt: created),
                                 accountID: account)
        }
        try await store.save(ResetRedemptionAttempt(resetId: "one", title: "Full reset", idempotencyKey: UUID(), hostID: hostID,
                                                    gatewayAccountID: "default-codex", accountName: "One", createdAt: nil),
                             accountID: "codex:undated")
        let redemptions = AccountResetRedemptions(storage: storage, provider: .codex, beginBackgroundExecution: { _ in {} })
        await redemptions.restore()
        var resumed: [String] = []
        let operation: @MainActor (String, ResetRedemptionAttempt) async throws -> AccountResetRedemptionResult = { account, _ in
            resumed.append(account)
            if resumed.count == 1 { throw ResetRedemptionError.unavailable("Gateway unavailable. Try again shortly.") }
            throw ResetRedemptionError.unconfirmed("Reply lost")
        }
        let stale = redemptions.revision
        redemptions.stop()
        redemptions.resume(now: now, fence: stale, operation: operation, refresh: {})
        #expect(resumed.isEmpty)
        for _ in 0..<5 {
            redemptions.resume(now: now, fence: redemptions.revision, operation: operation, refresh: {})
            redemptions.resume(now: now, fence: redemptions.revision, operation: operation, refresh: {})
            while redemptions.states.values.contains(where: \.isSubmitting) { await Task.yield() }
        }
        #expect(resumed == Array(repeating: "codex:recent", count: 4))
        #expect(redemptions.states["codex:recent"]?.canRetry == true)
        #expect(redemptions.states["codex:recent"]?.canForget == false)
        #expect(!ResetRedemptionAttempt(resetId: "one", title: "Full reset", idempotencyKey: UUID(), hostID: hostID,
                                        gatewayAccountID: "default-codex", accountName: "One",
                                        createdAt: now.addingTimeInterval(60)).canResume(now: now))
        #expect(redemptions.states["codex:undated"]?.canRetry == true)
    }

    @Test(arguments: ["gateway_stopping", "accounts_busy", "router_unavailable", "router_stopping",
                      "router_key_unavailable", "router_retry_later", "account_management_unavailable"])
    func transientRefusalsInviteARetry(code: String) {
        #expect(AccountResetMessages.refusal(code: code) == "Gateway unavailable. Try again shortly.")
    }

    @Test func missingCodexCredentialNamesTheAccountNeedingSignIn() {
        #expect(AccountResetMessages.unavailable(code: "codex_credential_unavailable", accountName: "Personal Codex")
                == "Sign-in needed for Personal Codex. Ask an agent to reconnect it.")
    }

    @Test func unconfirmedAttemptBlocksAnotherOfferAndRetriesKeepTheirKeyUntilAResponse() throws {
        var state = ResetRedemptionState.idle
        let key = UUID()
        let started = state.begin(offer: offer("one"), key: key, hostID: hostID, gatewayAccountID: "gateway-one", accountName: "One")
        let attempt = try #require(started)
        let duplicate = state.begin(offer: offer("two"), key: UUID(), hostID: hostID, gatewayAccountID: "gateway-one", accountName: "One")
        #expect(duplicate == nil)
        let concurrentRetry = state.retry()
        #expect(concurrentRetry == nil)
        state.fail("Response lost", key: key, unconfirmed: true)
        let replacement = state.begin(offer: offer("two"), key: UUID(), hostID: hostID, gatewayAccountID: "gateway-one", accountName: "One")
        #expect(replacement == nil)
        let retried = state.retry()
        #expect(retried == attempt)
        state.resolve(.init(outcome: .reset, reason: nil), key: UUID())
        #expect(state.isSubmitting)
        state.fail("Gateway offline", key: key, unconfirmed: false)
        #expect(state.isUnresolved)
        #expect(state.canForget)
        #expect(state.canRetry)
        #expect(state.attempt == attempt)
        #expect(state.message?.contains("still unknown") == true)
        let retriedAfterRefusal = state.retry()
        #expect(retriedAfterRefusal == attempt)
        state.resolve(.init(outcome: .reset, reason: nil), key: key)
        #expect(!state.isUnresolved)
    }

    @Test func definitePreSubmissionFailureAllowsANewAttempt() throws {
        var state = ResetRedemptionState.idle
        let started = state.begin(offer: offer("one"), key: UUID(), hostID: hostID, gatewayAccountID: "gateway-one", accountName: "One")
        let attempt = try #require(started)
        state.fail("Credential unavailable", key: attempt.idempotencyKey, unconfirmed: false)
        #expect(!state.isUnresolved)
        let restarted = state.begin(offer: offer("one"), key: UUID(), hostID: hostID, gatewayAccountID: "gateway-one", accountName: "One")
        let next = try #require(restarted)
        #expect(next.idempotencyKey != attempt.idempotencyKey)
    }

    @Test func providerRefusalDuringRetryPreservesTheOriginalUnknownOutcome() throws {
        var state = ResetRedemptionState.idle
        let started = state.begin(offer: offer("one"), key: UUID(), hostID: hostID, gatewayAccountID: "gateway-one", accountName: "One")
        let attempt = try #require(started)
        state.fail("Lost reply", key: attempt.idempotencyKey, unconfirmed: true)
        _ = state.retry()
        state.resolve(.init(outcome: .refused, reason: "already_used"), key: attempt.idempotencyKey)
        #expect(state.canForget)
        #expect(state.attempt == attempt)
        #expect(state.message?.contains("already used") == true)
        #expect(state.message?.contains("still unknown") == true)
        #expect(state.canRetry)
        let retried = state.retry()
        #expect(retried == attempt)
    }

    @Test @MainActor func lostResponseSurvivesRelaunchAndRefreshesAfterEachOutcome() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = HostStorage(root: root)
        let first = AccountResetRedemptions(storage: storage, provider: .codex, beginBackgroundExecution: { _ in {} })
        var submitted: ResetRedemptionAttempt?
        var refreshes = 0
        await first.redeem(accountID: "codex:one", accountName: "One", hostID: hostID, gatewayAccountID: "gateway-one", offer: offer("one"), operation: { attempt in
            submitted = attempt
            let saved = try await ResetRedemptionStore(storage: storage, provider: .codex).load()
            #expect(saved["codex:one"] == attempt)
            throw ResetRedemptionError.unconfirmed("Response lost")
        }, refresh: { refreshes += 1 })
        #expect(refreshes == 1)
        #expect(first.states["codex:one"]?.isUnresolved == true)
        let relaunched = AccountResetRedemptions(storage: storage, provider: .codex, beginBackgroundExecution: { _ in {} })
        await relaunched.restore()
        #expect(relaunched.states["codex:one"]?.attempt == submitted)
        #expect(relaunched.states["codex:one"]?.attempt?.gatewayAccountID == "gateway-one")
        await relaunched.retry(accountID: "codex:one", operation: { attempt in
            #expect(attempt == submitted)
            return .init(outcome: .alreadyRedeemed, reason: "alreadyRedeemed")
        }, refresh: { refreshes += 1 })
        #expect(refreshes == 2)
        #expect(relaunched.states["codex:one"] == .completed(.init(outcome: .alreadyRedeemed, reason: "alreadyRedeemed")))
        #expect(try await ResetRedemptionStore(storage: storage, provider: .codex).load().isEmpty)
        #expect(try await ResetRedemptionStore(storage: storage, provider: .claude).load().isEmpty)
    }

    @Test @MainActor func stoppingAnInFlightAttemptRetainsItsKeyAndIgnoresItsLateReply() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var expirations: [@MainActor () -> Void] = []
        let redemptions = AccountResetRedemptions(storage: HostStorage(root: root), provider: .claude, beginBackgroundExecution: { expiration in
            expirations.append(expiration)
            return {}
        })
        let started = AsyncStream<ResetRedemptionAttempt>.makeStream()
        var reply: CheckedContinuation<AccountResetRedemptionResult, Never>?
        var refreshes = 0
        let task = Task {
            await redemptions.redeem(accountID: "one", accountName: "One", hostID: hostID, gatewayAccountID: "gateway-one", offer: offer("grant"), operation: { attempt in
                await withCheckedContinuation { continuation in
                    reply = continuation
                    started.continuation.yield(attempt)
                }
            }, refresh: { refreshes += 1 })
        }
        var iterator = started.stream.makeAsyncIterator()
        let pending = try #require(await iterator.next())
        await redemptions.redeem(accountID: "one", accountName: "One", hostID: hostID, gatewayAccountID: "gateway-one", offer: offer("different"), operation: { _ in
            Issue.record("A second reset was submitted for the same account")
            return .init(outcome: .reset, reason: nil)
        }, refresh: { refreshes += 1 })
        redemptions.stop()
        await redemptions.retry(accountID: "one", operation: { attempt in
            #expect(attempt == pending)
            expirations[0]()
            #expect(!Task.isCancelled)
            throw ResetRedemptionError.unconfirmed("Still pending")
        }, refresh: { refreshes += 1 })
        reply?.resume(returning: .init(outcome: .reset, reason: nil))
        await task.value
        #expect(redemptions.states["one"]?.attempt == pending)
        #expect(redemptions.states["one"] == .unconfirmed(pending, "Still pending"))
        #expect(refreshes == 1)
        started.continuation.finish()
    }

    @Test @MainActor func failedPersistenceNeverSubmitsOrLeavesAnUnreadableLedger() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = HostStorage(root: root)
        let redemptions = AccountResetRedemptions(storage: storage, provider: .codex, beginBackgroundExecution: { _ in {} })
        let oversized = AccountResetOffer(id: "one", title: String(repeating: "x", count: 128 * 1_024),
            remaining: 1, expiresAt: nil, usableNow: nil, requiresLimit: nil, clears: nil)
        var refreshes = 0
        await redemptions.redeem(accountID: "one", accountName: "One", hostID: hostID, gatewayAccountID: "gateway-one", offer: oversized, operation: { _ in
            Issue.record("A reset was submitted before its attempt could be saved")
            return .init(outcome: .reset, reason: nil)
        }, refresh: { refreshes += 1 })
        #expect(refreshes == 1)
        #expect(redemptions.states["one"]?.isUnresolved == false)
        #expect(try await ResetRedemptionStore(storage: storage, provider: .codex).load().isEmpty)
    }

    @Test(arguments: [
        (504, "redeem_unconfirmed", ResetSubmissionCertainty.unconfirmed),
        (409, "redeem_unconfirmed", .unconfirmed),
        (409, "redeem_in_progress", .notSubmitted),
        (409, "redeem_unconfirmed_pending", .notSubmitted),
        (404, "account_not_found", .refused),
        (409, "reset_account_unbound", .refused),
        (409, "reset_account_changed", .refused),
        (503, "reset_credential_unavailable", .refused),
        (502, "router_unauthorized", .refused),
        (503, "router_key_unavailable", .notSubmitted),
        (503, "router_unavailable", .notSubmitted),
        (503, "gateway_stopping", .notSubmitted),
        (503, "router_retry_later", .notSubmitted),
        (502, "router_request_refused", .refused),
        (500, "future_code", .unconfirmed),
        (504, "upstream_timeout", .unconfirmed),
        (400, "invalid_request", .refused),
        (504, nil, .unconfirmed),
        (503, nil, .unconfirmed),
        (404, nil, .unconfirmed)
    ] as [(Int, String?, ResetSubmissionCertainty)])
    func gatewayOwnsSubmissionCertainty(status: Int, code: String?, expected: ResetSubmissionCertainty) {
        #expect(ResetSubmissionCertainty.response(status: status, code: code) == expected)
    }

    @Test(arguments: [
        (URLError.Code.cannotFindHost, ResetSubmissionCertainty.notSubmitted),
        (.cannotConnectToHost, .notSubmitted),
        (.dnsLookupFailed, .notSubmitted),
        (.notConnectedToInternet, .notSubmitted),
        (.secureConnectionFailed, .notSubmitted),
        (.serverCertificateUntrusted, .notSubmitted),
        (.badURL, .refused),
        (.unsupportedURL, .refused),
        (.timedOut, .unconfirmed),
        (.networkConnectionLost, .unconfirmed),
        (.cancelled, .unconfirmed),
        (.cannotParseResponse, .unconfirmed)
    ])
    func onlyPossiblySubmittedTransportFailuresRetainTheKey(code: URLError.Code, expected: ResetSubmissionCertainty) {
        #expect(ResetSubmissionCertainty.transport(URLError(code)) == expected)
    }

    @Test @MainActor func refusedRetryCanBeForgottenWithoutClaimingItsOriginalOutcome() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = HostStorage(root: root)
        let redemptions = AccountResetRedemptions(storage: storage, provider: .codex, beginBackgroundExecution: { _ in {} })
        await redemptions.redeem(accountID: "one", accountName: "One", hostID: hostID, gatewayAccountID: "gateway-one", offer: offer("one"), operation: { _ in
            throw ResetRedemptionError.unconfirmed("Lost reply")
        }, refresh: {})
        let attempt = try #require(redemptions.states["one"]?.attempt)
        await redemptions.forget(accountID: "one")
        #expect(redemptions.states["one"]?.attempt == attempt)
        await redemptions.retry(accountID: "one", operation: { retried in
            #expect(retried == attempt)
            throw ResetRedemptionError.rejected("Account was removed")
        }, refresh: {})
        #expect(redemptions.states["one"]?.canForget == true)
        #expect(try await ResetRedemptionStore(storage: storage, provider: .codex).load()["one"] == attempt)
        await redemptions.forget(accountID: "one")
        #expect(redemptions.states["one"]?.message?.contains("still unknown") == true)
        #expect(try await ResetRedemptionStore(storage: storage, provider: .codex).load().isEmpty)
        redemptions.retainAccounts([])
        #expect(redemptions.states.isEmpty)
    }

    @Test @MainActor func retiringOnlyTheOwningHostCancelsItsAttemptAndReleasesExecution() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = HostStorage(root: root)
        var holds = 0
        var releases = 0
        let redemptions = AccountResetRedemptions(storage: storage, provider: .claude, beginBackgroundExecution: { _ in
            holds += 1
            return { releases += 1 }
        })
        let otherHost = UUID()
        redemptions.retainHosts([hostID, otherHost])
        let started = AsyncStream<String>.makeStream()
        var replies: [String: CheckedContinuation<AccountResetRedemptionResult, Never>] = [:]
        let first = Task {
            await redemptions.redeem(accountID: "one", accountName: "One", hostID: hostID, gatewayAccountID: "gateway-one", offer: offer("one"), operation: { _ in
                await withCheckedContinuation { continuation in
                    replies["one"] = continuation
                    started.continuation.yield("one")
                }
            }, refresh: {})
        }
        let second = Task {
            await redemptions.redeem(accountID: "two", accountName: "Two", hostID: otherHost, gatewayAccountID: "gateway-two", offer: offer("two"), operation: { _ in
                await withCheckedContinuation { continuation in
                    replies["two"] = continuation
                    started.continuation.yield("two")
                }
            }, refresh: {})
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()
        #expect(holds == 2)
        #expect(releases == 0)
        redemptions.retire(hostID: UUID())
        #expect(redemptions.states["one"]?.isSubmitting == true)
        #expect(redemptions.states["two"]?.isSubmitting == true)
        redemptions.retainHosts([otherHost])
        #expect(redemptions.states["one"]?.canRetry == true)
        #expect(redemptions.states["one"]?.canForget == false)
        #expect(redemptions.states["two"]?.isSubmitting == true)
        for reply in replies.values { reply.resume(returning: .init(outcome: .reset, reason: nil)) }
        await first.value
        await second.value
        #expect(releases == 2)
        #expect(redemptions.states["one"]?.canRetry == true)
        #expect(redemptions.states["two"] == .completed(.init(outcome: .reset, reason: nil)))
        let restored = AccountResetRedemptions(storage: storage, provider: .claude, beginBackgroundExecution: { _ in {} })
        await restored.restore()
        #expect(restored.states["one"] == redemptions.states["one"])
        redemptions.retainAccounts([])
        #expect(redemptions.states["one"]?.canRetry == true)
        await redemptions.retry(accountID: "one", operation: { _ in throw ResetRedemptionError.rejected("Account unavailable") }, refresh: {})
        await redemptions.forget(accountID: "one")
        redemptions.retainAccounts([])
        #expect(redemptions.states.isEmpty)
        #expect(try await ResetRedemptionStore(storage: storage, provider: .claude).load().isEmpty)
        started.continuation.finish()
    }

    @MainActor
    private func failure(_ gateways: [String],
                         _ send: (String) async throws -> AccountResetRedemptionResult) async -> ResetRedemptionError? {
        do {
            _ = try await ResetRedemptionFailover.submit(through: gateways, name: { $0 }, send)
            return nil
        } catch { return error as? ResetRedemptionError }
    }

    private func offer(_ id: String) -> AccountResetOffer {
        AccountResetOffer(id: id, title: "Full reset", remaining: 1, expiresAt: nil,
                          usableNow: nil, requiresLimit: nil, clears: nil)
    }
}
