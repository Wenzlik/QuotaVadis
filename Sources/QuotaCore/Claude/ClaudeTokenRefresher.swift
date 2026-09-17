import Foundation
#if os(macOS)
import Security
#endif

/// Refreshes an expired Claude OAuth token for the extra organization profiles QuotaVadis owns.
/// The primary Claude Code login is never refreshed here: Claude Code owns that refresh token and a rotated
/// token would break its next session. Refreshed tokens go to QuotaVadis's own Keychain item, never back
/// into Claude Code's.
enum ClaudeTokenRefresher {
    static let endpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// Claude Code's public OAuth client id (same one CodexBar uses).
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double
        enum CodingKeys: String, CodingKey { case accessToken = "access_token"; case refreshToken = "refresh_token"; case expiresIn = "expires_in" }
    }

    /// Best current credentials for a profile: our refreshed copy when it is newer, else Claude Code's item.
    static func current(service: String) throws -> ClaudeCredentials {
        let original = try ClaudeCredentials.load(service: service)
        if let cached = loadOwn(for: service), (cached.expiresAt ?? .distantPast) > (original.expiresAt ?? .distantPast) {
            return cached
        }
        return original
    }

    static func refresh(service: String, using creds: ClaudeCredentials) async throws -> ClaudeCredentials {
        guard let refreshToken = creds.refreshToken, !refreshToken.isEmpty else { throw ProviderError.tokenExpired }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID),
        ]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await HTTP.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw status == 400 || status == 401 ? ProviderError.unauthorized : ProviderError.http(status) }
        let token = try HTTP.decode(TokenResponse.self, from: data)
        let fresh = ClaudeCredentials(accessToken: token.accessToken, refreshToken: token.refreshToken ?? refreshToken,
                                      expiresAt: Date(timeIntervalSinceNow: token.expiresIn), subscriptionType: creds.subscriptionType)
        saveOwn(fresh, for: service)
        return fresh
    }

    // MARK: - Own Keychain storage
    // A refreshed token goes to [ClaudeTokenStore], the item this app owns, under the Claude Code service it
    // was minted from. Owning an item is what makes it prompt-free to read; Claude Code's own item never is.

    private static func loadOwn(for service: String) -> ClaudeCredentials? { ClaudeTokenStore.load(account: service) }

    private static func saveOwn(_ creds: ClaudeCredentials, for service: String) { ClaudeTokenStore.save(creds, account: service) }
}
