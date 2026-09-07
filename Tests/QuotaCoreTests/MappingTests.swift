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
    #expect(s.windows.map(\.prominent) == [true, false, false])
    #expect(s.worstWindow?.id == "plan")
    #expect(s.seat == nil)
    #expect(s.credits.map(\.id) == ["plan", "on-demand"])
    #expect(s.credits[0].used == 13.40)
    #expect(s.credits[0].limit == 20)   // 1340/2000 = 67% agrees with totalPercentUsed 67
    #expect(s.credits[1].usedPercent == 5)
    #expect(s.secondaryWindow?.id == "plan")
}

@Test func cursorPooledSeatHidesBogusLimit() throws {
    let json = #"{"billingCycleEnd":"2026-09-22T17:25:37.000Z","membershipType":"enterprise","limitType":"team","individualUsage":{"plan":{"enabled":true,"used":713,"limit":2000,"totalPercentUsed":2.852}}}"#
    let r = try JSONDecoder().decode(CursorUsageSummary.self, from: Data(json.utf8))
    let s = CursorUsageFetcher.snapshot(from: r, account: nil)
    #expect(s.windows.first?.usedPercent == 2.852)
    #expect(s.credits.isEmpty)
}

@Test func cursorGrokBot() throws {
    let r = try JSONDecoder().decode(CursorUsageSummary.self, from: fixture("cursor_usage"))
    let bot = CursorBotUsage(nextResetTimestampUtc: "2026-09-08T00:00:00.000Z", usagePercent: 12, hasNonZeroIncludedLimit: true)
    let s = CursorUsageFetcher.snapshot(from: r, bot: bot, account: nil)
    #expect(s.windows.last?.id == "grok-bot")
    #expect(s.windows.last?.usedPercent == 12)
    #expect(s.windows.last?.prominent == true)
    let idle = CursorUsageFetcher.snapshot(from: r, bot: CursorBotUsage(nextResetTimestampUtc: nil, usagePercent: 0, hasNonZeroIncludedLimit: true), account: nil)
    #expect(idle.windows.last?.prominent == false)
    let none = CursorUsageFetcher.snapshot(from: r, bot: CursorBotUsage(nextResetTimestampUtc: nil, usagePercent: 0, hasNonZeroIncludedLimit: false), account: nil)
    #expect(!none.windows.contains { $0.id == "grok-bot" })
}

@Test func seatLabels() {
    #expect(ClaudeUsageFetcher.seatLabel(seatTier: "team_tier_1", rateTier: "default_claude_max_5x") == "Premium seat · Max 5x")
    #expect(ClaudeUsageFetcher.seatLabel(seatTier: "team_standard", rateTier: nil) == "Standard seat")
    #expect(ClaudeUsageFetcher.seatLabel(seatTier: nil, rateTier: "default_claude_max_20x") == "Max 20x")
    #expect(ClaudeUsageFetcher.seatLabel(seatTier: nil, rateTier: nil) == nil)
    #expect(ClaudeUsageFetcher.planLabel("claude_team") == "Team")
    #expect(CodexUsageFetcher.seatLabel("self_serve_business_prolite") == "Premium seat")
    #expect(CodexUsageFetcher.planLabel("self_serve_business_prolite") == "Business")
    #expect(CodexUsageFetcher.seatLabel("self_serve_business") == "Standard seat")
    #expect(CodexUsageFetcher.seatLabel("enterprise") == "Standard seat")
    #expect(CursorUsageFetcher.planLabel("enterprise") == "Team")
    #expect(CursorUsageFetcher.seatLabel(billingTier: "TEAM_MEMBER_BILLING_TIER_TIER_1000") == "Standard seat")
    #expect(CursorUsageFetcher.seatLabel(billingTier: "TEAM_MEMBER_BILLING_TIER_TIER_2000") == "Premium seat")
    #expect(CursorUsageFetcher.seatLabel(billingTier: nil) == nil)
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

@Test func codexResetCreditsDecoding() throws {
    let json = #"{"available_count":2,"credits":[{"status":"available","expires_at":"2026-10-04T02:34:40.360238Z"},{"status":"redeemed","expires_at":"2026-09-01T00:00:00Z"},{"status":"available","expires_at":"2026-09-21T00:12:35.149476Z"}]}"#
    let r = try JSONDecoder().decode(CodexResetCreditsResponse.self, from: Data(json.utf8))
    #expect(r.availableCount == 2)
    let dates = r.credits.filter { $0.status == "available" }.compactMap { ISO8601DateFormatter.parseAny($0.expiresAt) }.sorted()
    #expect(dates.count == 2)
    #expect(dates.first! < dates.last!)
}

@Test func claudeRefreshTokenParsed() throws {
    let json = #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1893456000000}}"#
    let c = try ClaudeCredentials.parse(Data(json.utf8))
    #expect(c.refreshToken == "r")
}

@Test func codexBinaryLookupHonoursPath() {
    let url = CodexCLI.binaryURL(environment: ["PATH": "/nonexistent"])
    // Either a standard install location resolves or nothing does; never a path from the bogus PATH entry.
    #expect(url == nil || !url!.path.hasPrefix("/nonexistent"))
}

@Test func antigravityMapping() throws {
    let summary = #"{"response":{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","displayName":"Weekly Limit Remaining","window":"weekly","remainingFraction":0.75,"resetTime":"2026-09-13T16:59:01Z"}]},{"displayName":"Claude and GPT models","buckets":[{"bucketId":"3p-weekly","window":"weekly","remainingFraction":1,"resetTime":"2026-09-13T16:59:01Z"}]}]}}"#
    let status = #"{"userStatus":{"email":"me@example.com","planStatus":{"planInfo":{"planName":"Pro"}},"userTier":{"id":"free-tier","name":"Antigravity Starter Quota"}}}"#
    let s = AntigravityUsageFetcher.snapshot(summary: try JSONDecoder().decode(AntigravityQuotaSummary.self, from: Data(summary.utf8)),
                                             status: try JSONDecoder().decode(AntigravityUserStatus.self, from: Data(status.utf8)))
    #expect(s.windows.map(\.id) == ["gemini-weekly", "3p-weekly"])
    #expect(s.windows[0].title == "Gemini models")
    #expect(abs(s.windows[0].usedPercent - 25) < 0.001)
    #expect(s.windows[1].usedPercent == 0)
    #expect(s.windows[0].kind == .weekly)
    #expect(s.plan == "Starter")
    #expect(s.seat == nil)
    #expect(s.account == "me@example.com")
}

@Test func alertEngineThresholdAndReset() {
    var engine = QuotaAlertEngine(warnAtPercent: 80, notifyOnReset: true)
    func snap(_ pct: Double) -> UsageSnapshot {
        UsageSnapshot(provider: .codex, account: nil, plan: nil, windows: [UsageWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: pct, resetsAt: nil)])
    }
    #expect(engine.evaluate(snapshots: [snap(50)]).isEmpty)
    let first = engine.evaluate(snapshots: [snap(95)])
    #expect(first.count == 1 && first[0].kind == .threshold)
    #expect(engine.evaluate(snapshots: [snap(97)]).isEmpty)          // no repeat while above
    let reset = engine.evaluate(snapshots: [snap(2)])
    #expect(reset.count == 1 && reset[0].kind == .reset)
    engine.snooze(key: "codex/weekly")
    #expect(engine.evaluate(snapshots: [snap(99)]).isEmpty)          // snoozed
}

@Test func resetLabelShapes() {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Prague")!
    let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 12, minute: 0))!
    let today = cal.date(byAdding: .hour, value: 1, to: now)!
    let label = today.resetLabel(now: now, calendar: cal)
    #expect(label.contains("·"))
    let nextWeek = cal.date(byAdding: .day, value: 10, to: now)!
    #expect(nextWeek.resetLabel(now: now, calendar: cal).contains("·"))
}

@Test func cursorSubWindowPromotedWhenBinding() throws {
    let json = #"{"billingCycleEnd":"2026-09-22T17:25:37.000Z","membershipType":"enterprise","limitType":"team","individualUsage":{"plan":{"enabled":true,"used":700,"limit":2000,"totalPercentUsed":14,"autoPercentUsed":8.8,"apiPercentUsed":41.5}}}"#
    let r = try JSONDecoder().decode(CursorUsageSummary.self, from: Data(json.utf8))
    let s = CursorUsageFetcher.snapshot(from: r, account: nil)
    #expect(s.windows.first { $0.id == "api" }?.prominent == true)
    #expect(s.windows.first { $0.id == "auto" }?.prominent == false)
    #expect(s.worstWindow?.id == "api")
}

@Test func extraUsageAlerts() {
    var engine = QuotaAlertEngine(warnAtPercent: 80, notifyOnReset: false)
    func snap(_ used: Double, weekly: Double) -> UsageSnapshot {
        UsageSnapshot(provider: .claude, account: nil, plan: "Team",
                      windows: [UsageWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: weekly, resetsAt: nil)],
                      credits: [UsageCredits(id: "extra", title: "Extra usage", used: used, limit: 20)])
    }
    #expect(engine.evaluate(snapshots: [snap(1.00, weekly: 40)]).isEmpty)          // baseline only
    let a = engine.evaluate(snapshots: [snap(1.50, weekly: 40)])
    #expect(a.count == 1 && a[0].kind == .extraUsageUnexpected)
    #expect(engine.evaluate(snapshots: [snap(1.80, weekly: 40)]).isEmpty)          // cooldown
    var later = engine; later.snoozed = [:]
    let b = later.evaluate(snapshots: [snap(2.50, weekly: 100)])
    #expect(b.contains { $0.kind == .extraUsageAtLimit })     // plus the threshold alert for 100%
    // Reset in 30 minutes: the title says so.
    var soon = QuotaAlertEngine(warnAtPercent: 101, notifyOnReset: false, creditBaseline: ["claude/credit/extra": 1])
    let now = Date()
    let s = UsageSnapshot(provider: .claude, account: nil, plan: nil,
                          windows: [UsageWindow(id: "session", kind: .session, title: "Session", usedPercent: 100, resetsAt: now.addingTimeInterval(1800))],
                          credits: [UsageCredits(id: "extra", title: "Extra usage", used: 1.4, limit: nil)])
    let c = soon.evaluate(snapshots: [s], now: now)
    #expect(c.count == 1 && c[0].title.contains("reset in 30 min"))
    var off = QuotaAlertEngine(warnAtPercent: 80, notifyOnReset: false, notifyExtraUsage: false, creditBaseline: ["claude/credit/extra": 1])
    #expect(off.evaluate(snapshots: [snap(5, weekly: 40)]).isEmpty)
}

@Test func rateLimitGateBacksOff() async {
    let gate = RateLimitGate()
    let now = Date()
    #expect(await gate.isBlocked("api.example.com", now: now) == false)
    await gate.recordLimit("api.example.com", retryAfter: nil, now: now)
    #expect(await gate.isBlocked("api.example.com", now: now.addingTimeInterval(299)) == true)
    #expect(await gate.isBlocked("api.example.com", now: now.addingTimeInterval(301)) == false)
    await gate.recordLimit("api.example.com", retryAfter: "900", now: now)
    #expect(await gate.isBlocked("api.example.com", now: now.addingTimeInterval(899)) == true)
    await gate.recordSuccess("api.example.com")
    #expect(await gate.isBlocked("api.example.com", now: now) == false)
}

private struct CountingFetcher: UsageFetcher {
    let provider: ProviderID
    let counter: Counter
    func isAvailable() -> Bool { true }
    func fetch() async throws -> UsageSnapshot {
        await counter.bump()
        return UsageSnapshot(provider: provider, account: nil, plan: nil, windows: [UsageWindow(id: "w", kind: .session, title: "S", usedPercent: 1, resetsAt: nil)])
    }
    func fetchRaw() async throws -> Data { Data() }
}
private actor Counter { var n = 0; func bump() { n += 1 } }

@Test func claudeIsPolledAtMostEveryFiveMinutes() async {
    let claude = Counter(), codex = Counter()
    let service = UsageService(fetchers: [CountingFetcher(provider: .claude, counter: claude), CountingFetcher(provider: .codex, counter: codex)])
    _ = await service.refresh(); _ = await service.refresh(); _ = await service.refresh()
    #expect(await claude.n == 1)
    #expect(await codex.n == 3)
}

@Test func adaptivePolicyTable() {
    let now = Date()
    func d(_ i: AdaptiveRefreshPolicy.Input) -> (TimeInterval, AdaptiveRefreshPolicy.Reason) { AdaptiveRefreshPolicy.next(i) }
    #expect(d(.init(now: now, lowPowerOrHot: true)) == (1800, .constrained))
    #expect(d(.init(now: now, lastPanelOpen: now.addingTimeInterval(-60))) == (120, .recentInteraction))
    #expect(d(.init(now: now, lastPanelOpen: now.addingTimeInterval(-1800))) == (300, .warm))
    #expect(d(.init(now: now, lastPanelOpen: now.addingTimeInterval(-7200), lastCodingActivity: now.addingTimeInterval(-60))) == (300, .codingActivity))
    #expect(d(.init(now: now, lastPanelOpen: now.addingTimeInterval(-7200))) == (900, .idle))
    #expect(d(.init(now: now)) == (1800, .longIdle))
}

@Test func claudeWebOrganizationDecoding() throws {
    let json = #"[{"uuid":"o1","name":"Acme","capabilities":["chat","raven"],"rate_limit_tier":"default_raven","billing_type":"stripe_subscription"},{"uuid":"o2","name":"API only","capabilities":["api"]}]"#
    let orgs = try JSONDecoder().decode([ClaudeWebUsageFetcher.Organization].self, from: Data(json.utf8))
    #expect(orgs.count == 2)
    #expect(ClaudeWebUsageFetcher.inferredType(orgs[0]) == "claude_team")
    #expect(ClaudeWebUsageFetcher.inferredType(orgs[1]) == nil)
    let profile = ClaudeProfileResponse(account: .init(email: "a@b.c", displayName: nil),
                                        organization: .init(name: "Acme", organizationType: "claude_team", rateLimitTier: "default_raven", seatTier: "team_tier_1"))
    let usage = try JSONDecoder().decode(ClaudeUsageResponse.self, from: fixture("claude_usage"))
    let s = ClaudeUsageFetcher.snapshot(from: usage, plan: nil, profile: profile)
    #expect(s.organization == "Acme" && s.plan == "Team" && s.seat == "Premium seat")
}

@Test func chromiumV10DecryptRoundTrip() throws {
    #if os(macOS)
    let key = try ChromiumCookieStore.deriveKey(password: "test-password")
    #expect(key.count == 16)
    #expect(ChromiumCookieStore.decrypt(Data("v10".utf8), key: key, hostKey: ".claude.ai") == nil)
    #endif
}
