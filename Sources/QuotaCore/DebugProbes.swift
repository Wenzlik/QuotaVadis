import Foundation

/// Extra endpoints used only from `quotactl --profile` while exploring API shapes.
public enum DebugProbes {
    public static func profiles() async -> [(String, Data)] {
        var out: [(String, Data)] = []
        if let creds = try? ClaudeCredentials.load() {
            let data = (try? await HTTP.get(URL(string: "https://api.anthropic.com/api/oauth/profile")!, headers: [
                "Authorization": "Bearer \(creds.accessToken)", "anthropic-beta": "oauth-2025-04-20", "User-Agent": "QuotaVadis",
            ])) ?? Data("error".utf8)
            out.append(("Claude profile", data))
        }
        if let creds = try? CodexCredentials.load() {
            let claims = JWT.payload(creds.idToken ?? "") ?? [:]
            out.append(("Codex id_token claims", (try? JSONSerialization.data(withJSONObject: claims)) ?? Data()))
        }
        if let creds = try? CursorCredentials.load() {
            let data = (try? await HTTP.get(URL(string: "https://cursor.com/api/auth/me")!, headers: [
                "Cookie": creds.cookieHeader, "Origin": "https://cursor.com", "User-Agent": "QuotaVadis",
            ])) ?? Data("error".utf8)
            out.append(("Cursor auth/me", data))
        }
        return out
    }
}
