import Foundation

/// Reads `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`). Codex CLI owns and refreshes it.
struct CodexCredentials: Sendable {
    let accessToken: String
    let accountID: String?
    let expiresAt: Date?
    let email: String?
    let plan: String?
    let idToken: String?
    /// Default API-platform organization from the id_token. NOT the ChatGPT workspace; informational only.
    let workspace: String?

    static var authFileURL: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.userHome.appendingPathComponent(".codex")
        return home.appendingPathComponent("auth.json")
    }

    static func isAvailable() -> Bool { FileManager.default.fileExists(atPath: authFileURL.path) }

    static func load() throws -> CodexCredentials {
        guard let data = try? Data(contentsOf: authFileURL) else { throw ProviderError.notLoggedIn }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> CodexCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.decoding("auth.json is not JSON")
        }
        guard let tokens = root["tokens"] as? [String: Any],
              let access = (tokens["access_token"] ?? tokens["accessToken"]) as? String, !access.isEmpty else {
            // API-key-only logins have no ChatGPT rate limits to show.
            throw ProviderError.notLoggedIn
        }
        var accountID = (tokens["account_id"] ?? tokens["accountId"]) as? String
        var email: String?
        var plan: String?
        var workspace: String?
        // The id_token carries the ChatGPT account id, email and plan under the openai auth claim.
        let claims = JWT.payload(tokens["id_token"] as? String ?? "") ?? [:]
        email = claims["email"] as? String
        if let auth = claims["https://api.openai.com/auth"] as? [String: Any] {
            accountID = accountID ?? auth["chatgpt_account_id"] as? String
            plan = auth["chatgpt_plan_type"] as? String
            let orgs = auth["organizations"] as? [[String: Any]] ?? []
            workspace = (orgs.first { $0["is_default"] as? Bool == true } ?? orgs.first)?["title"] as? String
        }
        return CodexCredentials(accessToken: access, accountID: accountID, expiresAt: JWT.expiry(access), email: email, plan: plan,
                                idToken: tokens["id_token"] as? String, workspace: workspace)
    }
}
