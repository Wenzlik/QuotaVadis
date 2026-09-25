import Foundation
import Testing
@testable import QuotaCore

// Synthetic values only: nothing here is, or resembles, a real code or token.
private func attempt(_ state: String) -> ClaudeOwnLogin.Attempt {
    ClaudeOwnLogin.Attempt(url: URL(string: "https://example.invalid/\(state)")!, verifier: "verifier-\(state)", state: state)
}

private let fakeCreds = ClaudeCredentials(accessToken: "synthetic-access", refreshToken: "synthetic-refresh",
                                          expiresAt: .now.addingTimeInterval(3600), subscriptionType: nil)

@Test func pasteFormsAccepted() throws {
    let a = attempt("s1")
    #expect(try ClaudeOwnLogin.parse(paste: "abc#s1", attempt: a) == ("abc", "s1"))
    #expect(try ClaudeOwnLogin.parse(paste: "  abc \n", attempt: a) == ("abc", "s1"))
    #expect(try ClaudeOwnLogin.parse(paste: "https://example.invalid/callback?code=abc%23s1&x=1", attempt: a) == ("abc", "s1"))
}

@Test func pasteRejectsMismatchAndEmpty() {
    let a = attempt("s1")
    #expect(throws: ClaudeOwnLogin.LoginError.codeMismatch) { try ClaudeOwnLogin.parse(paste: "abc#other", attempt: a) }
    #expect(throws: ClaudeOwnLogin.LoginError.emptyCode) { try ClaudeOwnLogin.parse(paste: "   ", attempt: a) }
    #expect(throws: ClaudeOwnLogin.LoginError.emptyCode) { try ClaudeOwnLogin.parse(paste: "#s1", attempt: a) }
}

/// Records what the coordinator did, and lets a test hold an exchange open.
@MainActor
private final class Harness {
    var stored: [String] = []
    var opened: [URL] = []
    var connectedCalls = 0
    var storeFails = false
    var browserOpens = true
    var attempts = 0
    let gate = AsyncResult<Void>()
    var holdExchange = false
    var exchangeError: Error?

    func coordinator() -> ClaudeSignInCoordinator {
        let gate = gate
        let hold = holdExchange
        let error = exchangeError
        let c = ClaudeSignInCoordinator(
            makeAttempt: { [unowned self] in attempts += 1; return attempt("s\(attempts)") },
            exchange: { paste, attempt in
                if hold { try await gate.value() }
                if let error { throw error }
                _ = try ClaudeOwnLogin.parse(paste: paste, attempt: attempt)
                return fakeCreds
            },
            store: { [unowned self] creds in
                if storeFails { throw ClaudeOwnLogin.LoginError.keychainSaveFailed }
                stored.append(creds.accessToken)
            },
            openURL: { [unowned self] url in opened.append(url); return browserOpens })
        c.onConnected = { [unowned self] in connectedCalls += 1 }
        return c
    }
}

@MainActor @Test func connectsOnlyAfterStoreSucceeds() async {
    let h = Harness()
    let c = h.coordinator()
    c.start()
    #expect(c.phase == .waitingForCode)
    #expect(h.opened.count == 1)
    c.code = "abc#s1"
    await c.submit()
    #expect(c.phase == .connected)
    #expect(h.stored == ["synthetic-access"])
    #expect(h.connectedCalls == 1)
    #expect(c.code.isEmpty)
}

@MainActor @Test func failedKeychainWriteNeverConnects() async {
    let h = Harness()
    h.storeFails = true
    let c = h.coordinator()
    c.start()
    c.code = "abc#s1"
    await c.submit()
    #expect(c.phase == .waitingForCode)
    #expect(h.connectedCalls == 0)
    #expect(c.problem == ClaudeOwnLogin.LoginError.keychainSaveFailed.errorDescription)
}

@MainActor @Test func rejectedExchangeKeepsPreviousLogin() async {
    let h = Harness()
    h.exchangeError = ClaudeOwnLogin.LoginError.rejected
    let c = h.coordinator()
    c.start()
    c.code = "abc#s1"
    await c.submit()
    #expect(h.stored.isEmpty) // nothing replaced the existing login
    #expect(c.phase == .waitingForCode)
    #expect(c.problem != nil)
}

@MainActor @Test func cancelDuringExchangeDropsResult() async {
    let h = Harness()
    h.holdExchange = true
    let c = h.coordinator()
    c.start()
    c.code = "abc#s1"
    let submit = Task { await c.submit() }
    await Task.yield()
    #expect(c.phase == .exchanging)
    await c.submit() // duplicate Connect while one runs: ignored
    c.startOver()    // ignored while exchanging
    #expect(h.attempts == 1)
    c.cancel()
    h.gate.finish(.success(()))
    await submit.value
    #expect(c.phase == .idle)
    #expect(h.stored.isEmpty)
    #expect(h.connectedCalls == 0)
}

@MainActor @Test func startOverInvalidatesOldCode() async {
    let h = Harness()
    let c = h.coordinator()
    c.start()
    c.startOver()
    #expect(h.attempts == 2)
    c.code = "abc#s1" // code from the first browser tab
    await c.submit()
    #expect(c.phase == .waitingForCode)
    #expect(h.stored.isEmpty)
    c.reopenBrowser()
    #expect(h.opened.last == URL(string: "https://example.invalid/s2"))
    #expect(h.attempts == 2)
}

@MainActor @Test func browserFailureIsRecoverable() {
    let h = Harness()
    h.browserOpens = false
    let c = h.coordinator()
    c.start()
    #expect(c.phase == .waitingForCode)
    #expect(c.problem != nil)
    h.browserOpens = true
    c.reopenBrowser()
    #expect(c.problem == nil)
}

private struct AccountFetcher: UsageFetcher {
    let provider: ProviderID = .claude
    let account: String
    let gate: AsyncResult<Void>?
    func fetchRaw() async throws -> Data { Data() }
    func isAvailable() -> Bool { true }
    func fetch() async throws -> UsageSnapshot {
        if let gate { try await gate.value() }
        return UsageSnapshot(provider: .claude, account: account, plan: nil, windows: [])
    }
}

@Test func oldAccountFetchCannotOverwriteNewLogin() async {
    let gate = AsyncResult<Void>()
    let service = UsageService(fetchers: [AccountFetcher(account: "old", gate: gate)])
    let inFlight = Task { await service.refresh(timeout: 5) }
    try? await Task.sleep(for: .milliseconds(30))
    await service.setFetchers([AccountFetcher(account: "new", gate: nil)], invalidating: [.claude])
    gate.finish(.success(()))
    let stale = await inFlight.value
    #expect(stale["claude"] == nil)
    // The next refresh must not reuse the old pending fetch nor its throttle floor.
    let fresh = await service.refresh(timeout: 5)
    #expect(fresh["claude"]?.snapshot?.account == "new")
}
