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
}

@Test func codexMapping() throws {
    let r = try JSONDecoder().decode(CodexUsageResponse.self, from: fixture("codex_usage"))
    let s = CodexUsageFetcher.snapshot(from: r, account: "me@example.com", fallbackPlan: nil)
    #expect(s.plan == "Plus")
    #expect(s.windows.map(\.id) == ["session", "weekly", "gpt-5.3-codex-spark-session"])
    #expect(s.secondaryWindow?.usedPercent == 55)
    #expect(s.primaryWindow?.resetsAt == Date(timeIntervalSince1970: 1_757_100_000))
}

@Test func cursorMapping() throws {
    let r = try JSONDecoder().decode(CursorUsageSummary.self, from: fixture("cursor_usage"))
    let s = CursorUsageFetcher.snapshot(from: r, account: nil)
    #expect(s.plan == "Pro")
    #expect(s.windows.map(\.id) == ["plan", "on-demand"])
    #expect(s.windows[0].usedPercent == 67)
    #expect(s.windows[1].usedPercent == 5)
    #expect(s.secondaryWindow?.id == "plan")
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
