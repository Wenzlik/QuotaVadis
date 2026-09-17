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
        let (status, result) = ProviderInteractionContext.copyMatching(query)
        guard status == errSecSuccess, let rows = result as? [[String: Any]] else { return [] }
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

    public static func isAvailable() -> Bool {
        if FileManager.default.fileExists(atPath: credentialsFileURL.path) { return true }
        #if os(macOS)
        // Presence check without reading the secret: no kSecReturnData, so no ACL prompt.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return ProviderInteractionContext.copyMatching(query).status == errSecSuccess
        #else
        return false
        #endif
    }

    /// The real guarantee against a prompt isn't any preflight check (all of them can, in theory, be fooled by
    /// a transient error at the wrong moment) — it's that we hit Claude Code's item as rarely as possible in
    /// the first place. Two caches in front of it: this process's memory, and [ClaudeTokenStore], our own
    /// Keychain item, which survives a quit, a reboot and a Sparkle update. A token is reused by both until it
    /// genuinely expires.
    ///
    /// A user-initiated read used to skip the cache, which meant every panel open with numbers older than 30 s
    /// went straight at Claude Code's item and could prompt (0.4.5). It no longer does: a valid token is a
    /// valid token no matter who asked for it, and `userInitiated` now only decides whether a read that must
    /// happen anyway is allowed to show the dialog. `force` is for the one case that really needs the source:
    /// the API rejected what we had.
    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cache: [String: ClaudeCredentials] = [:]

    /// A minute of headroom so a token that dies mid-request isn't handed out as fresh.
    private static func usable(_ creds: ClaudeCredentials?) -> ClaudeCredentials? {
        guard let creds, let expiresAt = creds.expiresAt, expiresAt > Date.now.addingTimeInterval(60) else { return nil }
        return creds
    }

    private static func cached(_ key: String) -> ClaudeCredentials? {
        usable(cacheLock.withLock { cache[key] })
    }

    private static func cache(_ creds: ClaudeCredentials, for key: String) {
        cacheLock.withLock { cache[key] = creds }
    }

    /// Forgets both copies of a token, so the next load goes back to Claude Code's item. Called when the usage
    /// API answers 401 — the only proof that what we cached is no longer good.
    public static func invalidate(service: String? = nil) {
        let key = service ?? keychainService
        cacheLock.withLock { cache[key] = nil }
        #if os(macOS)
        ClaudeTokenStore.delete(account: key)
        #endif
    }

    /// `service` nil = Claude Code's default login; otherwise a specific Keychain item (another organization).
    static func load(service: String? = nil, force: Bool = false) throws -> ClaudeCredentials {
        // A custom CLAUDE_CONFIG_DIR keeps the token in a plain file: no Keychain, so nothing to cache around.
        if service == nil, let data = try? Data(contentsOf: credentialsFileURL) { return try parse(data) }
        let cacheKey = service ?? keychainService
        if !force {
            if let cached = cached(cacheKey) { return cached }
            #if os(macOS)
            if let stored = usable(ClaudeTokenStore.load(account: cacheKey)) {
                cache(stored, for: cacheKey)
                return stored
            }
            #endif
        }
        let creds = try loadFresh(service: service)
        cache(creds, for: cacheKey)
        #if os(macOS)
        ClaudeTokenStore.save(creds, account: cacheKey)
        #endif
        return creds
    }

    private static func loadFresh(service: String?) throws -> ClaudeCredentials {
        #if os(macOS)
        let keychainService = service ?? keychainService
        // Background: only attempt the real read once the lock check and ACL preflight are clear; the process-wide
        // no-UI switch inside `copyMatching` then guarantees a wrong answer here fails instead of prompting.
        if ProviderInteractionContext.backgroundReadWouldPrompt(service: keychainService) { throw ProviderError.keychainDenied }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let (status, item) = ProviderInteractionContext.copyMatching(query)
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
