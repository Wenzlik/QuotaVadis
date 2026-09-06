import Foundation

/// `GET https://chatgpt.com/backend-api/wham/usage` with the Codex CLI OAuth token.
public struct CodexUsageFetcher: UsageFetcher {
    public let provider: ProviderID = .codex
    public init() {}

    public func isAvailable() -> Bool { CodexCredentials.isAvailable() }

    public func fetch() async throws -> UsageSnapshot {
        let creds = try CodexCredentials.load()
        if let expiry = creds.expiresAt, expiry < .now { throw ProviderError.tokenExpired }
        var headers = ["Authorization": "Bearer \(creds.accessToken)", "User-Agent": "QuotaBar"]
        if let id = creds.accountID { headers["ChatGPT-Account-Id"] = id }
        let data = try await HTTP.get(URL(string: "https://chatgpt.com/backend-api/wham/usage")!, headers: headers)
        let response = try HTTP.decode(CodexUsageResponse.self, from: data)
        return Self.snapshot(from: response, account: creds.email, fallbackPlan: creds.plan)
    }

    static func snapshot(from r: CodexUsageResponse, account: String?, fallbackPlan: String?) -> UsageSnapshot {
        var windows: [UsageWindow] = []
        func add(_ id: String, _ kind: UsageWindow.Kind, _ title: String, _ w: CodexUsageResponse.Window?) {
            guard let w else { return }
            windows.append(UsageWindow(id: id, kind: kind, title: title, usedPercent: Double(w.usedPercent),
                                       resetsAt: Date(timeIntervalSince1970: TimeInterval(w.resetAt))))
        }
        add("session", .session, "Session", r.rateLimit?.primaryWindow)
        add("weekly", .weekly, "Weekly", r.rateLimit?.secondaryWindow)
        for extra in r.additionalRateLimits ?? [] {
            let name = extra.limitName ?? "Extra"
            let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
            add("\(slug)-session", .model, name, extra.rateLimit?.primaryWindow)
            add("\(slug)-weekly", .model, "\(name) weekly", extra.rateLimit?.secondaryWindow)
        }
        let plan = (r.planType ?? fallbackPlan).map(Self.planLabel)
        return UsageSnapshot(provider: .codex, account: account, plan: plan, windows: windows)
    }
}

extension CodexUsageFetcher {
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
        enum CodingKeys: String, CodingKey { case usedPercent = "used_percent"; case resetAt = "reset_at" }
    }
    struct RateLimit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?
        enum CodingKeys: String, CodingKey { case primaryWindow = "primary_window"; case secondaryWindow = "secondary_window" }
    }
    struct AdditionalRateLimit: Decodable {
        let limitName: String?
        let rateLimit: RateLimit?
        enum CodingKeys: String, CodingKey { case limitName = "limit_name"; case rateLimit = "rate_limit" }
    }

    let planType: String?
    let rateLimit: RateLimit?
    let additionalRateLimits: [AdditionalRateLimit]?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        planType = try? c.decodeIfPresent(String.self, forKey: .planType)
        rateLimit = try? c.decodeIfPresent(RateLimit.self, forKey: .rateLimit)
        additionalRateLimits = try? c.decodeIfPresent([AdditionalRateLimit].self, forKey: .additionalRateLimits)
    }
}
