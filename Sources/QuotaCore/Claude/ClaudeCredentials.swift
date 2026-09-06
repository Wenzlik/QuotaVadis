import Foundation
#if os(macOS)
import Security
#endif

/// Reads the OAuth token Claude Code keeps in the login Keychain (`Claude Code-credentials`).
/// Claude Code owns and rotates that item; we never write to it.
public struct ClaudeCredentials: Sendable {
    let accessToken: String
    var refreshToken: String? = nil
    let expiresAt: Date?
    let subscriptionType: String?

    public static let keychainService = "Claude Code-credentials"

    /// One Keychain item Claude Code created: the default one or a `-<hash>` variant from a custom CLAUDE_CONFIG_DIR.
    public struct KeychainEntry: Sendable, Hashable, Identifiable {
        public let service: String
        public let created: Date?
        public let modified: Date?
        public var id: String { service }
        public var suffix: String { service.replacingOccurrences(of: ClaudeCredentials.keychainService, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
    }

    /// Attributes only, no secrets, so this never triggers an ACL prompt. Newest first.
    public static func keychainEntries() -> [KeychainEntry] {
        #if os(macOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let rows = result as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let service = row[kSecAttrService as String] as? String, service.hasPrefix(keychainService) else { return nil }
            return KeychainEntry(service: service, created: row[kSecAttrCreationDate as String] as? Date, modified: row[kSecAttrModificationDate as String] as? Date)
        }
        .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        #else
        return []
        #endif
    }

    static var credentialsFileURL: URL {
        let root = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.userHome.appendingPathComponent(".claude")
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

    /// `service` nil = Claude Code's default login; otherwise a specific Keychain item (another organization).
    static func load(service: String? = nil) throws -> ClaudeCredentials {
        if service == nil, let data = try? Data(contentsOf: credentialsFileURL) {
            return try parse(data)
        }
        #if os(macOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service ?? keychainService,
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
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: expiresMs.map { Date(timeIntervalSince1970: $0 / 1000) },
            subscriptionType: oauth["subscriptionType"] as? String)
    }
}
