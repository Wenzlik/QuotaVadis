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
    static let ownService = "cz.zmrhal.QuotaVadis.claude-oauth"

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

    // MARK: - Own Keychain storage (account = Claude Code service name)
    // Owning the item does not exempt reads from the ACL prompt: the item trusts the signature of the build that
    // created it, and a Developer ID release and a local Apple Development install are different signatures.

    private static func loadOwn(for service: String) -> ClaudeCredentials? {
        #if os(macOS)
        guard !ProviderInteractionContext.backgroundReadWouldPrompt(service: ownService, account: service) else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ownService,
            kSecAttrAccount as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let (status, item) = ProviderInteractionContext.copyMatching(query)
        guard status == errSecSuccess, let data = item as? Data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let token = obj["accessToken"] as? String else { return nil }
        return ClaudeCredentials(accessToken: token, refreshToken: obj["refreshToken"] as? String,
                                 expiresAt: (obj["expiresAt"] as? Double).map(Date.init(timeIntervalSince1970:)),
                                 subscriptionType: obj["subscriptionType"] as? String)
        #else
        return nil
        #endif
    }

    private static func saveOwn(_ creds: ClaudeCredentials, for service: String) {
        #if os(macOS)
        var payload: [String: Any] = ["accessToken": creds.accessToken]
        payload["refreshToken"] = creds.refreshToken
        payload["expiresAt"] = creds.expiresAt?.timeIntervalSince1970
        payload["subscriptionType"] = creds.subscriptionType
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        // Runs from background refreshes: with the process-wide no-UI switch a locked Keychain or an untrusted
        // signature makes the write fail quietly (the token is still returned to the caller) instead of prompting.
        ProviderInteractionContext.installProcessGuard()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ownService,
            kSecAttrAccount as String: service,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
        #endif
    }
}
