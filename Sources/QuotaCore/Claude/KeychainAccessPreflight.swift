import Foundation
#if os(macOS)
import Darwin
import Security
#endif

/// Whether reading a Keychain generic-password item would need the OS "Allow/Deny" prompt — checked WITHOUT
/// ever requesting the secret (`kSecReturnData`). CodexBar's own comment on this exact technique: "some macOS
/// configurations have been observed to show the legacy keychain prompt even with UI-fail" — meaning
/// `ProviderInteractionContext`'s `kSecUseAuthenticationUIFail` flag alone is not reliable (confirmed: it did
/// not stop a real prompt from firing here during a background refresh). This inspects the item's decrypt ACL
/// directly instead — a stable, prompt-free answer — using the same private-but-stable Security APIs CodexBar
/// documents (`SecKeychainItemCopyAccess`/`SecAccessCopyMatchingACLList`/`SecACLCopyContents`).
public enum KeychainAccessPreflight {
    public enum Outcome: Sendable {
        case allowed
        /// Readable, but the decrypt ACL does not trust this executable.
        case interactionRequired
        /// Could not be inspected (locked keychain, ACL introspection failed) — not a stable answer.
        case temporarilyUnavailable
        case notFound
        case failure(OSStatus)

        public var requiresInteraction: Bool {
            switch self {
            case .interactionRequired, .temporarilyUnavailable: true
            case .allowed, .failure, .notFound: false
            }
        }
    }

    public static func checkGenericPassword(service: String, account: String? = nil) -> Outcome {
        #if os(macOS)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // No kSecReturnData: this must never be able to prompt, so the secret is never requested.
            kSecReturnAttributes as String: true,
            kSecReturnRef as String: true,
        ]
        ProviderInteractionContext.suppressUIIfBackground(&query)
        if let account { query[kSecAttrAccount as String] = account }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let attributes = result as? [String: Any], let ref = attributes[kSecValueRef as String] else {
                return .temporarilyUnavailable
            }
            let item = unsafeDowncast(ref as AnyObject, to: SecKeychainItem.self)
            switch evaluateDecryptACL(item: item) {
            case .allowed: return .allowed
            case .rejected: return .interactionRequired
            case .indeterminate: return .temporarilyUnavailable
            }
        case errSecItemNotFound: return .notFound
        case errSecInteractionNotAllowed: return .temporarilyUnavailable
        default: return .failure(status)
        }
        #else
        return .notFound
        #endif
    }

    #if os(macOS)
    private enum DecryptACLEvaluation: Equatable { case allowed, rejected, indeterminate }

    /// `.rejected` only once every ACL entry's trusted-application list was inspected and none matched this
    /// executable's own path — a stable answer. Anything inspection couldn't complete stays `.indeterminate`.
    private static func evaluateDecryptACL(item: SecKeychainItem) -> DecryptACLEvaluation {
        guard let copyItemAccess = securityFunction("SecKeychainItemCopyAccess", as: SecKeychainItemCopyAccessFn.self),
              let copyMatchingACLs = securityFunction("SecAccessCopyMatchingACLList", as: SecAccessCopyMatchingACLListFn.self),
              let copyACLContents = securityFunction("SecACLCopyContents", as: SecACLCopyContentsFn.self),
              let validatePath = securityFunction("SecTrustedApplicationValidateWithPath", as: SecTrustedApplicationValidateWithPathFn.self)
        else { return .indeterminate }

        var access: SecAccess?
        guard copyItemAccess(item, &access) == errSecSuccess, let access,
              let rawACLs = copyMatchingACLs(access, kSecACLAuthorizationDecrypt)?.takeRetainedValue(),
              let acls = rawACLs as? [SecACL], !acls.isEmpty
        else { return .indeterminate }

        guard let currentPath = Bundle.main.executablePath else { return .indeterminate }
        var inspectionIncomplete = false
        for acl in acls {
            var applications: CFArray?
            var description: CFString?
            var selector = SecKeychainPromptSelector()
            guard copyACLContents(acl, &applications, &description, &selector) == errSecSuccess else {
                inspectionIncomplete = true
                continue
            }
            // A non-zero prompt selector means the ACL can require authentication regardless of the caller's
            // signature; a background preflight cannot prove that safe, so treat it as requiring interaction.
            guard selector.rawValue == 0 else { continue }
            guard let applications else { return .allowed }   // nil application list = unrestricted
            guard let trustedApplications = applications as? [SecTrustedApplication] else {
                inspectionIncomplete = true
                continue
            }
            let matched = trustedApplications.contains { app in
                currentPath.withCString { validatePath(app, $0) } == errSecSuccess
            }
            if matched { return .allowed }
        }
        return inspectionIncomplete ? .indeterminate : .rejected
    }

    private typealias SecKeychainItemCopyAccessFn = @convention(c) (SecKeychainItem, UnsafeMutablePointer<SecAccess?>) -> OSStatus
    private typealias SecAccessCopyMatchingACLListFn = @convention(c) (SecAccess, CFTypeRef) -> Unmanaged<CFArray>?
    private typealias SecACLCopyContentsFn = @convention(c) (
        SecACL, UnsafeMutablePointer<CFArray?>, UnsafeMutablePointer<CFString?>, UnsafeMutablePointer<SecKeychainPromptSelector>) -> OSStatus
    private typealias SecTrustedApplicationValidateWithPathFn = @convention(c) (SecTrustedApplication, UnsafePointer<CChar>) -> OSStatus

    private static func securityFunction<T>(_ name: String, as _: T.Type) -> T? {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
              let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
    #endif
}
