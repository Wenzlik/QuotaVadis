import Foundation
import Testing
@testable import QuotaCore

@Test func codexModelLimitRemainsSignificantWhenCollapsed() throws {
    let json = #"{"rate_limit":{"primary_window":{"used_percent":10,"reset_at":1788806972}},"additional_rate_limits":[{"limit_name":"Spark","rate_limit":{"primary_window":{"used_percent":100,"reset_at":1788806972}}}]}"#
    let response = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
    let snapshot = CodexUsageFetcher.snapshot(from: response, account: nil, fallbackPlan: nil)
    #expect(snapshot.worstWindow?.usedPercent == 100)
    #expect(snapshot.worstWindow?.title == "Spark session")
    #expect(snapshot.compactWindows.first?.id == snapshot.worstWindow?.id)
    #expect(snapshot.overviewWindows.count == 2)
    #expect(snapshot.windows.last?.prominent == false)
    var alerts = QuotaAlertEngine(warnAtPercent: 80, notifyOnReset: true)
    let due = alerts.evaluate(snapshots: [snapshot])
    #expect(due.count == 1)
    #expect(due.first?.title.contains("Spark") == true)
    #expect(due.first?.body.contains("this model limit only") == true)
}

@Test func emptySchemasRejectedButCreditsOnlyAndUnlimitedAccepted() throws {
    for json in ["{}", #"{"rate_limit":{"primary_window":{"unexpected":true}}}"#] {
        let r = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
        #expect(throws: ProviderError.self) { try CodexUsageFetcher.snapshot(from: r, account: nil, fallbackPlan: nil).validated() }
    }
    let claude = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data("{}".utf8))
    #expect(throws: ProviderError.self) { try ClaudeUsageFetcher.snapshot(from: claude, plan: nil).validated() }
    for json in [#"{"credits":{"has_credits":true,"balance":10}}"#, #"{"credits":{"unlimited":true}}"#] {
        let r = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
        _ = try CodexUsageFetcher.snapshot(from: r, account: nil, fallbackPlan: nil).validated(allowUnlimited: r.credits?.unlimited == true)
    }
}
