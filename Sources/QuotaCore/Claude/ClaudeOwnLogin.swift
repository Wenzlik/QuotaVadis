import Foundation
import CryptoKit
import Security

/// QuotaVadis's own Claude login: a sign-in of its own, independent of Claude Code's.
///
/// Every other Claude path in this app borrows someone else's credentials — Claude Code's Keychain item, a
/// browser's cookie store — and borrowing is what makes the Keychain dialog unavoidable. Those items belong to
/// other apps, their ACLs do not trust us, and Claude Code replaces its item on every token rotation, so an
/// "Always Allow" grant dies again within a day.
///
/// Signing in here ends that: the refresh token is ours, it lives in [ClaudeTokenStore] (an item this app
/// created, whose ACL trusts this app), and a new access token is minted from it over the network. Nothing in
/// this path ever reads an item another app owns, so nothing in it can prompt.
///
/// The flow is the OAuth PKCE authorization-code grant, with the code copied out of the browser by hand rather
/// than caught on a redirect: a menu bar app has no URL scheme registered with Anthropic, and the code-copy
/// callback page is the same one the Claude Code CLI uses for its own login.
public enum ClaudeOwnLogin {
    static let account = "cz.zmrhal.QuotaVadis.own-login"
    static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    static let scopes = "org:create_api_key user:profile user:inference"

    /// One sign-in attempt: the page to open, plus the PKCE verifier and state the paste is checked against.
    /// Held by the UI between opening the browser and the user pasting the code back.
    public struct Attempt: Sendable {
        public let url: URL
        let verifier: String
        let state: String
    }

    public static func begin() -> Attempt {
        let verifier = randomURLSafeString()
        let state = randomURLSafeString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        var components = URLComponents(string: "https://claude.ai/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: ClaudeTokenRefresher.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return Attempt(url: components.url!, verifier: verifier, state: state)
    }

    /// Why an explicit sign-in did not end connected. Messages are shown as-is under the paste field.
    public enum LoginError: Error, LocalizedError, Equatable, Sendable {
        case emptyCode
        case codeMismatch
        case rejected
        case exchange(String)
        case keychainSaveFailed

        public var errorDescription: String? {
            switch self {
            case .emptyCode: "Paste the code Claude showed you."
            case .codeMismatch: "That code belongs to a different sign-in. Choose Start over and try again."
            case .rejected: "Claude did not accept that code. Codes work once and expire quickly — choose Start over."
            case .exchange(let why): "Could not reach Claude: \(why)"
            case .keychainSaveFailed: "Signed in, but the login could not be saved to the Keychain. Unlock the Mac's Keychain and try again."
            }
        }
    }

    /// Splits what the user pasted into the code and state to send. The callback page hands out `code#state`;
    /// people paste it with either half missing or with the whole URL around it, so all three are accepted.
    /// A bare code carries no state of its own and is sent with this attempt's.
    static func parse(paste: String, attempt: Attempt) throws(LoginError) -> (code: String, state: String) {
        let trimmed = paste.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .emptyCode }
        let raw = URLComponents(string: trimmed)?.queryItems?.first { $0.name == "code" }?.value ?? trimmed
        let parts = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let code = String(parts[0])
        let state = parts.count > 1 ? String(parts[1]) : attempt.state
        guard !code.isEmpty else { throw .emptyCode }
        guard state == attempt.state else { throw .codeMismatch }
        return (code, state)
    }

    /// Trades the pasted code for tokens. Stores nothing: the caller decides whether the attempt is still
    /// current before `store` replaces whatever login is there now.
    static func exchange(paste: String, attempt: Attempt) async throws -> ClaudeCredentials {
        let (code, state) = try parse(paste: paste, attempt: attempt)
        var request = URLRequest(url: ClaudeTokenRefresher.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": ClaudeTokenRefresher.clientID,
            "redirect_uri": redirectURI,
            "code_verifier": attempt.verifier,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, response: URLResponse
        do { (data, response) = try await HTTP.session.data(for: request) }
        catch { throw LoginError.exchange(error.localizedDescription) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw status == 400 || status == 401 ? LoginError.rejected : LoginError.exchange("HTTP \(status)") }
        let token = try HTTP.decode(ClaudeTokenRefresher.TokenResponse.self, from: data)
        return ClaudeCredentials(accessToken: token.accessToken, refreshToken: token.refreshToken,
                                 expiresAt: Date(timeIntervalSinceNow: token.expiresIn), subscriptionType: nil)
    }

    /// Replaces the stored login with a fresh one. The user just signed in, so the write may show the
    /// Keychain's own UI (a locked login keychain); a write that still fails is reported, never swallowed —
    /// "connected" is only true once the login is really on disk.
    static func store(_ creds: ClaudeCredentials) throws(LoginError) {
        #if os(macOS)
        let saved = ProviderInteractionContext.allowingInteraction { ClaudeTokenStore.save(creds, account: account, replacing: true) }
        guard saved else { throw .keychainSaveFailed }
        #else
        throw .keychainSaveFailed
        #endif
    }

    /// Exchange and store in one go, for callers without a UI attempt to guard (none in the app itself).
    public static func complete(paste: String, attempt: Attempt) async throws {
        try store(try await exchange(paste: paste, attempt: attempt))
    }

    /// Whether a QuotaVadis login is stored, from the item's attributes alone: never reads the secret, so it
    /// cannot prompt and it stays true while the Keychain is locked or the ACL needs a fresh grant.
    public static var isSignedIn: Bool {
        #if os(macOS)
        if case .notFound = KeychainAccessPreflight.checkGenericPassword(service: ClaudeTokenStore.service, account: account) { return false }
        return true
        #else
        return false
        #endif
    }

    public static func signOut() { ClaudeTokenStore.delete(account: account) }

    /// The credentials to use when this login exists, refreshing them first if they are about to expire.
    /// nil means no own login is set up, and the caller falls back to Claude Code's item.
    /// A login that exists but cannot be read right now is an error, not a reason to go borrow Claude Code's.
    static func credentials() async throws -> ClaudeCredentials? {
        guard let stored = ClaudeTokenStore.load(account: account) else {
            guard isSignedIn else { return nil }
            throw ProviderError.keychainDenied
        }
        guard let expiry = stored.expiresAt, expiry > .now.addingTimeInterval(60) else {
            return try await ClaudeTokenRefresher.refresh(service: account, using: stored)
        }
        return stored
    }

    private static func randomURLSafeString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }
}

extension Data {
    /// base64url without padding, as PKCE and OAuth state want it.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
