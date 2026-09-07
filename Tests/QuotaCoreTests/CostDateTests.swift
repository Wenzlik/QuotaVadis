import Foundation
import Testing
@testable import QuotaCore

@Test func yesterdayIsNeverReportedAsToday() {
    let now = Date()
    let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
    let report = CostReport(provider: .codex, days: [CostBucket(id: CostAccumulator.dayKey(yesterday), costUSD: 12)],
                            byModel: [], byProject: [], generatedAt: yesterday, source: "Test")
    #expect(report.day(at: now) == nil)
    #expect(report.day(at: yesterday)?.costUSD == 12)
}

@Test func costDayUsesPublishingMacTimeZone() {
    let now = Date(timeIntervalSince1970: 1_788_825_600) // Same instant on both devices.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Pacific/Honolulu")!
    let key = CostAccumulator.dayKey(now, calendar: calendar)
    var report = CostReport(provider: .codex, days: [CostBucket(id: key, costUSD: 7)], byModel: [], byProject: [], source: "Test")
    report.timeZoneID = calendar.timeZone.identifier
    #expect(report.day(at: now)?.costUSD == 7)
    #expect(report.day(at: now.addingTimeInterval(86400)) == nil)
}
