import Foundation
import Testing
@testable import QuotaCore

private let combineNow = Date(timeIntervalSince1970: 1_791_000_000)

private func reading(_ provider: ProviderID = .codex, account: String? = "user@example.com", org: String? = nil,
                     percent: Double = 55, age: TimeInterval = 0) -> UsageSnapshot {
    UsageSnapshot(provider: provider, account: account, organization: org, plan: nil,
                  windows: [UsageWindow(id: "session", kind: .session, title: "Session", usedPercent: percent, resetsAt: nil)],
                  credits: [UsageCredits(id: "credits", title: "Credits", used: 12, limit: 100)],
                  fetchedAt: combineNow.addingTimeInterval(-age))
}

private func report(_ provider: ProviderID, cost: Double, age: TimeInterval = 0) -> CostReport {
    var report = CostReport(provider: provider,
                           days: [CostBucket(id: CostAccumulator.dayKey(combineNow), tokens: TokenCounts(input: 100), costUSD: cost, requests: 1)],
                           byModel: [], byProject: [], generatedAt: combineNow.addingTimeInterval(-age), source: "test")
    report.timeZoneID = TimeZone.current.identifier
    return report
}

@Test func combinedQuotasKeepNewestAccountReadingAndPreserveStatus() {
    let newest = reading(account: " USER@example.com ", percent: 65)
    let status = ProviderSyncStatus(instanceID: newest.instanceID, provider: .codex,
                                    state: .failed(.unauthorized, last: newest), lastAttemptAt: combineNow)
    let a = DevicePayload(deviceID: "a", deviceName: "Book", snapshots: [reading(age: 900)], costs: [])
    let b = DevicePayload(deviceID: "b", deviceName: "Studio", snapshots: [newest], costs: [], providerStatuses: [status])
    let result = CombinedUsage(devices: [a, b], now: combineNow)
    #expect(result.readings.count == 1)
    #expect(result.readings[0].snapshot.windows[0].usedPercent == 65)
    #expect(result.readings[0].snapshot.credits[0].used == 12)
    #expect(result.readings[0].deviceID == "b")
    #expect(result.readings[0].status.errorCode == .loginRequired)
    #expect(result.readings[0].status.freshness(now: combineNow) == .stale)
}

@Test func combinedAccountsAndUnknownIdentitiesRemainSeparate() {
    let a = DevicePayload(deviceID: "a", deviceName: "Same name", snapshots: [reading(account: nil)], costs: [])
    let b = DevicePayload(deviceID: "b", deviceName: "Same name", snapshots: [reading(account: " ")], costs: [])
    let c = DevicePayload(deviceID: "c", deviceName: "C", snapshots: [reading(org: "One")], costs: [])
    let d = DevicePayload(deviceID: "d", deviceName: "D", snapshots: [reading(org: "Two")], costs: [])
    let e = DevicePayload(deviceID: "e", deviceName: "E", snapshots: [reading(account: "other@example.com", org: "One")], costs: [])
    #expect(CombinedUsage(devices: [a, b, c, d, e], now: combineNow).readings.count == 5)
    #expect(CombinedUsage(devices: [], now: combineNow).costs.isEmpty)
}

@Test func combinedCostsSumLocalLogsButDedupeCursorAndDevicePayloads() throws {
    let a = DevicePayload(deviceID: "a", deviceName: "Book", snapshots: [reading(.cursor)],
                          costs: [report(.claude, cost: 2), report(.codex, cost: 3), report(.cursor, cost: 7, age: 60)])
    let b = DevicePayload(deviceID: "b", deviceName: "Studio", snapshots: [reading(.cursor)],
                          costs: [report(.claude, cost: 4), report(.codex, cost: 5), report(.cursor, cost: 8)])
    let c = DevicePayload(deviceID: "c", deviceName: "Other", snapshots: [reading(.cursor, account: "other@example.com")],
                          costs: [report(.cursor, cost: 10)])
    let unknown = DevicePayload(deviceID: "u", deviceName: "Unknown", snapshots: [], costs: [report(.cursor, cost: 99)])
    let result = CombinedUsage(devices: [a, b, a, c, unknown], now: combineNow)
    #expect(result.devices.count == 4)
    #expect(result.costs.first { $0.provider == .claude }?.costUSD == 6)
    #expect(result.costs.first { $0.provider == .codex }?.costUSD == 8)
    #expect(result.costs.first { $0.provider == .cursor }?.costUSD == 18)
    #expect(result.costs.first { $0.provider == .cursor }?.tokens == 200)
    #expect(result.unidentifiedCursorReports == 1)
    // The unchanged sync schema round-trips and still contains no merged data.
    #expect(try DevicePayload.decode(a.encoded()).costs.count == 3)
}

@Test func combinedCostsRespectRollingWindowAndPublisherCalendar() throws {
    var cost = report(.codex, cost: 3)
    cost.timeZoneID = "Pacific/Kiritimati"
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Pacific/Kiritimati"))
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 0)))
    cost.days = [CostBucket(id: "2026-09-02", costUSD: 100), CostBucket(id: "2026-09-03", costUSD: 2),
                 CostBucket(id: "2026-10-02", costUSD: 3), CostBucket(id: "2026-10-03", costUSD: 100)]
    let payload = DevicePayload(deviceID: "a", deviceName: "A", snapshots: [], costs: [cost])
    #expect(CombinedUsage(devices: [payload], now: now).costs.first?.costUSD == 5)
}
