import Foundation

/// Where a provider's login comes from and how long it is valid. Reads the same sources the fetchers use.
public struct CredentialStatus: Sendable, Hashable {
    public var source: String
    public var expiresAt: Date?
    public var problem: String?

    public static func claude(service: String? = nil) -> CredentialStatus {
        let source = service.map { "Keychain item \($0)" } ?? (FileManager.default.fileExists(atPath: ClaudeCredentials.credentialsFileURL.path)
            ? "~/.claude/.credentials.json" : "Keychain item \(ClaudeCredentials.keychainService)")
        guard ClaudeCredentials.isAvailable() || service != nil else { return CredentialStatus(source: source, expiresAt: nil, problem: "Claude Code is not logged in on this Mac") }
        do {
            let creds: ClaudeCredentials
            if let service { creds = try ClaudeTokenRefresher.current(service: service) } else { creds = try ClaudeCredentials.load() }
            return CredentialStatus(source: source, expiresAt: creds.expiresAt, problem: nil)
        } catch {
            return CredentialStatus(source: source, expiresAt: nil, problem: (error as? ProviderError)?.errorDescription ?? error.localizedDescription)
        }
    }

    public static func codex() -> CredentialStatus {
        let source = CodexCredentials.authFileURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        guard CodexCredentials.isAvailable() else { return CredentialStatus(source: source, expiresAt: nil, problem: "Codex CLI is not logged in on this Mac") }
        do {
            let creds = try CodexCredentials.load()
            return CredentialStatus(source: source, expiresAt: creds.expiresAt, problem: nil)
        } catch {
            return CredentialStatus(source: source, expiresAt: nil, problem: (error as? ProviderError)?.errorDescription ?? error.localizedDescription)
        }
    }

    public static func cursor() -> CredentialStatus {
        let source = "Cursor.app session (state.vscdb)"
        guard CursorCredentials.isAvailable() else { return CredentialStatus(source: source, expiresAt: nil, problem: "Cursor is not installed on this Mac") }
        do {
            let creds = try CursorCredentials.load()
            return CredentialStatus(source: source, expiresAt: creds.expiresAt, problem: nil)
        } catch {
            return CredentialStatus(source: source, expiresAt: nil, problem: (error as? ProviderError)?.errorDescription ?? error.localizedDescription)
        }
    }

    public static func antigravity() -> CredentialStatus {
        let installed = AntigravityUsageFetcher().isAvailable()
        return CredentialStatus(source: "Antigravity.app local language server (while the app runs)", expiresAt: nil,
                                problem: installed ? nil : "Antigravity is not installed on this Mac")
    }

    public static func status(for provider: ProviderID) -> CredentialStatus {
        switch provider {
        case .claude: claude()
        case .codex: codex()
        case .cursor: cursor()
        case .gemini: antigravity()
        }
    }

    /// One-line summary for Settings.
    public var summary: String {
        if let problem { return problem }
        guard let expiresAt else { return source }
        let rel = expiresAt.formatted(.relative(presentation: .named))
        return expiresAt > .now ? "\(source) · valid until \(rel)" : "\(source) · expired \(rel)"
    }
}
