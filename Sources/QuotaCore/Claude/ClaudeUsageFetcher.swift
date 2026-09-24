import Foundation

/// `GET https://api.anthropic.com/api/oauth/usage?cedar_ember=1` with the Claude Code OAuth token.
public struct ClaudeUsageFetcher: UsageFetcher {
    public let provider: ProviderID = .claude
    /// Keychain service of the login to read; nil = Claude Code's default item.
    public let keychainService: String?

    public init(keychainService: String? = nil) { self.keychainService = keychainService }

    public var instanceID: String {
        guard let keychainService else { return provider.rawValue }
        return "claude:" + keychainService.replacingOccurrences(of: ClaudeCredentials.keychainService, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    public func isAvailable() -> Bool { keychainService == nil ? (ClaudeOwnLogin.isSignedIn || ClaudeCredentials.isAvailable()) : true }

    /// Extra profiles: use our refreshed copy and refresh when expired. Primary: Claude Code's item as-is.
    private func credentials(force: Bool = false) async throws -> ClaudeCredentials {
        guard let keychainService else {
            // QuotaVadis's own sign-in wins when there is one: it is the only Claude path that never reads an
            // item another app owns, so it is the only one that can never raise the Keychain dialog.
            if let own = try await ClaudeOwnLogin.credentials() { return own }
            return try ClaudeCredentials.load(force: force)
        }
        let creds = try ClaudeTokenRefresher.current(service: keychainService)
        if let expiry = creds.expiresAt, expiry < .now.addingTimeInterval(60) {
            return try await ClaudeTokenRefresher.refresh(service: keychainService, using: creds)
        }
        return creds
    }

    public func fetch() async throws -> UsageSnapshot {
        do { return try await fetch(force: false) }
        catch ProviderError.unauthorized where keychainService == nil && !ClaudeOwnLogin.isSignedIn {
            // A 401 is the only proof our cached copy has gone stale before its stated expiry — Claude Code
            // logged out or rotated the login underneath us. Drop it and go back to the source once.
            ClaudeCredentials.invalidate()
            return try await fetch(force: true)
        }
    }

    private func fetch(force: Bool) async throws -> UsageSnapshot {
        let creds = try await credentials(force: force)
        // Usage is required; profile (seat, email) is best-effort.
        async let usageData = fetchRaw(creds)
        async let profileData = try? HTTP.get(URL(string: "https://api.anthropic.com/api/oauth/profile")!, headers: Self.headers(creds))
        let response = try HTTP.decode(ClaudeUsageResponse.self, from: try await usageData)
        let profile = await profileData.flatMap { try? JSONDecoder().decode(ClaudeProfileResponse.self, from: $0) }
        var snapshot = Self.snapshot(from: response, plan: creds.subscriptionType, profile: profile)
        snapshot.instanceID = instanceID
        return try snapshot.validated()
    }

    public func fetchRaw() async throws -> Data { try await fetchRaw(try await credentials()) }

    private static func headers(_ creds: ClaudeCredentials) -> [String: String] {
        ["Authorization": "Bearer \(creds.accessToken)", "anthropic-beta": "oauth-2025-04-20", "User-Agent": "QuotaVadis"]
    }

    /// The server only hands out `cedar_ember` grants to Claude Code's own surface: with our UA it answers
    /// `eligible:false, ineligible_reason:"surface"`. Presenting as Claude Code on this one request (owner's
    /// explicit call) is what makes the usage-limit resets show; every other request stays `QuotaVadis`.
    static let usageUserAgent = "claude-cli/2.1.281 (external, cli)"

    static func usageHeaders(_ creds: ClaudeCredentials) -> [String: String] {
        headers(creds).merging(["User-Agent": usageUserAgent]) { $1 }
    }

    private func fetchRaw(_ creds: ClaudeCredentials) async throws -> Data {
        if let expiry = creds.expiresAt, expiry < .now { throw ProviderError.tokenExpired }
        // `cedar_ember=1` asks for the usage-limit reset grants block on top of the plain payload (what Claude Code's
        // reset offer reads); without it the key is omitted. Claude Code also sends `skip_spend=1`, we keep spend.
        return try await HTTP.get(URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1")!, headers: Self.usageHeaders(creds))
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
        // Usage-limit resets ("cedar_ember"): Claude's counterpart of Codex's rate limit reset credits.
        var resetsAvailable: Int?
        var resetExpiries: [Date] = []
        if let program = r.cedarEmber, program.eligible == true || !(program.grants ?? []).isEmpty {
            let grants = (program.grants ?? []).filter { $0.resetsLeft != nil }
            resetsAvailable = grants.reduce(0) { $0 + max(0, $1.resetsLeft ?? 0) }
            resetExpiries = grants.filter { ($0.resetsLeft ?? 0) > 0 }
                .compactMap { ISO8601DateFormatter.parseAny($0.endsAt) }
                .sorted()
        }
        let org = profile?.organization
        let planLabel = org?.organizationType.map(Self.planLabel) ?? plan.map(Self.planLabel)
        return UsageSnapshot(provider: .claude, account: profile?.account?.email, organization: org?.name, plan: planLabel,
                             seat: Self.seatLabel(seatTier: org?.seatTier, rateTier: org?.rateLimitTier),
                             windows: windows, credits: credits,
                             resetCreditsAvailable: resetsAvailable, resetCreditExpiries: resetExpiries)
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

    /// Team seats: `team_standard` = Standard, `team_tier_1` = Premium (the seat that includes Claude Code with
    /// Max-level limits). Unknown values pass through humanized so a new tier is still visible.
    static func seatLabel(seatTier: String?, rateTier: String?) -> String? {
        var parts: [String] = []
        if let seatTier, !seatTier.isEmpty {
            switch seatTier.lowercased() {
            case "team_standard": parts.append("Standard seat")
            case "team_tier_1", "team_premium": parts.append("Premium seat")
            default: parts.append(seatTier.replacingOccurrences(of: "_", with: " ").capitalized)
            }
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
    struct Account: Decodable {
        let email: String?; let displayName: String?
        enum CodingKeys: String, CodingKey { case email; case displayName = "display_name" }
        init(email: String?, displayName: String?) { self.email = email; self.displayName = displayName }
    }
    struct Organization: Decodable {
        let name: String?
        let organizationType: String?
        let rateLimitTier: String?
        let seatTier: String?
        enum CodingKeys: String, CodingKey {
            case name; case organizationType = "organization_type"; case rateLimitTier = "rate_limit_tier"; case seatTier = "seat_tier"
        }
        init(name: String?, organizationType: String?, rateLimitTier: String?, seatTier: String?) {
            self.name = name; self.organizationType = organizationType; self.rateLimitTier = rateLimitTier; self.seatTier = seatTier
        }
    }
    let account: Account?
    let organization: Organization?
    init(account: Account?, organization: Organization?) { self.account = account; self.organization = organization }
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
    let cedarEmber: ResetProgram?

    /// Usage-limit reset program, only present when the request carries `cedar_ember=1`.
    struct ResetProgram: Decodable {
        struct Grant: Decodable {
            let resetsLeft: Int?
            let endsAt: String?
            enum CodingKeys: String, CodingKey { case resetsLeft = "resets_left"; case endsAt = "ends_at" }
        }
        let eligible: Bool?
        let grants: [Grant]?
    }

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
        case cedarEmber = "cedar_ember"
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
        cedarEmber = try? c.decodeIfPresent(ResetProgram.self, forKey: .cedarEmber)
    }
}
