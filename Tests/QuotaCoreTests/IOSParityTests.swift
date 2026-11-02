import Foundation
import Testing
@testable import QuotaCore

/// Shared logic the iOS app uses for the Mac's 0.6.0 features: summary items, main-bar pick, per-Mac history.
struct IOSParityTests {
    private let now = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01 00:00 UTC

    private func snapshot(_ percent: Double, fetchedAt: Date, instanceID: String? = nil) -> UsageSnapshot {
        UsageSnapshot(provider: .claude, instanceID: instanceID, account: nil, plan: nil, windows: [
            UsageWindow(id: "session", kind: .session, title: "Session", usedPercent: percent, resetsAt: now.addingTimeInterval(3 * 3_600)),
        ], fetchedAt: fetchedAt, deviceName: "test")
    }

    @Test func riskItemsPerSnapshot() {
        let reset = now.addingTimeInterval(86_400)
        let cursor = UsageSnapshot(provider: .cursor, account: nil, plan: nil, windows: [
            UsageWindow(id: "plan", kind: .monthly, title: "Included total", usedPercent: 32, resetsAt: reset),
            UsageWindow(id: "auto", kind: .model, title: "Auto", usedPercent: 30, resetsAt: reset, prominent: false),
        ], credits: [
            UsageCredits(id: "od", title: "On-demand", used: 1.04, limit: 1.00),
            UsageCredits(id: "plan", title: "Mirrors the window", used: 2, limit: 1),
        ], deviceName: "test")
        let fits = UsageForecast(projectedPercent: 60, runsOutAt: nil, resetsAt: reset, ratePerHour: 1, basis: .recent, risk: .safe)

        // The minor sub-window stays out while it fits; no forecast = "not enough data", not on track.
        let quiet = RiskItem.items(for: cursor, name: "Cursor", now: now) { $0.id == "plan" ? fits : nil }
        #expect(quiet.map(\.title) == ["Cursor · Included total", "Cursor · On-demand"])
        #expect(quiet[0].missingForecast == false)
        #expect(quiet[0].detail == fits.label(now: now))
        #expect(quiet[1].risk == .exhausted)

        // Once it runs out before its reset, it counts.
        let runsOut = UsageForecast(projectedPercent: 140, runsOutAt: now.addingTimeInterval(3_600), resetsAt: reset,
                                    ratePerHour: 5, basis: .recent, risk: .atRisk)
        let hot = RiskItem.items(for: cursor, name: "Cursor", now: now) { $0.id == "auto" ? runsOut : nil }
        #expect(hot.map(\.title) == ["Cursor · Included total", "Cursor · Auto", "Cursor · On-demand"])
        #expect(hot[0].missingForecast)
        #expect(hot[0].detail == UsageForecast.notEnoughDataLabel)
    }

    @Test func savedMainBarPickReadsAsDefaultWhileUnreported() {
        let s = snapshot(10, fetchedAt: now)
        #expect(s.reportedWindowID("session") == "session")
        #expect(s.reportedWindowID("gone") == nil)
        #expect(s.reportedWindowID(nil) == nil)
    }

    @Test func historyFromPayloadsUsesMeasurementTimePerMac() throws {
        var history = UsageHistory()
        let macA = DevicePayload(deviceID: "A", deviceName: "A", snapshots: [snapshot(10, fetchedAt: now)], costs: [])
        let macB = DevicePayload(deviceID: "B", deviceName: "B", snapshots: [snapshot(70, fetchedAt: now)], costs: [])
        history.record(payloads: [macA, macB])
        let keyA = UsageHistory.instanceID(deviceID: "A", instanceID: "claude")
        #expect(history.samples(instanceID: keyA, windowID: "session").map(\.at) == [now])
        // Same instance on another Mac: separate samples.
        #expect(history.samples(instanceID: UsageHistory.instanceID(deviceID: "B", instanceID: "claude"), windowID: "session")
            .map(\.percent) == [70])

        // The same payload read again, or an older one arriving late, adds nothing.
        history.record(payloads: [macA])
        let late = DevicePayload(deviceID: "A", deviceName: "A", snapshots: [snapshot(5, fetchedAt: now.addingTimeInterval(-600))], costs: [])
        history.record(payloads: [late])
        #expect(history.samples(instanceID: keyA, windowID: "session").map(\.percent) == [10])

        // A newer measurement 30 min later: two samples, so a recent-rate forecast from the phone's own history.
        let later = now.addingTimeInterval(1_800)
        let newer = snapshot(20, fetchedAt: later)
        let payload = DevicePayload(deviceID: "A", deviceName: "A", snapshots: [newer], costs: [])
        history.record(payloads: [payload])
        #expect(history.samples(instanceID: keyA, windowID: "session").map(\.percent) == [10, 20])
        let forecast = try #require(history.forecast(for: newer.windows[0], snapshot: newer, in: payload, now: later))
        #expect(forecast.basis == .recent)
        #expect(abs(forecast.ratePerHour - 20) < 0.001)

        // A measurement older than the Mac's stale threshold: no projection, not the current value.
        let stale = later.addingTimeInterval(ProviderSyncStatus.minimumStaleAfter + 60)
        #expect(history.forecast(for: newer.windows[0], snapshot: newer, in: payload, now: stale) == nil)
    }
}
