import Foundation
import Testing
@testable import QuotaCore

struct PaceForecastTests {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Prague")!
        return c
    }()

    @Test func windowLengthByKindAndOverride() {
        let reset = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01 10:00 UTC
        #expect(UsageWindow(id: "s", kind: .session, title: "S", usedPercent: 0, resetsAt: reset).windowLength(calendar: cal) == 18_000)
        #expect(UsageWindow(id: "w", kind: .weekly, title: "W", usedPercent: 0, resetsAt: reset).windowLength(calendar: cal) == 604_800)
        #expect(UsageWindow(id: "m", kind: .monthly, title: "M", usedPercent: 0, resetsAt: reset).windowLength(calendar: cal) != nil)
        #expect(UsageWindow(id: "m", kind: .model, title: "M", usedPercent: 0, resetsAt: reset).windowLength(calendar: cal) == nil)
        #expect(UsageWindow(id: "c", kind: .credits, title: "C", usedPercent: 0, resetsAt: reset).windowLength(calendar: cal) == nil)
        #expect(UsageWindow(id: "x", kind: .session, title: "X", usedPercent: 0, resetsAt: reset, windowSeconds: 7_200).windowLength(calendar: cal) == 7_200)
        #expect(UsageWindow(id: "x", kind: .session, title: "X", usedPercent: 0, resetsAt: nil).windowLength(calendar: cal) == 18_000)
    }

    @Test func paceSessionWindow() throws {
        let reset = Date(timeIntervalSince1970: 1_735_689_600) // 10:00
        let start = reset.addingTimeInterval(-18_000) // 05:00
        let now = start.addingTimeInterval(10_800) // 08:00 -> 60% elapsed
        let window = UsageWindow(id: "s", kind: .session, title: "Session", usedPercent: 40, resetsAt: reset)

        let pace = try #require(window.pace(now: now, calendar: cal))
        #expect(abs(pace.elapsedFraction - 0.6) < 0.001)
        #expect(abs(pace.expectedPercent - 60) < 0.001)
        #expect(abs(pace.deltaPercent - (-20)) < 0.001)
        #expect(pace.status == .under)
        #expect(pace.label == "20% under pace")

        let over = UsageWindow(id: "s", kind: .session, title: "Session", usedPercent: 75, resetsAt: reset)
        let pace2 = try #require(over.pace(now: now, calendar: cal))
        #expect(pace2.status == .over)
        #expect(pace2.label == "15% over pace")

        let on = UsageWindow(id: "s", kind: .session, title: "Session", usedPercent: 62, resetsAt: reset)
        let pace3 = try #require(on.pace(now: now, calendar: cal))
        #expect(pace3.status == .onPace)
        #expect(pace3.label == "on pace")

        #expect(window.pace(now: start.addingTimeInterval(-1), calendar: cal) == nil)
        #expect(window.pace(now: reset, calendar: cal) == nil)
    }

    @Test func forecastRecentRate() throws {
        let reset = Date(timeIntervalSince1970: 1_735_689_600 + 7_200) // +2h
        let now = reset.addingTimeInterval(-7_200)
        let window = UsageWindow(id: "s", kind: .session, title: "Session", usedPercent: 50, resetsAt: reset)
        let samples = (0..<6).map { i in
            UsageSample(at: now.addingTimeInterval(Double(i - 5) * 360), percent: 40 + Double(i) * 2)
        } // 40..50 over 30 min ending at now -> 20 pt/h
        let f = try #require(UsageForecaster.forecast(window: window, samples: samples, now: now, calendar: cal))
        #expect(abs(f.projectedPercent - 90) < 0.5)
        #expect(f.risk == .watch)
        #expect(f.runsOutAt == nil)
        #expect(f.basis == .recent)
        #expect(abs(f.ratePerHour - 20) < 0.5)
    }

    @Test func forecastRunsOut() throws {
        let reset = Date(timeIntervalSince1970: 1_735_689_600 + 7_200)
        let now = reset.addingTimeInterval(-7_200)
        let window = UsageWindow(id: "s", kind: .session, title: "Session", usedPercent: 60, resetsAt: reset)
        let samples = (0..<6).map { i in
            UsageSample(at: now.addingTimeInterval(Double(i - 5) * 360), percent: 40 + Double(i) * 4)
        } // 40..60 over 30 min -> 40 pts/h
        let f = try #require(UsageForecaster.forecast(window: window, samples: samples, now: now, calendar: cal))
        #expect(f.risk == .atRisk)
        let runsOut = try #require(f.runsOutAt)
        #expect(abs(runsOut.timeIntervalSince(now) - 3_600) < 1, "runsOutAt should be now + 1h")
        #expect(f.label(now: now, calendar: cal, locale: Locale(identifier: "en_US_POSIX")).contains("before reset"))
    }

    @Test func forecastWindowAverageFallback() throws {
        let reset = Date(timeIntervalSince1970: 1_735_689_600 + 7_200)
        let now = reset.addingTimeInterval(-7_200)
        let window = UsageWindow(id: "s", kind: .session, title: "Session", usedPercent: 30, resetsAt: reset, windowSeconds: 18_000)
        let f = try #require(UsageForecaster.forecast(window: window, samples: [], now: now, calendar: cal))
        #expect(f.basis == .windowAverage)
        #expect(abs(f.ratePerHour - 10) < 0.01) // 30 pts / 3 h = 10 pt/h
        #expect(abs(f.projectedPercent - 50) < 0.5) // 30 + 10 * 2
    }

    @Test func forecastNilWhenNoData() {
        let reset = Date(timeIntervalSince1970: 1_735_689_600 + 7_200)
        let now = reset.addingTimeInterval(-7_200)
        let window = UsageWindow(id: "s", kind: .model, title: "Model", usedPercent: 30, resetsAt: reset)
        #expect(UsageForecaster.forecast(window: window, samples: [], now: now, calendar: cal) == nil)
    }

    @Test func forecastResetDrop() throws {
        let reset = Date(timeIntervalSince1970: 1_735_689_600 + 7_200)
        let now = reset.addingTimeInterval(-7_200)
        let window = UsageWindow(id: "s", kind: .session, title: "Session", usedPercent: 10, resetsAt: reset)
        let samples = [
            UsageSample(at: now.addingTimeInterval(-3_600), percent: 80),
            UsageSample(at: now.addingTimeInterval(-1_800), percent: 90),
            UsageSample(at: now.addingTimeInterval(-600), percent: 5),
        ]
        let f = try #require(UsageForecaster.forecast(window: window, samples: samples, now: now, calendar: cal))
        // Samples before the drop are discarded: 5 -> 10 over the last 10 min = 30 pt/h, 10 + 30 * 2 = 70.
        #expect(f.basis == .recent)
        #expect(abs(f.ratePerHour - 30) < 0.01)
        #expect(abs(f.projectedPercent - 70) < 0.01)
    }

    @Test func forecastExhausted() throws {
        let reset = Date(timeIntervalSince1970: 1_735_689_600 + 7_200)
        let now = reset.addingTimeInterval(-7_200)
        let window = UsageWindow(id: "s", kind: .session, title: "Session", usedPercent: 100, resetsAt: reset)
        let f = try #require(UsageForecaster.forecast(window: window, samples: [], now: now, calendar: cal))
        #expect(f.risk == .exhausted)
        #expect(f.label() == "limit reached")
        #expect(f.runsOutAt == nil)
    }

    @Test func historyDedupeAndReset() {
        var history = UsageHistory()
        let now = Date(timeIntervalSince1970: 1_735_689_600)
        let snap1 = UsageSnapshot(provider: .claude, account: "a", plan: "Pro", windows: [
            UsageWindow(id: "w1", kind: .session, title: "S", usedPercent: 50, resetsAt: now.addingTimeInterval(3_600))
        ], credits: [])
        history.record(snap1, at: now)
        #expect(history.samples(instanceID: "claude", windowID: "w1").count == 1)
        history.record(snap1, at: now.addingTimeInterval(60)) // same percent within 120s -> skipped
        #expect(history.samples(instanceID: "claude", windowID: "w1").count == 1)
        let snap2 = UsageSnapshot(provider: .claude, account: "a", plan: "Pro", windows: [
            UsageWindow(id: "w1", kind: .session, title: "S", usedPercent: 10, resetsAt: now.addingTimeInterval(3_600))
        ], credits: [])
        history.record(snap2, at: now.addingTimeInterval(300)) // reset drop -> only new sample
        #expect(history.samples(instanceID: "claude", windowID: "w1").count == 1)
        #expect(history.samples(instanceID: "claude", windowID: "w1").first?.percent == 10)
    }

    @Test func historySaveLoadRoundtrip() throws {
        var history = UsageHistory()
        let now = Date(timeIntervalSince1970: 1_735_689_600)
        let snap = UsageSnapshot(provider: .claude, account: "a", plan: "Pro", windows: [
            UsageWindow(id: "w1", kind: .session, title: "S", usedPercent: 50, resetsAt: now.addingTimeInterval(3_600))
        ], credits: [])
        history.record(snap, at: now)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try history.save(to: url)
        let loaded = UsageHistory.load(from: url)
        #expect(loaded.samples.count == history.samples.count)
        try? FileManager.default.removeItem(at: url)
    }

    @Test func usageWindowDecodesWithoutWindowSeconds() throws {
        let json = """
        {"id":"w1","kind":"session","title":"Session","usedPercent":50,"resetsAt":null,"prominent":true}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let w = try decoder.decode(UsageWindow.self, from: json)
        #expect(w.windowSeconds == nil)
    }
}
