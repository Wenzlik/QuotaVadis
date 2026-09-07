import Foundation

/// Claude limits through the claude.ai web API with the `sessionKey` cookie of the Claude desktop app, Chrome,
/// or a manually pasted key. For people without Claude Code. One snapshot per organization that has limits.
public struct ClaudeWebUsageFetcher: UsageFetcher {
    public let provider: ProviderID = .claude
    public var instanceID: String { "claude-web" }
    /// Organization names already covered by Claude Code logins; skipped so a workspace is not shown twice.
    public var excludedOrganizationNames: Set<String> = []

    public init(excludedOrganizationNames: Set<String> = []) { self.excludedOrganizationNames = excludedOrganizationNames }

    public func isAvailable() -> Bool { ClaudeWebSession.isAvailable() }

    public func fetch() async throws -> UsageSnapshot {
        guard let first = try await fetchAll().first else { throw ProviderError.notLoggedIn }
        return first
    }

    public func fetchRaw() async throws -> Data {
        guard let session = try ClaudeWebSession.load() else { throw ProviderError.notLoggedIn }
        return try await HTTP.get(URL(string: "https://claude.ai/api/organizations")!, headers: Self.headers(sessionKey: session.sessionKey))
    }

    public func fetchAll() async throws -> [UsageSnapshot] {
        guard let session = try ClaudeWebSession.load() else { throw ProviderError.notLoggedIn }
        let h = Self.headers(sessionKey: session.sessionKey)
        let orgs = try HTTP.decode([Organization].self, from: try await HTTP.get(URL(string: "https://claude.ai/api/organizations")!, headers: h))
        let account = try? HTTP.decode(Account.self, from: try await HTTP.get(URL(string: "https://claude.ai/api/account")!, headers: h))
        var snapshots: [UsageSnapshot] = []
        let candidates = orgs.filter { ($0.capabilities ?? []).contains("chat") && !excludedOrganizationNames.contains($0.name ?? "") }
        // The org the app last used first, so it becomes the primary web instance.
        let ordered = candidates.sorted { ($0.uuid == session.lastActiveOrg ? 0 : 1) < ($1.uuid == session.lastActiveOrg ? 0 : 1) }
        for org in ordered {
            guard let id = org.uuid else { continue }
            let data = try await HTTP.get(URL(string: "https://claude.ai/api/organizations/\(id)/usage")!, headers: h)
            let usage = try HTTP.decode(ClaudeUsageResponse.self, from: data)
            let membership = account?.memberships?.first { $0.organization?.uuid == id }
            let profile = ClaudeProfileResponse(
                account: .init(email: account?.emailAddress, displayName: nil),
                organization: .init(name: org.name, organizationType: org.organizationType ?? Self.inferredType(org),
                                    rateLimitTier: org.rateLimitTier, seatTier: membership?.seatTier))
            var snapshot = ClaudeUsageFetcher.snapshot(from: usage, plan: nil, profile: profile)
            guard !snapshot.windows.isEmpty else { continue }    // no seat / no limits in this org
            snapshot.instanceID = "claude-web:\(id)"
            snapshots.append(snapshot)
        }
        guard !snapshots.isEmpty else { throw ProviderError.decoding("This claude.ai account has no organization with usage limits") }
        return snapshots
    }

    static func inferredType(_ org: Organization) -> String? {
        switch org.billingType {
        case "stripe_subscription": return (org.capabilities ?? []).contains("raven") ? "claude_team" : "claude_pro"
        default: return nil
        }
    }

    static func headers(sessionKey: String) -> [String: String] {
        ["Cookie": "sessionKey=\(sessionKey)",
         "Accept": "application/json",
         "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"]
    }

    struct Organization: Decodable {
        let uuid: String?; let name: String?; let capabilities: [String]?
        let rateLimitTier: String?; let billingType: String?; let organizationType: String?
        enum CodingKeys: String, CodingKey {
            case uuid, name, capabilities
            case rateLimitTier = "rate_limit_tier"; case billingType = "billing_type"; case organizationType = "organization_type"
        }
    }
    struct Account: Decodable {
        struct Membership: Decodable {
            struct Org: Decodable { let uuid: String? }
            let organization: Org?; let seatTier: String?
            enum CodingKeys: String, CodingKey { case organization; case seatTier = "seat_tier" }
        }
        let emailAddress: String?; let memberships: [Membership]?
        enum CodingKeys: String, CodingKey { case emailAddress = "email_address"; case memberships }
    }
}
