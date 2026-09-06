import Foundation
import Testing
@testable import QuotaCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Test func claudeMapping() throws {
    let r = try JSONDecoder().decode(ClaudeUsageResponse.self, from: fixture("claude_usage"))
    let s = ClaudeUsageFetcher.snapshot(from: r, plan: "max")
    #expect(s.plan == "Max")
    #expect(s.windows.map(\.id) == ["session", "weekly", "weekly-sonnet", "weekly-fable"])
    #expect(s.primaryWindow?.usedPercent == 42.5)
    #expect(s.secondaryWindow?.usedPercent == 61)
    #expect(s.primaryWindow?.resetsAt != nil)
    #expect(s.worstWindow?.id == "weekly")
    #expect(s.credits == [UsageCredits(id: "extra", title: "Extra usage", used: 15.65, limit: 5, currency: "USD")])
}

@Test func codexWeeklyOnlyPlan() throws {
    let json = #"{"rate_limit":{"primary_window":{"used_percent":94,"reset_at":1788806972,"limit_window_seconds":604800},"secondary_window":null}}"#
    let r = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
    let s = CodexUsageFetcher.snapshot(from: r, account: nil, fallbackPlan: "self_serve_business_prolite")
    #expect(s.windows.map(\.kind) == [.weekly])
    #expect(s.windows.first?.title == "Weekly")
    #expect(s.plan == "Business")
}

@Test func codexMapping() throws {
    let r = try JSONDecoder().decode(CodexUsageResponse.self, from: fixture("codex_usage"))
    let s = CodexUsageFetcher.snapshot(from: r, account: "me@example.com", fallbackPlan: nil)
    #expect(s.plan == "Plus")
    #expect(s.windows.map(\.id) == ["session", "weekly", "GPT-5.3-Codex-Spark-session"])
    #expect(s.windows.map(\.kind) == [.session, .weekly, .model])
    #expect(s.secondaryWindow?.usedPercent == 55)
    #expect(s.primaryWindow?.resetsAt == Date(timeIntervalSince1970: 1_757_100_000))
    #expect(s.resetCreditsAvailable == 3)
    #expect(s.credits.first?.limit == 1)
    #expect(s.credits.first?.used == 0)
}

@Test func cursorMapping() throws {
    let r = try JSONDecoder().decode(CursorUsageSummary.self, from: fixture("cursor_usage"))
    let s = CursorUsageFetcher.snapshot(from: r, account: nil)
    #expect(s.plan == "Pro")
    #expect(s.windows.map(\.id) == ["plan", "auto", "api"])
    #expect(s.windows[0].usedPercent == 67)
    #expect(s.windows[1].usedPercent == 60)
    #expect(s.windows[2].usedPercent == 7)
    #expect(s.seat == "Team seat")
    #expect(s.credits.map(\.id) == ["plan", "on-demand"])
    #expect(s.credits[0].used == 13.40)
    #expect(s.credits[0].limit == 20)
    #expect(s.credits[1].usedPercent == 5)
    #expect(s.secondaryWindow?.id == "plan")
}

@Test func cursorGrokBot() throws {
    let r = try JSONDecoder().decode(CursorUsageSummary.self, from: fixture("cursor_usage"))
    let bot = CursorBotUsage(nextResetTimestampUtc: "2026-09-08T00:00:00.000Z", usagePercent: 12, hasNonZeroIncludedLimit: true)
    let s = CursorUsageFetcher.snapshot(from: r, bot: bot, account: nil)
    #expect(s.windows.last?.id == "grok-bot")
    #expect(s.windows.last?.usedPercent == 12)
    let none = CursorUsageFetcher.snapshot(from: r, bot: CursorBotUsage(nextResetTimestampUtc: nil, usagePercent: 0, hasNonZeroIncludedLimit: false), account: nil)
    #expect(!none.windows.contains { $0.id == "grok-bot" })
}

@Test func seatLabels() {
    #expect(ClaudeUsageFetcher.seatLabel(seatTier: "team_tier_1", rateTier: "default_claude_max_5x") == "Premium seat · Max 5x")
    #expect(ClaudeUsageFetcher.seatLabel(seatTier: "team_standard", rateTier: nil) == "Standard seat")
    #expect(ClaudeUsageFetcher.seatLabel(seatTier: nil, rateTier: "default_claude_max_20x") == "Max 20x")
    #expect(ClaudeUsageFetcher.seatLabel(seatTier: nil, rateTier: nil) == nil)
    #expect(ClaudeUsageFetcher.planLabel("claude_team") == "Team")
    #expect(CodexUsageFetcher.seatLabel("self_serve_business_prolite") == "Pro Lite")
    #expect(CodexUsageFetcher.seatLabel("plus") == nil)
}

@Test func claudeCredentialsParsing() throws {
    let json = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-x","expiresAt":1893456000000,"subscriptionType":"max"}}"#
    let c = try ClaudeCredentials.parse(Data(json.utf8))
    #expect(c.accessToken == "sk-ant-oat01-x")
    #expect(c.subscriptionType == "max")
    #expect(c.expiresAt == Date(timeIntervalSince1970: 1_893_456_000))
    #expect(throws: ProviderError.notLoggedIn) { try ClaudeCredentials.parse(Data(#"{"mcpOAuth":{}}"#.utf8)) }
}

@Test func codexCredentialsParsing() throws {
    // id_token payload: {"email":"me@example.com","https://api.openai.com/auth":{"chatgpt_account_id":"acc-1","chatgpt_plan_type":"plus"}}
    let payload = Data(#"{"email":"me@example.com","https://api.openai.com/auth":{"chatgpt_account_id":"acc-1","chatgpt_plan_type":"plus"}}"#.utf8)
        .base64EncodedString().replacingOccurrences(of: "=", with: "")
    let json = #"{"tokens":{"access_token":"a.b.c","id_token":"h.\#(payload).s"}}"#
    let c = try CodexCredentials.parse(Data(json.utf8))
    #expect(c.accountID == "acc-1")
    #expect(c.email == "me@example.com")
    #expect(c.plan == "plus")
}
