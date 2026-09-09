import Foundation
#if os(macOS)
import Darwin
import LocalAuthentication
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

        /// `.failure` fails CLOSED (treated as requiring interaction): an unexpected status here — most
        /// plausible right after wake, before securityd has settled — must never be read as "safe to
        /// proceed," or the real query right behind it could be the one that actually prompts.
        public var requiresInteraction: Bool {
            switch self {
            case .interactionRequired, .temporarilyUnavailable, .failure: true
            case .allowed, .notFound: false
            }
        }
    }

    public static func checkGenericPassword(service: String, account: String? = nil) -> Outcome {
        #if os(macOS)
        // Always no-UI, whatever the task context: a preflight must never be the call that prompts.
        ProviderInteractionContext.installProcessGuard()
        let context = LAContext()
        context.interactionNotAllowed = true
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // No kSecReturnData: this must never be able to prompt, so the secret is never requested.
            kSecReturnAttributes as String: true,
            kSecReturnRef as String: true,
            kSecUseAuthenticationContext as String: context,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        if let account { query[kSecAttrAccount as String] = account }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let attributes = result as? [String: Any], let ref = attributes[kSecValueRef as String],
                  CFGetTypeID(ref as AnyObject) == SecKeychainItemGetTypeID() else {
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
    enum DecryptACLEvaluation: Equatable { case allowed, rejected, indeterminate }

    /// One ACL entry, given how each of its trusted applications validated against this executable (nil list =
    /// the entry does not restrict callers). Same rules as CodexBar's helper of the same name.
    static func evaluateDecryptACL(trustedApplicationValidationStatuses: [OSStatus?]?,
                                   promptSelector: SecKeychainPromptSelector) -> DecryptACLEvaluation {
        // Any non-zero selector can require authentication based on the caller's signature state; a background
        // preflight cannot prove that safe, so fail closed.
        guard promptSelector.rawValue == 0 else { return .rejected }
        guard let trustedApplicationValidationStatuses else { return .allowed }
        // At least one stored code-signing requirement must validate against the invoking executable. A path
        // match alone is insufficient: legacy ACLs keep an old build's signature at the same path and still
        // show UI (seen here: two `/Applications/QuotaVadis.app` entries on one item, only one validating).
        if trustedApplicationValidationStatuses.contains(errSecSuccess) { return .allowed }
        // The validator reports a completed signature mismatch as CSSMERR_CSP_VERIFY_FAILED — a stable
        // rejection. A missing symbol or any other error cannot establish that the ACL rejects this executable.
        return trustedApplicationValidationStatuses.allSatisfy { $0 == OSStatus(CSSMERR_CSP_VERIFY_FAILED) } ? .rejected : .indeterminate
    }

    /// `.rejected` only once every ACL entry was inspected and none trusts this executable — a stable answer.
    /// Anything inspection couldn't complete stays `.indeterminate`.
    private static func evaluateDecryptACL(item: SecKeychainItem) -> DecryptACLEvaluation {
        guard let copyItemAccess = securityFunction("SecKeychainItemCopyAccess", as: SecKeychainItemCopyAccessFn.self),
              let copyMatchingACLs = securityFunction("SecAccessCopyMatchingACLList", as: SecAccessCopyMatchingACLListFn.self),
              let copyACLContents = securityFunction("SecACLCopyContents", as: SecACLCopyContentsFn.self)
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
            guard let applications else {
                if evaluateDecryptACL(trustedApplicationValidationStatuses: nil, promptSelector: selector) == .allowed { return .allowed }
                continue
            }
            guard let trustedApplications = applications as? [SecTrustedApplication] else {
                inspectionIncomplete = true
                continue
            }
            let statuses = trustedApplications.map { trustedApplication($0, validatesExecutableAt: currentPath) }
            switch evaluateDecryptACL(trustedApplicationValidationStatuses: statuses, promptSelector: selector) {
            case .allowed: return .allowed
            case .indeterminate: inspectionIncomplete = true
            case .rejected: break
            }
        }
        return inspectionIncomplete ? .indeterminate : .rejected
    }

    private static func trustedApplication(_ application: SecTrustedApplication, validatesExecutableAt path: String) -> OSStatus? {
        guard let validate = securityFunction("SecTrustedApplicationValidateWithPath", as: SecTrustedApplicationValidateWithPathFn.self) else { return nil }
        return path.withCString { validate(application, $0) }
    }

    // Signatures checked against the macOS SDK headers (SecKeychainItem.h, SecAccess.h, SecACL.h,
    // SecTrustedApplication.h); SecKeychainPromptSelector is CF_OPTIONS(uint16).
    private typealias SecKeychainItemCopyAccessFn = @convention(c) (SecKeychainItem, UnsafeMutablePointer<SecAccess?>) -> OSStatus
    private typealias SecAccessCopyMatchingACLListFn = @convention(c) (SecAccess, CFTypeRef) -> Unmanaged<CFArray>?
    private typealias SecACLCopyContentsFn = @convention(c) (
        SecACL, UnsafeMutablePointer<CFArray?>, UnsafeMutablePointer<CFString?>, UnsafeMutablePointer<SecKeychainPromptSelector>) -> OSStatus
    private typealias SecTrustedApplicationValidateWithPathFn = @convention(c) (SecTrustedApplication, UnsafePointer<CChar>) -> OSStatus

    private nonisolated(unsafe) static let securityFrameworkHandle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW)

    private static func securityFunction<T>(_ name: String, as _: T.Type) -> T? {
        guard let securityFrameworkHandle, let symbol = dlsym(securityFrameworkHandle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
    #endif
}
