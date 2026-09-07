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
        manualKey() != nil || ChromiumCookieStore.claudeDesktop.exists || !ChromiumCookieStore.chromeProfiles().isEmpty
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

    public static func manualKey() -> String? {
        #if os(macOS)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: manualService,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #else
        return nil
        #endif
    }

    public static func saveManualKey(_ key: String?) {
        #if os(macOS)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: manualService]
        SecItemDelete(query as CFDictionary)
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
        var add = query; add[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(add as CFDictionary, nil)
        #endif
    }
}
