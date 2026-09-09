import Foundation
#if os(macOS)
import LocalAuthentication
import Security
#endif

/// Marks the current task as started by an explicit user action (opening the panel, finishing onboarding,
/// changing a Claude login in Settings) rather than a background timer tick. A background read must never
/// surface the macOS "Allow/Deny" Keychain prompt with nobody there to answer it — CodexBar (this project's
/// sibling, see README) solves the same problem the same way: fail fast instead of prompting, and only let
/// user-initiated reads show the OS dialog.
public enum ProviderInteractionContext {
    @TaskLocal public static var userInitiated = false

    #if os(macOS)
    /// Every Keychain read in the process goes through here. Three layers, because the first two have each
    /// failed alone in production (0.3.1, 0.4.1):
    /// 1. `kSecUseAuthenticationUI`/`LAContext` flags only govern this one SecItem call.
    /// 2. The ACL preflight and lock check (`backgroundReadWouldPrompt`) decide whether to attempt a read at all.
    /// 3. `SecKeychainSetUserInteractionAllowed(false)` is the process-wide switch the legacy Keychain layer
    ///    consults for BOTH its dialogs (login-keychain unlock and item ACL). It is the only flag that also
    ///    covers the preflight's own `SecKeychainItemCopyAccess` calls, and the only one verified live to turn
    ///    an untrusted data read into an immediate `errSecAuthFailed` instead of a dialog. Off for the whole
    ///    process; on only around a user-initiated read.
    static func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: CFTypeRef?) {
        installProcessGuard()
        var result: CFTypeRef?
        if userInitiated {
            let status = allowingInteraction { SecItemCopyMatching(query as CFDictionary, &result) }
            return (status, result)
        }
        var query = query
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        return (SecItemCopyMatching(query as CFDictionary, &result), result)
    }

    /// Whether a background data read of this item could need a dialog: a locked login Keychain needs its
    /// unlock prompt for almost any access, and an ACL that does not trust this exact executable (signature,
    /// not path — a Developer ID release and a local Apple Development install are different identities to
    /// the Keychain, even for items this app created itself) needs the Allow/Deny one. Neither check ever
    /// requests the secret, so neither can itself prompt. Always false for a user-initiated read.
    static func backgroundReadWouldPrompt(service: String, account: String? = nil) -> Bool {
        guard !userInitiated else { return false }
        return isDefaultKeychainLocked() || KeychainAccessPreflight.checkGenericPassword(service: service, account: account).requiresInteraction
    }

    /// Pure status check — never reads or unlocks anything.
    static func isDefaultKeychainLocked() -> Bool {
        installProcessGuard()
        var keychain: SecKeychain?
        guard SecKeychainCopyDefault(&keychain) == errSecSuccess, let keychain else { return false }
        var status: SecKeychainStatus = 0
        guard SecKeychainGetStatus(keychain, &status) == errSecSuccess else { return false }
        return status & SecKeychainStatus(kSecUnlockStateStatus) == 0
    }

    /// Turns legacy Keychain UI off for the process. Called before any Security call in QuotaCore so the
    /// order in which call sites run cannot matter; idempotent.
    static func installProcessGuard() { _ = processGuard }
    private static let processGuard: Void = { _ = SecKeychainSetUserInteractionAllowed(false) }()

    /// Re-enables the process-wide switch for the duration of a Keychain call the user asked for (a first
    /// read that must be allowed to show Allow/Deny, saving a key typed into Settings). Depth-counted so
    /// nested or concurrent user-initiated calls do not switch it off under each other.
    static func allowingInteraction<T>(_ body: () throws -> T) rethrows -> T {
        interactionLock.withLock {
            interactionDepth += 1
            if interactionDepth == 1 { _ = SecKeychainSetUserInteractionAllowed(true) }
        }
        defer {
            interactionLock.withLock {
                interactionDepth -= 1
                if interactionDepth == 0 { _ = SecKeychainSetUserInteractionAllowed(false) }
            }
        }
        return try body()
    }

    private static let interactionLock = NSLock()
    private nonisolated(unsafe) static var interactionDepth = 0
    #endif
}
