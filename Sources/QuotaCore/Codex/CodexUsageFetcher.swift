import Foundation

/// `GET https://chatgpt.com/backend-api/wham/usage` with the Codex CLI OAuth token.
public struct CodexUsageFetcher: UsageFetcher {
    public let provider: ProviderID = .codex
    public init() {}

    public func isAvailable() -> Bool { CodexCredentials.isAvailable() }

    public func fetch() async throws -> UsageSnapshot {
        let creds = try CodexCredentials.load()
        async let usageData = fetchRaw(creds)
        async let resetData = try? HTTP.get(URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!, headers: Self.headers(creds))
        let response = try HTTP.decode(CodexUsageResponse.self, from: try await usageData)
        let resets = await resetData.flatMap { try? JSONDecoder().decode(CodexResetCreditsResponse.self, from: $0) }
        var snapshot = Self.snapshot(from: response, account: creds.email, fallbackPlan: creds.plan)
        if let resets {
            snapshot.resetCreditExpiries = resets.credits
                .filter { $0.status == "available" }
                .compactMap { ISO8601DateFormatter.parseAny($0.expiresAt) }
                .sorted()
            snapshot.resetCreditsAvailable = resets.availableCount ?? snapshot.resetCreditsAvailable
        }
        return snapshot
    }

    private static func headers(_ creds: CodexCredentials) -> [String: String] {
        var headers = ["Authorization": "Bearer \(creds.accessToken)", "User-Agent": "QuotaVadis"]
        if let id = creds.accountID { headers["ChatGPT-Account-Id"] = id }
        return headers
    }

    public func fetchRaw() async throws -> Data { try await fetchRaw(try CodexCredentials.load()) }

    private func fetchRaw(_ creds: CodexCredentials) async throws -> Data {
        if let expiry = creds.expiresAt, expiry < .now { throw ProviderError.tokenExpired }
        return try await HTTP.get(URL(string: "https://chatgpt.com/backend-api/wham/usage")!, headers: Self.headers(creds))
    }

    static func snapshot(from r: CodexUsageResponse, account: String?, fallbackPlan: String?) -> UsageSnapshot {
        var windows: [UsageWindow] = []
        // Windows are labelled by their real length: some plans expose only a weekly window as "primary".
        func add(prefix: String?, _ w: CodexUsageResponse.Window?, kindOverride: UsageWindow.Kind? = nil) {
            guard let w else { return }
            let kind = UsageWindow.kind(forSeconds: w.limitWindowSeconds ?? 18_000)
            let baseTitle = kind == .session ? "Session" : kind == .weekly ? "Weekly" : "Monthly"
            let id = [prefix, kind.rawValue].compactMap { $0 }.joined(separator: "-")
            let title = prefix.map { "\($0) \(baseTitle.lowercased())" } ?? baseTitle
            windows.append(UsageWindow(id: id, kind: kindOverride ?? kind, title: title, usedPercent: Double(w.usedPercent),
                                       resetsAt: Date(timeIntervalSince1970: TimeInterval(w.resetAt)), prominent: kindOverride == nil))
        }
        add(prefix: nil, r.rateLimit?.primaryWindow)
        add(prefix: nil, r.rateLimit?.secondaryWindow)
        for extra in r.additionalRateLimits ?? [] {
            let name = extra.limitName ?? "Extra"
            add(prefix: name, extra.rateLimit?.primaryWindow, kindOverride: .model)
            add(prefix: name, extra.rateLimit?.secondaryWindow, kindOverride: .model)
        }
        let rawPlan = r.planType ?? fallbackPlan
        let plan = rawPlan.map(Self.planLabel)
        let seat = rawPlan.flatMap(Self.seatLabel)
        var credits: [UsageCredits] = []
        // Business/Team workspaces: monthly credit pool with a per-user cap.
        if let cap = r.individualLimit ?? r.rateLimit?.individualLimit ?? r.spendControl?.individualLimit, let used = cap.used {
            credits.append(UsageCredits(id: "monthly", title: "Monthly credits", used: used, limit: cap.limit,
                                        resetsAt: cap.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }))
        }
        // Personal plans: prepaid credit balance (only a balance, no "used" figure is exposed).
        if let c = r.credits, c.hasCredits, !c.unlimited, let balance = c.balance {
            credits.append(UsageCredits(id: "balance", title: "Credit balance", used: 0, limit: balance))
        }
        return UsageSnapshot(provider: .codex, account: account, plan: plan, seat: seat, windows: windows, credits: credits,
                             resetCreditsAvailable: r.rateLimitResetCredits?.availableCount)
    }
}

extension CodexUsageFetcher {
    /// The seat suffix of a workspace plan: "self_serve_business_prolite" → "Pro Lite". nil for personal plans.
    static func seatLabel(_ raw: String) -> String? {
        let lower = raw.lowercased()
        guard let range = lower.range(of: "business_") ?? lower.range(of: "team_") ?? lower.range(of: "enterprise_") else { return nil }
        let suffix = lower[range.upperBound...]
        guard !suffix.isEmpty else { return nil }
        switch suffix {
        case "prolite": return "Pro Lite"
        case "pro": return "Pro"
        default: return suffix.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// "self_serve_business_prolite" → "Business", "plus" → "Plus".
    static func planLabel(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("enterprise") { return "Enterprise" }
        if lower.contains("business") || lower.contains("team") { return "Business" }
        if lower.contains("pro") { return "Pro" }
        if lower.contains("plus") { return "Plus" }
        if lower.contains("free") { return "Free" }
        return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct CodexUsageResponse: Decodable {
    struct Window: Decodable {
        let usedPercent: Int
        let resetAt: Int
        let limitWindowSeconds: Int?
        enum CodingKeys: String, CodingKey { case usedPercent = "used_percent"; case resetAt = "reset_at"; case limitWindowSeconds = "limit_window_seconds" }
    }
    struct ResetCredits: Decodable {
        let availableCount: Int?
        enum CodingKeys: String, CodingKey { case availableCount = "available_count" }
    }
    struct RateLimit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?
        let individualLimit: SpendLimit?
        enum CodingKeys: String, CodingKey { case primaryWindow = "primary_window"; case secondaryWindow = "secondary_window"; case individualLimit = "individual_limit" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            primaryWindow = try? c.decodeIfPresent(Window.self, forKey: .primaryWindow)
            secondaryWindow = try? c.decodeIfPresent(Window.self, forKey: .secondaryWindow)
            individualLimit = try? c.decodeIfPresent(SpendLimit.self, forKey: .individualLimit)
        }
    }
    struct AdditionalRateLimit: Decodable {
        let limitName: String?
        let rateLimit: RateLimit?
        enum CodingKeys: String, CodingKey { case limitName = "limit_name"; case rateLimit = "rate_limit" }
    }

    struct Credits: Decodable {
        let hasCredits: Bool
        let unlimited: Bool
        let balance: Double?
        enum CodingKeys: String, CodingKey { case hasCredits = "has_credits"; case unlimited; case balance }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hasCredits = (try? c.decode(Bool.self, forKey: .hasCredits)) ?? false
            unlimited = (try? c.decode(Bool.self, forKey: .unlimited)) ?? false
            balance = (try? c.decode(Double.self, forKey: .balance)) ?? (try? c.decode(String.self, forKey: .balance)).flatMap(Double.init)
        }
    }
    struct SpendLimit: Decodable {
        let limit: Double?
        let used: Double?
        let resetsAt: Int?
        enum CodingKeys: String, CodingKey { case limit, used, resetsAt = "resets_at", resetAt = "reset_at" }
        /// Values arrive as numbers or as numeric strings ("1", "0.0").
        private static func number(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
            (try? c.decodeIfPresent(Double.self, forKey: key)) ?? (try? c.decodeIfPresent(String.self, forKey: key)).flatMap(Double.init)
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            limit = Self.number(c, .limit)
            used = Self.number(c, .used)
            resetsAt = (try? c.decodeIfPresent(Int.self, forKey: .resetsAt)) ?? (try? c.decodeIfPresent(Int.self, forKey: .resetAt))
        }
    }
    struct SpendControl: Decodable {
        let individualLimit: SpendLimit?
        enum CodingKeys: String, CodingKey { case individualLimit = "individual_limit" }
    }

    let planType: String?
    let rateLimit: RateLimit?
    let additionalRateLimits: [AdditionalRateLimit]?
    let credits: Credits?
    let individualLimit: SpendLimit?
    let spendControl: SpendControl?
    let rateLimitResetCredits: ResetCredits?

    enum CodingKeys: String, CodingKey {
        case rateLimitResetCredits = "rate_limit_reset_credits"
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
        case credits
        case individualLimit = "individual_limit"
        case spendControl = "spend_control"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        planType = try? c.decodeIfPresent(String.self, forKey: .planType)
        rateLimit = try? c.decodeIfPresent(RateLimit.self, forKey: .rateLimit)
        additionalRateLimits = try? c.decodeIfPresent([AdditionalRateLimit].self, forKey: .additionalRateLimits)
        credits = try? c.decodeIfPresent(Credits.self, forKey: .credits)
        individualLimit = try? c.decodeIfPresent(SpendLimit.self, forKey: .individualLimit)
        spendControl = try? c.decodeIfPresent(SpendControl.self, forKey: .spendControl)
        rateLimitResetCredits = try? c.decodeIfPresent(ResetCredits.self, forKey: .rateLimitResetCredits)
    }
}

struct CodexResetCreditsResponse: Decodable {
    struct Credit: Decodable {
        let status: String?
        let expiresAt: String?
        enum CodingKeys: String, CodingKey { case status; case expiresAt = "expires_at" }
    }
    let availableCount: Int?
    let credits: [Credit]
    enum CodingKeys: String, CodingKey { case availableCount = "available_count"; case credits }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        availableCount = try? c.decodeIfPresent(Int.self, forKey: .availableCount)
        credits = (try? c.decodeIfPresent([Credit].self, forKey: .credits)) ?? []
    }
}
