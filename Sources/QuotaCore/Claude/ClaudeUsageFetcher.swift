import Foundation

/// `GET https://api.anthropic.com/api/oauth/usage` with the Claude Code OAuth token.
public struct ClaudeUsageFetcher: UsageFetcher {
    public let provider: ProviderID = .claude
    public init() {}

    public func isAvailable() -> Bool { ClaudeCredentials.isAvailable() }

    public func fetch() async throws -> UsageSnapshot {
        let creds = try ClaudeCredentials.load()
        if let expiry = creds.expiresAt, expiry < .now { throw ProviderError.tokenExpired }
        let data = try await HTTP.get(URL(string: "https://api.anthropic.com/api/oauth/usage")!, headers: [
            "Authorization": "Bearer \(creds.accessToken)",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "QuotaBar",
        ])
        let response = try HTTP.decode(ClaudeUsageResponse.self, from: data)
        return Self.snapshot(from: response, plan: creds.subscriptionType)
    }

    static func snapshot(from r: ClaudeUsageResponse, plan: String?) -> UsageSnapshot {
        var windows: [UsageWindow] = []
        func add(_ id: String, _ kind: UsageWindow.Kind, _ title: String, _ w: ClaudeUsageResponse.Window?) {
            guard let w, let pct = w.utilization else { return }
            windows.append(UsageWindow(id: id, kind: kind, title: title, usedPercent: pct, resetsAt: ISO8601DateFormatter.parseAny(w.resetsAt)))
        }
        add("session", .session, "Session", r.fiveHour)
        add("weekly", .weekly, "Weekly", r.sevenDay)
        add("weekly-sonnet", .model, "Sonnet", r.sevenDaySonnet)
        add("weekly-opus", .model, "Opus", r.sevenDayOpus)
        // Newer shape: per-model scoped weekly limits.
        for entry in r.limits ?? [] {
            guard let pct = entry.percent, let name = entry.scope?.model?.displayName else { continue }
            let id = "weekly-" + name.lowercased().replacingOccurrences(of: " ", with: "-")
            guard !windows.contains(where: { $0.id == id }) else { continue }
            windows.append(UsageWindow(id: id, kind: .model, title: name, usedPercent: pct, resetsAt: ISO8601DateFormatter.parseAny(entry.resetsAt)))
        }
        return UsageSnapshot(provider: .claude, account: nil, plan: plan.map(Self.planLabel), windows: windows)
    }

    static func planLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "max": "Max"
        case "pro": "Pro"
        case "team": "Team"
        case "enterprise": "Enterprise"
        default: raw.capitalized
        }
    }
}

struct ClaudeUsageResponse: Decodable {
    struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?
        enum CodingKeys: String, CodingKey { case utilization; case resetsAt = "resets_at" }
    }
    struct LimitScope: Decodable {
        struct Model: Decodable {
            let displayName: String?
            enum CodingKeys: String, CodingKey { case displayName = "display_name" }
        }
        let model: Model?
    }
    struct LimitEntry: Decodable {
        let percent: Double?
        let resetsAt: String?
        let scope: LimitScope?
        enum CodingKeys: String, CodingKey { case percent; case resetsAt = "resets_at"; case scope }
    }

    let fiveHour: Window?
    let sevenDay: Window?
    let sevenDaySonnet: Window?
    let sevenDayOpus: Window?
    let limits: [LimitEntry]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOpus = "seven_day_opus"
        case limits
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Each field is decoded independently so one unexpected shape cannot blank the others.
        fiveHour = try? c.decodeIfPresent(Window.self, forKey: .fiveHour)
        sevenDay = try? c.decodeIfPresent(Window.self, forKey: .sevenDay)
        sevenDaySonnet = try? c.decodeIfPresent(Window.self, forKey: .sevenDaySonnet)
        sevenDayOpus = try? c.decodeIfPresent(Window.self, forKey: .sevenDayOpus)
        limits = try? c.decodeIfPresent([LimitEntry].self, forKey: .limits)
    }
}
