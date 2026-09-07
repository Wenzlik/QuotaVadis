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
            let h = ["Authorization": "Bearer \(creds.accessToken)", "anthropic-beta": "oauth-2025-04-20", "User-Agent": "QuotaVadis"]
            if let org = ProcessInfo.processInfo.environment["CLAUDE_ORG"] {
                var variants: [(String, String, [String: String])] = [
                    ("query organization_id", "/api/oauth/usage?organization_id=\(org)", h),
                    ("query organization_uuid", "/api/oauth/usage?organization_uuid=\(org)", h),
                ]
                for header in ["anthropic-organization-id", "x-organization-uuid", "X-Organization-UUID", "anthropic-organization"] {
                    var hh = h; hh[header] = org
                    variants.append(("header \(header)", "/api/oauth/usage", hh))
                    variants.append(("profile header \(header)", "/api/oauth/profile", hh))
                }
                for (label, path, hh) in variants {
                    let d = (try? await HTTP.get(URL(string: "https://api.anthropic.com" + path)!, headers: hh)) ?? Data("error".utf8)
                    out.append(("Claude \(label)", d))
                }
            }
        }
        if let creds = try? CodexCredentials.load() {
            let claims = JWT.payload(creds.idToken ?? "") ?? [:]
            out.append(("Codex id_token claims", (try? JSONSerialization.data(withJSONObject: claims)) ?? Data()))
            var headers = ["Authorization": "Bearer \(creds.accessToken)", "User-Agent": "QuotaVadis"]
            if let id = creds.accountID { headers["ChatGPT-Account-Id"] = id }
            let data = (try? await HTTP.get(URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!, headers: headers)) ?? Data("error".utf8)
            out.append(("Codex reset credits", data))
        }
        if let creds = try? CursorCredentials.load() {
            let data = (try? await HTTP.get(URL(string: "https://cursor.com/api/auth/me")!, headers: [
                "Cookie": creds.cookieHeader, "Origin": "https://cursor.com", "User-Agent": "QuotaVadis",
            ])) ?? Data("error".utf8)
            out.append(("Cursor auth/me", data))
            let h = ["Cookie": creds.cookieHeader, "Origin": "https://cursor.com", "Referer": "https://cursor.com/dashboard", "User-Agent": "QuotaVadis"]
            let teamID = ProcessInfo.processInfo.environment["CURSOR_TEAM_ID"] ?? "0"
            for path in ["/api/dashboard/team", "/api/dashboard/get-team-spend", "/api/dashboard/get-team-members", "/api/dashboard/get-team-member-info", "/api/dashboard/get-billing-info", "/api/dashboard/get-plan-info"] {
                let url = URL(string: "https://cursor.com" + path)!
                var d = try? await HTTP.post(url, json: #"{"teamId":\#(teamID)}"#, headers: h)
                if d == nil { d = try? await HTTP.get(url, headers: h) }
                out.append(("Cursor " + path, d ?? Data("error".utf8)))
                continue
            }
        }
        return out
    }

    /// claude.ai web API through the sessionKey cookie: organizations + usage/spend/credits for chat-capable orgs.
    public static func claudeWeb() async throws -> [(String, Data)] {
        guard let session = try ClaudeWebSession.load() else { return [("session", Data("none".utf8))] }
        var out: [(String, Data)] = [("session", Data("source=\(session.source.rawValue) lastActiveOrg=\(session.lastActiveOrg ?? "-") key=\(session.sessionKey.prefix(12))…".utf8))]
        let h = ClaudeWebUsageFetcher.headers(sessionKey: session.sessionKey)
        let orgsData = try await HTTP.get(URL(string: "https://claude.ai/api/organizations")!, headers: h)
        out.append(("organizations", orgsData))
        let orgs = (try? JSONSerialization.jsonObject(with: orgsData) as? [[String: Any]]) ?? []
        for o in orgs.prefix(3) {
            guard let id = o["uuid"] as? String, (o["capabilities"] as? [String])?.contains("chat") == true else { continue }
            for path in ["usage", "overage_spend_limit", "prepaid/credits"] {
                let d = (try? await HTTP.get(URL(string: "https://claude.ai/api/organizations/\(id)/\(path)")!, headers: h)) ?? Data("error".utf8)
                out.append(("\(o["name"] ?? id) /\(path)", d))
            }
        }
        return out
    }
}
