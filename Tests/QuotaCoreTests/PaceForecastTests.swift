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

    @Test func forecastIgnoresOnePointDip() throws {
        // Integer providers (Codex) can dip 51 -> 50 within the same window; that is not a reset.
        let reset = Date(timeIntervalSince1970: 1_735_689_600 + 7_200)
        let now = reset.addingTimeInterval(-7_200)
        let window = UsageWindow(id: "s", kind: .session, title: "Session", usedPercent: 50, resetsAt: reset)
        let samples = [
            UsageSample(at: now.addingTimeInterval(-1_800), percent: 40),
            UsageSample(at: now.addingTimeInterval(-1_200), percent: 46),
            UsageSample(at: now.addingTimeInterval(-600), percent: 51),
            UsageSample(at: now.addingTimeInterval(-300), percent: 50),
        ]
        let f = try #require(UsageForecaster.forecast(window: window, samples: samples, now: now, calendar: cal))
        // 40 -> 50 over 30 min = 20 pt/h, 50 + 20 * 2 = 90 (a reset would leave only 300 s -> window average).
        #expect(f.basis == .recent)
        #expect(abs(f.ratePerHour - 20) < 0.01)
        #expect(abs(f.projectedPercent - 90) < 0.01)
        #expect(!UsageForecaster.isReset(from: 51, to: 50))
        #expect(UsageForecaster.isReset(from: 3, to: 0))
        #expect(UsageForecaster.isReset(from: 60, to: 50))
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

    /// Regression: Session 16% / Weekly 2% / Codex 26% showed "fits, ends at ~16/2/26%". A flat last hour gave a
    /// recent rate of 0, so the "projection" was the current value. It must fall back to the window average.
    @Test func flatLastHourIsNotAProjectionOfCurrent() throws {
        let locale = Locale(identifier: "en_US_POSIX")
        let reset = Date(timeIntervalSince1970: 1_735_689_600)
        let now = reset.addingTimeInterval(-7_200) // session: 3 h elapsed, 2 h left
        let flat = (0...12).map { UsageSample(at: now.addingTimeInterval(Double(-300 * $0)), percent: 16) }
        let session = UsageWindow(id: "s", kind: .session, title: "Session", usedPercent: 16, resetsAt: reset)
        let f = try #require(UsageForecaster.forecast(window: session, samples: flat, now: now, calendar: cal))
        #expect(f.basis == .windowAverage)
        #expect(abs(f.ratePerHour - 16.0 / 3) < 0.01)
        #expect(abs(f.projectedPercent - (16 + 16.0 / 3 * 2)) < 0.01) // ~26.7
        #expect(f.label(now: now, calendar: cal, locale: locale) == "fits, ends at ~27%")

        // Weekly 2% one day in, flat for the last hour: 2 + 2 pt/day * 6 days = 14.
        let weekReset = now.addingTimeInterval(6 * 86_400)
        let weekly = UsageWindow(id: "w", kind: .weekly, title: "Weekly", usedPercent: 2, resetsAt: weekReset)
        let flat2 = flat.map { UsageSample(at: $0.at, percent: 2) }
        let w = try #require(UsageForecaster.forecast(window: weekly, samples: flat2, now: now, calendar: cal))
        #expect(abs(w.projectedPercent - 14) < 0.01)
        #expect(w.projectedPercent > weekly.usedPercent)
    }

    @Test func projectionIsCurrentPlusRateTimesRemaining() throws {
        let reset = Date(timeIntervalSince1970: 1_735_689_600)
        let now = reset.addingTimeInterval(-3 * 86_400)
        let window = UsageWindow(id: "w", kind: .weekly, title: "Weekly", usedPercent: 30, resetsAt: reset)
        let samples = [UsageSample(at: now.addingTimeInterval(-3_600), percent: 29), UsageSample(at: now, percent: 30)]
        let f = try #require(UsageForecaster.forecast(window: window, samples: samples, now: now, calendar: cal))
        #expect(f.basis == .recent)
        #expect(abs(f.ratePerHour - 1) < 0.001)
        #expect(abs(f.projectedPercent - (30 + 1 * 72)) < 0.01)
        #expect(f.risk == .atRisk) // 30 + 72 > 100: runs out ~70 h from now
    }

    @Test func zeroRateIsAMeasurementNotMissingData() throws {
        // Nothing used one hour into a session: a measured rate of 0 projects 0, honestly.
        let reset = Date(timeIntervalSince1970: 1_735_689_600)
        let now = reset.addingTimeInterval(-4 * 3_600)
        let window = UsageWindow(id: "s", kind: .session, title: "Session", usedPercent: 0, resetsAt: reset)
        let f = try #require(UsageForecaster.forecast(window: window, samples: [], now: now, calendar: cal))
        #expect(f.basis == .windowAverage)
        #expect(f.ratePerHour == 0)
        #expect(f.projectedPercent == 0)
        #expect(f.risk == .safe)
    }

    @Test func notEnoughDataGivesNoForecast() {
        let reset = Date(timeIntervalSince1970: 1_735_689_600)
        let now = reset.addingTimeInterval(-7_200)
        // No known start (model window) and a flat hour: used to project the current 26%, now no forecast.
        let model = UsageWindow(id: "m", kind: .model, title: "Model", usedPercent: 26, resetsAt: reset)
        let flat = (0...12).map { UsageSample(at: now.addingTimeInterval(Double(-300 * $0)), percent: 26) }
        #expect(UsageForecaster.forecast(window: model, samples: flat, now: now, calendar: cal) == nil)
        // Window just started (< 5 min) and no history.
        let session = UsageWindow(id: "s", kind: .session, title: "Session", usedPercent: 3, resetsAt: reset)
        let justStarted = reset.addingTimeInterval(-18_000 + 120)
        #expect(UsageForecaster.forecast(window: session, samples: [], now: justStarted, calendar: cal) == nil)
        // Without a forecast the risk is the usage level, never a forecast's "fits".
        #expect(UsageForecast.Risk(usedPercent: 26, forecast: nil) == .safe)
        #expect(UsageForecast.Risk(usedPercent: 95, forecast: nil) == .atRisk)
    }

    @Test func staleMeasurementGivesNoForecast() throws {
        let reset = Date(timeIntervalSince1970: 1_735_689_600)
        let start = reset.addingTimeInterval(-7 * 86_400)
        let measured = start.addingTimeInterval(86_400) // 50% one day into the week
        let weekly = UsageWindow(id: "w", kind: .weekly, title: "Weekly", usedPercent: 50, resetsAt: reset)
        // Refreshes failing for 2 h: the old 50% is not current usage, so no projection (and no warning).
        #expect(UsageForecaster.forecast(window: weekly, samples: [], now: measured.addingTimeInterval(7_200),
                                         measuredAt: measured, staleAfter: 900, calendar: cal) == nil)
        // Fresh enough: the window average runs to the measurement, not to the clock (50% per 24 h).
        let f = try #require(UsageForecaster.forecast(window: weekly, samples: [], now: measured.addingTimeInterval(600),
                                                      measuredAt: measured, staleAfter: 900, calendar: cal))
        #expect(f.basis == .windowAverage)
        #expect(abs(f.ratePerHour - 50.0 / 24) < 0.000_1)
        // A stale 100% is still exhausted: usage never drops within a window.
        let full = UsageWindow(id: "w", kind: .weekly, title: "Weekly", usedPercent: 100, resetsAt: reset)
        let e = try #require(UsageForecaster.forecast(window: full, samples: [], now: measured.addingTimeInterval(7_200),
                                                      measuredAt: measured, staleAfter: 900, calendar: cal))
        #expect(e.risk == .exhausted)
        #expect(ProviderSyncStatus.staleAfter(refreshInterval: 1_800) == 3_660)
    }

    @Test func resetInThePastOrNowGivesNoForecast() {
        let reset = Date(timeIntervalSince1970: 1_735_689_600)
        let window = UsageWindow(id: "s", kind: .session, title: "Session", usedPercent: 40, resetsAt: reset)
        #expect(UsageForecaster.forecast(window: window, samples: [], now: reset, calendar: cal) == nil)
        #expect(UsageForecaster.forecast(window: window, samples: [], now: reset.addingTimeInterval(60), calendar: cal) == nil)
        let noReset = UsageWindow(id: "s", kind: .session, title: "Session", usedPercent: 40, resetsAt: nil)
        #expect(UsageForecaster.forecast(window: noReset, samples: [], now: reset, calendar: cal) == nil)
    }

    @Test func windowEdges() throws {
        let reset = Date(timeIntervalSince1970: 1_735_689_600)
        let window = UsageWindow(id: "s", kind: .session, title: "Session", usedPercent: 50, resetsAt: reset)
        // One second before the reset: projection is current + rate * 1 s.
        let late = reset.addingTimeInterval(-1)
        let f = try #require(UsageForecaster.forecast(window: window, samples: [], now: late, calendar: cal))
        #expect(f.projectedPercent > 50 && f.projectedPercent < 50.01)
        #expect(f.runsOutAt == nil)
        // Exactly 5 min into the window: the window average is just allowed.
        let early = reset.addingTimeInterval(-18_000 + 300)
        let e = try #require(UsageForecaster.forecast(window: window, samples: [], now: early, calendar: cal))
        #expect(e.basis == .windowAverage)
        #expect(e.risk == .atRisk) // 50% in 5 min of a 5 h window
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

    @Test func historyKeepsOnePointDipAndResetsOnNewWindow() {
        var history = UsageHistory()
        let now = Date(timeIntervalSince1970: 1_735_689_600)
        func snap(_ percent: Double, resetsAt: Date) -> UsageSnapshot {
            UsageSnapshot(provider: .codex, account: "a", plan: "Plus", windows: [
                UsageWindow(id: "w1", kind: .session, title: "S", usedPercent: percent, resetsAt: resetsAt)
            ], credits: [])
        }
        let reset1 = now.addingTimeInterval(3_600)
        history.record(snap(51, resetsAt: reset1), at: now)
        history.record(snap(50, resetsAt: reset1), at: now.addingTimeInterval(300)) // 1-point dip, same window
        #expect(history.samples(instanceID: "codex", windowID: "w1").map(\.percent) == [51, 50])
        // Next window: resetsAt moved 5 h on, so its start (reset1) is after both old samples.
        let reset2 = reset1.addingTimeInterval(18_000)
        history.record(snap(47, resetsAt: reset2), at: reset1.addingTimeInterval(60))
        #expect(history.samples(instanceID: "codex", windowID: "w1").map(\.percent) == [47])
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
