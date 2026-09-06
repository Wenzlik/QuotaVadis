import Foundation

/// `GET https://cursor.com/api/usage-summary` authenticated with Cursor.app's local session.
public struct CursorUsageFetcher: UsageFetcher {
    public let provider: ProviderID = .cursor
    public init() {}

    public func isAvailable() -> Bool { CursorCredentials.isAvailable() }

    public func fetch() async throws -> UsageSnapshot {
        let creds = try CursorCredentials.load()
        // Grok Bot ("sand") lives on a dashboard endpoint; its failure must not hide the plan bars.
        async let summaryData = fetchRaw(creds)
        async let botData = try? HTTP.post(URL(string: "https://cursor.com/api/dashboard/get-sand-usage-status")!, json: "{}",
                                           headers: Self.headers(creds))
        async let seatData = Self.fetchSeat(creds)
        let response = try HTTP.decode(CursorUsageSummary.self, from: try await summaryData)
        let bot = await botData.flatMap { try? JSONDecoder().decode(CursorBotUsage.self, from: $0) }
        var snapshot = Self.snapshot(from: response, bot: bot, account: creds.email)
        snapshot.seat = await seatData
        return snapshot
    }

    /// Team seat tier: `/api/dashboard/teams` → the team this user is a direct member of →
    /// `/api/dashboard/team` → this user's `billingTier`. Verified: TIER_1000 = Standard seat.
    private static func fetchSeat(_ creds: CursorCredentials) async -> String? {
        guard let teamsData = try? await HTTP.post(URL(string: "https://cursor.com/api/dashboard/teams")!, json: "{}", headers: headers(creds)),
              let teams = try? JSONDecoder().decode(CursorTeams.self, from: teamsData),
              let team = teams.teams.first(where: { $0.isDirectMember == true }) ?? teams.teams.first,
              let teamData = try? await HTTP.post(URL(string: "https://cursor.com/api/dashboard/team")!, json: #"{"teamId":\#(team.id)}"#, headers: headers(creds)),
              let detail = try? JSONDecoder().decode(CursorTeamDetail.self, from: teamData),
              let me = detail.teamMembers.first(where: { $0.id == detail.userId }) else { return nil }
        return seatLabel(billingTier: me.billingTier)
    }

    static func seatLabel(billingTier: String?) -> String? {
        guard let billingTier else { return nil }
        switch billingTier.uppercased() {
        case "TEAM_MEMBER_BILLING_TIER_TIER_1000": return "Standard seat"
        case "TEAM_MEMBER_BILLING_TIER_TIER_2000": return "Premium seat"
        default:
            // Unknown tier: surface the number rather than hide it.
            let digits = billingTier.split(separator: "_").last.map(String.init) ?? billingTier
            return "Tier \(digits) seat"
        }
    }

    private static func headers(_ creds: CursorCredentials) -> [String: String] {
        ["Cookie": creds.cookieHeader, "Origin": "https://cursor.com", "Referer": "https://cursor.com/dashboard", "User-Agent": "QuotaVadis"]
    }

    public func fetchRaw() async throws -> Data { try await fetchRaw(try CursorCredentials.load()) }

    private func fetchRaw(_ creds: CursorCredentials) async throws -> Data {
        if let expiry = creds.expiresAt, expiry.timeIntervalSinceNow < 60 { throw ProviderError.tokenExpired }
        return try await HTTP.get(URL(string: "https://cursor.com/api/usage-summary")!, headers: Self.headers(creds))
    }

    static func snapshot(from r: CursorUsageSummary, bot: CursorBotUsage? = nil, account: String?) -> UsageSnapshot {
        var windows: [UsageWindow] = []
        var credits: [UsageCredits] = []
        let cycleEnd = ISO8601DateFormatter.parseAny(r.billingCycleEnd)
        // Cursor is money-metered: the plan's included allowance is both the "window" and the credit figure.
        // The monthly total splits into Auto (Cursor's own models) and named/API models.
        if let plan = r.individualUsage?.plan {
            if let pct = plan.totalPercentUsed ?? percent(used: plan.used, limit: plan.limit) {
                windows.append(UsageWindow(id: "plan", kind: .monthly, title: "Included total", usedPercent: pct, resetsAt: cycleEnd))
            }
            if let pct = plan.autoPercentUsed {
                windows.append(UsageWindow(id: "auto", kind: .model, title: "Auto (Cursor models)", usedPercent: pct, resetsAt: cycleEnd, prominent: false))
            }
            if let pct = plan.apiPercentUsed {
                windows.append(UsageWindow(id: "api", kind: .model, title: "Other models", usedPercent: pct, resetsAt: cycleEnd, prominent: false))
            }
            // On team/enterprise seats `used`/`limit` (cents) disagree with Cursor's own `totalPercentUsed`
            // (e.g. 713/2000 = 36% vs 2.85%): the seat draws on a pooled team allowance and `limit` is a placeholder.
            // Only show the dollar figure when it agrees with the percentage Cursor displays itself.
            // `used` is the metered value of included usage, never money the user pays. Show it only when the
            // limit is real (individual plans); pooled team seats already have the percentage bar.
            if let used = plan.used, let limit = plan.limit, limit > 0 {
                let derived = Double(used) / Double(limit) * 100
                if plan.totalPercentUsed.map({ abs($0 - derived) <= 1.5 }) ?? true {
                    credits.append(UsageCredits(id: "plan", title: "Included usage", used: Double(used) / 100, limit: Double(limit) / 100, resetsAt: cycleEnd))
                }
            }
        }
        if let od = r.individualUsage?.onDemand, od.enabled == true, let used = od.used {
            credits.append(UsageCredits(id: "on-demand", title: "On-demand spend", used: Double(used) / 100,
                                        limit: od.limit.map { Double($0) / 100 }, resetsAt: cycleEnd))
        }
        if let bot, bot.hasNonZeroIncludedLimit == true, let pct = bot.usagePercent {
            windows.append(UsageWindow(id: "grok-bot", kind: .weekly, title: "Grok Bot", usedPercent: pct,
                                       resetsAt: ISO8601DateFormatter.parseAny(bot.nextResetTimestampUtc)))
        }
        // Cursor reports Teams workspaces as `enterprise`; the API exposes no seat type, so none is shown.
        let plan = r.membershipType.map(Self.planLabel)
        return UsageSnapshot(provider: .cursor, account: account, plan: plan, seat: nil, windows: windows, credits: credits)
    }

    static func planLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "enterprise", "team", "teams", "business": "Team"
        case "pro": "Pro"
        case "pro_plus", "pro-plus": "Pro+"
        case "ultra": "Ultra"
        case "free", "hobby": "Hobby"
        default: raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func percent(used: Int?, limit: Int?) -> Double? {
        guard let used, let limit, limit > 0 else { return nil }
        return Double(used) / Double(limit) * 100
    }
}

struct CursorUsageSummary: Decodable {
    struct Bucket: Decodable {
        let enabled: Bool?
        let used: Int?
        let limit: Int?
        let totalPercentUsed: Double?
        let autoPercentUsed: Double?
        let apiPercentUsed: Double?
    }
    struct Individual: Decodable {
        let plan: Bucket?
        let onDemand: Bucket?
    }
    let billingCycleEnd: String?
    let membershipType: String?
    let limitType: String?
    let individualUsage: Individual?
}

struct CursorTeams: Decodable {
    struct Team: Decodable { let id: Int; let isDirectMember: Bool? }
    let teams: [Team]
}

struct CursorTeamDetail: Decodable {
    struct Member: Decodable { let id: Int; let billingTier: String? }
    let teamMembers: [Member]
    let userId: Int
}

struct CursorBotUsage: Decodable {
    let nextResetTimestampUtc: String?
    let usagePercent: Double?
    let hasNonZeroIncludedLimit: Bool?
}
