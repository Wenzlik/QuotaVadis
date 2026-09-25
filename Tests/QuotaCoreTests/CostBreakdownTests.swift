import Foundation
import Testing
@testable import QuotaCore

private func bucket(_ id: String, cost: Double, tokens: Int) -> CostBucket {
    CostBucket(id: id, tokens: TokenCounts(input: tokens), costUSD: cost, requests: 1)
}

@Test func breakdownRanksBySelectedMetric() {
    // Stored order is by cost; by tokens the cheap-but-chatty model must come first.
    let buckets = [bucket("opus", cost: 9, tokens: 10), bucket("haiku", cost: 1, tokens: 900), bucket("sonnet", cost: 5, tokens: 90)]
    #expect(CostBreakdown.rows(buckets, metric: .cost).map(\.id) == ["opus", "sonnet", "haiku"])
    #expect(CostBreakdown.rows(buckets, metric: .tokens).map(\.id) == ["haiku", "sonnet", "opus"])
    #expect(abs(CostBreakdown.rows(buckets, metric: .tokens)[0].share - 0.9) < 1e-9)
}

@Test func breakdownFoldsRestIntoOtherLast() {
    let buckets = (1...8).map { bucket("m\($0)", cost: Double($0), tokens: 100) }
    let rows = CostBreakdown.rows(buckets, metric: .cost, top: 5)
    #expect(rows.count == 6)
    #expect(rows.last?.isOther == true)
    #expect(rows.last?.folded == 3)
    #expect(rows.last?.bucket.costUSD == 6) // m1 + m2 + m3
    #expect(abs(rows.reduce(0) { $0 + $1.share } - 1) < 1e-9)
    // Equal token counts: order is stable by id, not by whatever the input order was.
    #expect(CostBreakdown.rows(buckets.reversed(), metric: .tokens, top: 3).map(\.id) == ["m1", "m2", "m3", "Other (5)"])
}

@Test func breakdownAllZeroHasZeroShare() {
    let rows = CostBreakdown.rows([bucket("a", cost: 0, tokens: 0)], metric: .cost)
    #expect(rows.first?.share == 0)
}

@Test func dayDatesUseReportTimeZone() throws {
    var report = CostReport(provider: .claude, days: [CostBucket(id: "2026-03-05")], byModel: [], byProject: [], source: "test")
    report.timeZoneID = "Pacific/Auckland"
    let date = try #require(report.date(of: report.days[0]))
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Pacific/Auckland")!
    #expect(cal.dateComponents([.year, .month, .day, .hour], from: date) == DateComponents(year: 2026, month: 3, day: 5, hour: 0))
    #expect(report.date(of: CostBucket(id: "garbage")) == nil)
}
