import Foundation
import Observation

/// One owner for a QuotaVadis Claude sign-in, shared by the welcome window and Settings so both show the same
/// attempt: `idle → waitingForCode → exchanging → connected`, with a problem line for recoverable failures.
///
/// The code is copied out of the browser by hand (see `ClaudeOwnLogin`), so the attempt has to outlive the
/// click that opened the browser. What this type guarantees on top of the raw exchange:
/// - "Open browser again" reuses the attempt; "Start over" and cancel invalidate it, and a completion that
///   belongs to an invalidated attempt is dropped *before* it can replace the stored login.
/// - A second Connect while one exchange runs is ignored.
/// - Connected means the Keychain write succeeded; a failed write leaves the previous login untouched.
/// - The pasted code and the PKCE secrets are cleared on completion, cancel and restart, and never logged.
@MainActor
@Observable
public final class ClaudeSignInCoordinator {
    public enum Phase: Equatable, Sendable {
        case idle
        case waitingForCode
        case exchanging
        case connected
    }

    public private(set) var phase: Phase = .idle
    /// Bound to the paste field; cleared whenever the attempt ends.
    public var code = ""
    /// Why the last step did not go through, shown under the field. nil when nothing is wrong.
    public private(set) var problem: String?

    public var canSubmit: Bool {
        phase == .waitingForCode && !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Called once the new login is stored, before `phase` turns `.connected` observers see it.
    public var onConnected: (@MainActor () -> Void)?

    typealias Exchange = @Sendable (String, ClaudeOwnLogin.Attempt) async throws -> ClaudeCredentials
    typealias Store = @MainActor (ClaudeCredentials) throws -> Void

    private var attempt: ClaudeOwnLogin.Attempt?
    private var generation = 0
    private let makeAttempt: () -> ClaudeOwnLogin.Attempt
    private let exchange: Exchange
    private let store: Store
    private let openURL: @MainActor (URL) -> Bool

    /// `openURL` returns whether the browser actually opened (NSWorkspace.open's result on the Mac).
    public convenience init(openURL: @escaping @MainActor (URL) -> Bool) {
        self.init(makeAttempt: ClaudeOwnLogin.begin,
                  exchange: { try await ClaudeOwnLogin.exchange(paste: $0, attempt: $1) },
                  store: { try ClaudeOwnLogin.store($0) },
                  openURL: openURL)
    }

    init(makeAttempt: @escaping () -> ClaudeOwnLogin.Attempt, exchange: @escaping Exchange, store: @escaping Store,
         openURL: @escaping @MainActor (URL) -> Bool) {
        self.makeAttempt = makeAttempt; self.exchange = exchange; self.store = store; self.openURL = openURL
    }

    /// "Continue in browser": a fresh attempt, then the authorization page.
    public func start() {
        guard phase != .exchanging else { return }
        invalidate()
        let fresh = makeAttempt()
        attempt = fresh
        phase = .waitingForCode
        open(fresh.url)
    }

    /// "Open browser again": same verifier and state, so a code from either tab still works.
    public func reopenBrowser() {
        guard phase == .waitingForCode, let attempt else { return }
        problem = nil
        open(attempt.url)
    }

    /// "Start over": the old attempt's code no longer counts.
    public func startOver() {
        guard phase != .exchanging else { return }
        start()
    }

    /// Leaves the flow. Safe at any point: an exchange still in flight finishes into nothing.
    public func cancel() {
        invalidate()
        phase = .idle
    }

    /// Back to `idle` after a success has been shown, e.g. before offering Reconnect again.
    public func acknowledge() {
        if phase == .connected { phase = .idle }
    }

    public func submit() async {
        guard canSubmit, let attempt else { return }
        let paste = code
        let current = generation
        phase = .exchanging
        problem = nil
        do {
            let creds = try await exchange(paste, attempt)
            // Cancelled or restarted while the network call ran: the user no longer wants this login.
            guard current == generation else { return }
            try store(creds)
            self.attempt = nil
            code = ""
            onConnected?()
            phase = .connected
        } catch {
            guard current == generation else { return }
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .waitingForCode
        }
    }

    private func open(_ url: URL) {
        if !openURL(url) {
            problem = "The browser did not open. Choose Open browser again, or check your default browser in System Settings."
        } else {
            problem = nil
        }
    }

    private func invalidate() {
        generation += 1
        attempt = nil
        code = ""
        problem = nil
    }
}
