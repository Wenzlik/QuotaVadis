import Foundation
#if os(macOS)
import Security
#endif

/// Claude tokens in a Keychain item QuotaVadis itself created, keyed by the Claude Code service the token
/// came from (`Claude Code-credentials`, or a `-<hash>` variant).
///
/// Claude Code's own item is the one we can never stop being asked about: it rotates, and a rotation replaces
/// the item, which throws away the ACL entry an "Always Allow" had added — that is why the prompt keeps coming
/// back after a day of quiet. Our item carries our own ACL, so reading it never prompts. Every successful read
/// of Claude Code's item leaves a copy here, and the copy answers every later read until the token in it
/// actually expires, so the prompt-capable read happens once per token lifetime instead of once per launch.
enum ClaudeTokenStore {
    /// Historic name: the item started out holding only the tokens the refresher minted for extra profiles.
    /// Keeping it means existing installs keep their stored profile tokens.
    static let service = "cz.zmrhal.QuotaVadis.claude-oauth"

    static func load(account: String) -> ClaudeCredentials? {
        #if os(macOS)
        guard !ProviderInteractionContext.backgroundReadWouldPrompt(service: service, account: account) else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let (status, item) = ProviderInteractionContext.copyMatching(query)
        guard status == errSecSuccess, let data = item as? Data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["accessToken"] as? String else { return nil }
        return ClaudeCredentials(accessToken: token, refreshToken: obj["refreshToken"] as? String,
                                 expiresAt: (obj["expiresAt"] as? Double).map(Date.init(timeIntervalSince1970:)),
                                 subscriptionType: obj["subscriptionType"] as? String)
        #else
        return nil
        #endif
    }

    /// Runs from background refreshes: with the process-wide no-UI switch a locked Keychain or an untrusted
    /// signature makes the write fail quietly (the token is still returned to the caller) instead of prompting.
    /// `replacing` skips the newer-wins guard, for a fresh sign-in that is authoritative by definition.
    static func save(_ creds: ClaudeCredentials, account: String, replacing: Bool = false) {
        #if os(macOS)
        var payload: [String: Any] = ["accessToken": creds.accessToken]
        payload["refreshToken"] = creds.refreshToken
        payload["expiresAt"] = creds.expiresAt?.timeIntervalSince1970
        payload["subscriptionType"] = creds.subscriptionType
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        // Never trade a newer token for an older one: both the refresher's minted tokens and plain copies of
        // Claude Code's item land in the same slot, and they can arrive in either order.
        if !replacing, let stored = load(account: account),
           (stored.expiresAt ?? .distantPast) >= (creds.expiresAt ?? .distantPast) { return }
        ProviderInteractionContext.installProcessGuard()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            // Our copy is only useful while this Mac is unlocked and it is always re-derivable from Claude
            // Code's item, so it never needs to leave the device or survive in a locked state.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
        #endif
    }

    /// Drops our copy after the API has rejected the token in it, so the next read goes back to the source.
    static func delete(account: String) {
        #if os(macOS)
        ProviderInteractionContext.installProcessGuard()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        #endif
    }
}
