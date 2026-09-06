import Foundation
#if os(macOS)
import Security
#endif

/// Reads the OAuth token Claude Code keeps in the login Keychain (`Claude Code-credentials`).
/// Claude Code owns and rotates that item; we never write to it.
struct ClaudeCredentials: Sendable {
    let accessToken: String
    let expiresAt: Date?
    let subscriptionType: String?

    static let keychainService = "Claude Code-credentials"

    static var credentialsFileURL: URL {
        let root = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return root.appendingPathComponent(".credentials.json")
    }

    static func isAvailable() -> Bool {
        if FileManager.default.fileExists(atPath: credentialsFileURL.path) { return true }
        #if os(macOS)
        // Presence check without reading the secret: no kSecReturnData, so no ACL prompt.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
        #else
        return false
        #endif
    }

    static func load() throws -> ClaudeCredentials {
        if let data = try? Data(contentsOf: credentialsFileURL) {
            return try parse(data)
        }
        #if os(macOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw ProviderError.notLoggedIn }
            return try parse(data)
        case errSecItemNotFound:
            throw ProviderError.notLoggedIn
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            throw ProviderError.keychainDenied
        default:
            throw ProviderError.keychainDenied
        }
        #else
        throw ProviderError.notInstalled
        #endif
    }

    static func parse(_ data: Data) throws -> ClaudeCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.decoding("credentials are not JSON")
        }
        // Claude Code 2.1.x may leave only `mcpOAuth` in the item after a logout.
        guard let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw ProviderError.notLoggedIn
        }
        let expiresMs = oauth["expiresAt"] as? Double
        return ClaudeCredentials(
            accessToken: token,
            expiresAt: expiresMs.map { Date(timeIntervalSince1970: $0 / 1000) },
            subscriptionType: oauth["subscriptionType"] as? String)
    }
}
