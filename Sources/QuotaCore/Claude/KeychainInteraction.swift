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
    /// Adds flags that make a Keychain query fail immediately (`errSecInteractionNotAllowed`) instead of
    /// showing UI, unless this task is user-initiated. Cheap no-op on the happy path where the item's ACL
    /// already grants this app access: the query still succeeds, just without ever being able to prompt.
    static func suppressUIIfBackground(_ query: inout [String: Any]) {
        guard !userInitiated else { return }
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    }
    #endif
}
