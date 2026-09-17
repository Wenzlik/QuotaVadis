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

    /// Exchanges what the user pasted for tokens and stores them. The callback page hands out `code#state`;
    /// people paste it with either half missing or with the whole URL around it, so all three are accepted.
    public static func complete(paste: String, attempt: Attempt) async throws {
        let trimmed = paste.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProviderError.notLoggedIn }
        let raw = URLComponents(string: trimmed)?.queryItems?.first { $0.name == "code" }?.value ?? trimmed
        let parts = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let code = String(parts[0])
        let state = parts.count > 1 ? String(parts[1]) : attempt.state
        guard !code.isEmpty, state == attempt.state else { throw ProviderError.decoding("that code does not match this sign-in — start again") }

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
        let (data, response) = try await HTTP.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw status == 400 || status == 401 ? ProviderError.unauthorized : ProviderError.http(status) }
        let token = try HTTP.decode(ClaudeTokenRefresher.TokenResponse.self, from: data)
        ClaudeTokenStore.save(ClaudeCredentials(accessToken: token.accessToken, refreshToken: token.refreshToken,
                                                expiresAt: Date(timeIntervalSinceNow: token.expiresIn), subscriptionType: nil),
                              account: account, replacing: true)
    }

    public static var isSignedIn: Bool { ClaudeTokenStore.load(account: account) != nil }

    public static func signOut() { ClaudeTokenStore.delete(account: account) }

    /// The credentials to use when this login exists, refreshing them first if they are about to expire.
    /// nil means no own login is set up, and the caller falls back to Claude Code's item.
    static func credentials() async throws -> ClaudeCredentials? {
        guard let stored = ClaudeTokenStore.load(account: account) else { return nil }
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
