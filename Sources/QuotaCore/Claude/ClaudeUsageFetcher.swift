import Foundation

/// `GET https://api.anthropic.com/api/oauth/usage` with the Claude Code OAuth token.
public struct ClaudeUsageFetcher: UsageFetcher {
    public let provider: ProviderID = .claude
    public init() {}

    public func isAvailable() -> Bool { ClaudeCredentials.isAvailable() }

    public func fetch() async throws -> UsageSnapshot {
        let creds = try ClaudeCredentials.load()
        // Usage is required; profile (seat, email) is best-effort.
        async let usageData = fetchRaw(creds)
        async let profileData = try? HTTP.get(URL(string: "https://api.anthropic.com/api/oauth/profile")!, headers: Self.headers(creds))
        let response = try HTTP.decode(ClaudeUsageResponse.self, from: try await usageData)
        let profile = await profileData.flatMap { try? JSONDecoder().decode(ClaudeProfileResponse.self, from: $0) }
        return Self.snapshot(from: response, plan: creds.subscriptionType, profile: profile)
    }

    public func fetchRaw() async throws -> Data { try await fetchRaw(try ClaudeCredentials.load()) }

    private static func headers(_ creds: ClaudeCredentials) -> [String: String] {
        ["Authorization": "Bearer \(creds.accessToken)", "anthropic-beta": "oauth-2025-04-20", "User-Agent": "QuotaVadis"]
    }

    private func fetchRaw(_ creds: ClaudeCredentials) async throws -> Data {
        if let expiry = creds.expiresAt, expiry < .now { throw ProviderError.tokenExpired }
        return try await HTTP.get(URL(string: "https://api.anthropic.com/api/oauth/usage")!, headers: Self.headers(creds))
    }

    static func snapshot(from r: ClaudeUsageResponse, plan: String?, profile: ClaudeProfileResponse? = nil) -> UsageSnapshot {
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
        var credits: [UsageCredits] = []
        if let spend = r.spend, spend.enabled == true, let used = spend.used?.amount {
            // Newer shape: minor units with an explicit exponent.
            credits.append(UsageCredits(id: "extra", title: "Extra usage", used: used, limit: spend.limit?.amount,
                                        currency: spend.used?.currency ?? "USD"))
        } else if let extra = r.extraUsage, extra.isEnabled == true, let used = extra.usedCredits {
            // Older shape: cents.
            credits.append(UsageCredits(id: "extra", title: "Extra usage", used: used / 100,
                                        limit: extra.monthlyLimit.map { $0 / 100 }, currency: extra.currency ?? "USD"))
        }
        let org = profile?.organization
        let planLabel = org?.organizationType.map(Self.planLabel) ?? plan.map(Self.planLabel)
        return UsageSnapshot(provider: .claude, account: profile?.account?.email, plan: planLabel,
                             seat: Self.seatLabel(seatTier: org?.seatTier, rateTier: org?.rateLimitTier),
                             windows: windows, credits: credits)
    }

    /// Accepts both `subscriptionType` ("max") and `organization_type` ("claude_team").
    static func planLabel(_ raw: String) -> String {
        let lower = raw.lowercased().replacingOccurrences(of: "claude_", with: "")
        switch lower {
        case "max": return "Max"
        case "pro": return "Pro"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        default: return lower.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// "team_tier_1" + "default_claude_max_5x" → "Team tier 1 · Max 5x". Unknown values pass through humanized.
    static func seatLabel(seatTier: String?, rateTier: String?) -> String? {
        var parts: [String] = []
        if let seatTier, !seatTier.isEmpty {
            parts.append(seatTier.replacingOccurrences(of: "_", with: " ").capitalized
                .replacingOccurrences(of: "Tier", with: "tier"))
        }
        if let rateTier {
            let lower = rateTier.lowercased()
            if let range = lower.range(of: "max_") {
                let multiplier = lower[range.upperBound...].uppercased()   // "5X", "20X"
                parts.append("Max \(multiplier.lowercased())")
            } else if lower.contains("pro") { parts.append("Pro") }
            else if lower.contains("enterprise") { parts.append("Enterprise") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct ClaudeProfileResponse: Decodable {
    struct Account: Decodable { let email: String?; let displayName: String?
        enum CodingKeys: String, CodingKey { case email; case displayName = "display_name" } }
    struct Organization: Decodable {
        let organizationType: String?
        let rateLimitTier: String?
        let seatTier: String?
        enum CodingKeys: String, CodingKey {
            case organizationType = "organization_type"; case rateLimitTier = "rate_limit_tier"; case seatTier = "seat_tier"
        }
    }
    let account: Account?
    let organization: Organization?
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
    let extraUsage: ExtraUsage?
    let spend: Spend?

    struct Money: Decodable {
        let amountMinor: Double?
        let exponent: Int?
        let currency: String?
        enum CodingKeys: String, CodingKey { case amountMinor = "amount_minor"; case exponent; case currency }
        var amount: Double? { amountMinor.map { $0 / pow(10, Double(exponent ?? 2)) } }
    }
    struct Spend: Decodable {
        let enabled: Bool?
        let used: Money?
        let limit: Money?
    }

    struct ExtraUsage: Decodable {
        let isEnabled: Bool?
        let monthlyLimit: Double?
        let usedCredits: Double?
        let currency: String?
        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled"; case monthlyLimit = "monthly_limit"; case usedCredits = "used_credits"; case currency
        }
    }

    enum CodingKeys: String, CodingKey {
        case extraUsage = "extra_usage"
        case spend
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
        extraUsage = try? c.decodeIfPresent(ExtraUsage.self, forKey: .extraUsage)
        spend = try? c.decodeIfPresent(Spend.self, forKey: .spend)
    }
}
