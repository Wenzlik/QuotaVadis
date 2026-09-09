import Foundation
#if os(macOS)
import Security
#endif

/// A claude.ai `sessionKey`, found in this order: manual value saved in Settings, Claude desktop app cookies,
/// Chrome profiles. Lets people without Claude Code see their limits.
public struct ClaudeWebSession: Sendable {
    public enum Source: String, Sendable { case manual, claudeDesktop, chrome }
    public let sessionKey: String
    public let source: Source
    /// Organization the desktop app / browser last used, when the cookie store says so.
    public let lastActiveOrg: String?

    static let manualService = "cz.zmrhal.QuotaVadis.claude-web-session"

    public static func isAvailable() -> Bool {
        hasManualKey() || ChromiumCookieStore.claudeDesktop.exists || !ChromiumCookieStore.chromeProfiles().isEmpty
    }

    public static func load() throws -> ClaudeWebSession? {
        if let manual = manualKey() { return ClaudeWebSession(sessionKey: manual, source: .manual, lastActiveOrg: nil) }
        var lastError: Error?
        let stores: [(ChromiumCookieStore, Source)] = [(.claudeDesktop, .claudeDesktop)] + ChromiumCookieStore.chromeProfiles().map { ($0, .chrome) }
        for (store, source) in stores where store.exists {
            do {
                if let key = try store.value(name: "sessionKey", domain: "claude.ai"), key.hasPrefix("sk-ant-") {
                    let org = try? store.value(name: "lastActiveOrg", domain: "claude.ai")
                    return ClaudeWebSession(sessionKey: key, source: source, lastActiveOrg: org)
                }
            } catch { lastError = error }
        }
        if let lastError { throw lastError }
        return nil
    }

    // MARK: - Manual session key (our own Keychain item)
    // "Our own" does not exempt it from the ACL prompt: the item trusts the signature of the build that created
    // it, and a Developer ID release and a local Apple Development install are different signatures.

    /// Presence only (attributes, no secret), so it is safe from any context.
    static func hasManualKey() -> Bool {
        #if os(macOS)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: manualService,
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        return ProviderInteractionContext.copyMatching(query).status == errSecSuccess
        #else
        return false
        #endif
    }

    /// The user only ever changes this by retyping it in Settings (`saveManualKey` clears the cache then), so
    /// a successful read is cached for the process's lifetime — at most one background Keychain touch, ever.
    private static let manualKeyCacheLock = NSLock()
    private nonisolated(unsafe) static var manualKeyCache: String??

    public static func manualKey() -> String? {
        #if os(macOS)
        if let cached = manualKeyCacheLock.withLock({ manualKeyCache }) { return cached }
        guard !ProviderInteractionContext.backgroundReadWouldPrompt(service: manualService) else { return nil }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: manualService,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        let (status, item) = ProviderInteractionContext.copyMatching(query)
        let key = (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
        if status == errSecSuccess { manualKeyCacheLock.withLock { manualKeyCache = key } }
        return key
        #else
        return nil
        #endif
    }

    /// Only ever called for a key the user just typed into Settings, so a prompt here is expected and answerable.
    public static func saveManualKey(_ key: String?) {
        #if os(macOS)
        ProviderInteractionContext.installProcessGuard()
        ProviderInteractionContext.allowingInteraction {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: manualService]
            SecItemDelete(query as CFDictionary)
            guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
            var add = query; add[kSecValueData as String] = Data(key.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
        manualKeyCacheLock.withLock { manualKeyCache = nil }
        #endif
    }
}
