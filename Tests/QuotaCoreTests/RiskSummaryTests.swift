import Foundation
import Testing
@testable import QuotaCore

struct RiskSummaryTests {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Prague")!
        return c
    }()
    private let locale = Locale(identifier: "en_US_POSIX")
    private let now = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01 00:00 UTC

    @Test func severityFollowsForecastThenUsageLevel() {
        let watch = UsageForecast(projectedPercent: 86, runsOutAt: nil, resetsAt: now.addingTimeInterval(86_400),
                                  ratePerHour: 1, basis: .recent, risk: .watch)
        // A forecast decides on its own, however low the current usage.
        #expect(UsageForecast.Risk(usedPercent: 26, forecast: watch) == .watch)
        // Without one, the usage level: < 50 ok, < 80 warning, else critical; 100 is a limit hit.
        #expect(UsageForecast.Risk(usedPercent: 26, forecast: nil) == .safe)
        #expect(UsageForecast.Risk(usedPercent: 60, forecast: nil) == .watch)
        #expect(UsageForecast.Risk(usedPercent: 85, forecast: nil) == .atRisk)
        #expect(UsageForecast.Risk(usedPercent: 100, forecast: nil) == .exhausted)
    }

    @Test func summaryPlacementDecodesWithBottomDefault() {
        #expect(RiskSummaryPlacement(storedValue: nil) == .bottom)
        #expect(RiskSummaryPlacement(storedValue: "") == .bottom)
        #expect(RiskSummaryPlacement(storedValue: "sideways") == .bottom)
        #expect(RiskSummaryPlacement(storedValue: "Top") == .bottom) // raw values are case-sensitive
        #expect(RiskSummaryPlacement(storedValue: "bottom") == .bottom)
        #expect(RiskSummaryPlacement(storedValue: "top") == .top)
        #expect(RiskSummaryPlacement(storedValue: "hidden") == .hidden)
        // Stored strings are a persistence contract: never rename them.
        #expect(RiskSummaryPlacement.allCases.map(\.rawValue) == ["bottom", "top", "hidden"])
        for placement in RiskSummaryPlacement.allCases {
            #expect(RiskSummaryPlacement(storedValue: placement.rawValue) == placement)
        }
    }

    @Test func rankingRiskThenUsageThenReset() {
        let soon = now.addingTimeInterval(3_600), later = now.addingTimeInterval(7_200)
        let grok = RiskItem(title: "Grok Bot", usedPercent: 53, resetsAt: later, risk: .safe)
        let auto = RiskItem(title: "Auto", usedPercent: 36, resetsAt: later, risk: .atRisk)
        #expect(auto.outranks(grok))
        #expect(!grok.outranks(auto))
        let higher = RiskItem(title: "A", usedPercent: 60, resetsAt: later, risk: .watch)
        let lower = RiskItem(title: "B", usedPercent: 40, resetsAt: soon, risk: .watch)
        #expect(higher.outranks(lower))
        let early = RiskItem(title: "C", usedPercent: 40, resetsAt: soon, risk: .watch)
        let late = RiskItem(title: "D", usedPercent: 40, resetsAt: later, risk: .watch)
        let never = RiskItem(title: "E", usedPercent: 40, resetsAt: nil, risk: .watch)
        #expect(early.outranks(late))
        #expect(late.outranks(never))
        #expect(!early.outranks(early))
    }

    @Test func summaryHeadlinesTheMostThreatenedLimit() throws {
        let reset = now.addingTimeInterval(86_400)
        let windows = [
            RiskItem(title: "Cursor · Grok Bot", usedPercent: 53, resetsAt: reset, risk: .safe),
            RiskItem(title: "Cursor · Auto", usedPercent: 36, resetsAt: reset, risk: .atRisk),
            RiskItem(title: "Codex · Weekly", usedPercent: 26, resetsAt: reset, risk: .watch),
        ]
        let summary = try #require(RiskSummary(items: windows))
        #expect(summary.top.title == "Cursor · Auto")
        #expect(summary.atRiskCount == 1)
        #expect(summary.limitCount == 3)

        let spend = RiskItem(title: "Cursor · On-demand spend", usedPercent: 104, resetsAt: reset, risk: .exhausted)
        let withSpend = try #require(RiskSummary(items: windows + [spend]))
        #expect(withSpend.top.title == "Cursor · On-demand spend")
        #expect(withSpend.atRiskCount == 2)
        #expect(withSpend.limitCount == 4)

        #expect(RiskSummary(items: []) == nil)
    }

    @Test func spendOverLimit() {
        #expect(UsageCredits(id: "od", title: "On-demand", used: 1.04, limit: 1.00).isOverLimit)
        #expect(UsageCredits(id: "od", title: "On-demand", used: 1.00, limit: 1.00).isOverLimit)
        #expect(!UsageCredits(id: "od", title: "On-demand", used: 0.50, limit: 1.00).isOverLimit)
        #expect(!UsageCredits(id: "od", title: "On-demand", used: 5, limit: nil).isOverLimit)
    }

    @Test func compactForecastLabel() {
        let reset = now.addingTimeInterval(4 * 86_400)
        let runsOut = now.addingTimeInterval(86_400 + 3_600)
        let atRisk = UsageForecast(projectedPercent: 140, runsOutAt: runsOut, resetsAt: reset, ratePerHour: 2, basis: .recent, risk: .atRisk)
        #expect(atRisk.compactLabel(now: now, calendar: cal, locale: locale)
                == "runs out \(runsOut.resetClockLabel(now: now, calendar: cal, locale: locale))")
        // The full label keeps the gap to the reset; the compact one drops it.
        #expect(atRisk.label(now: now, calendar: cal, locale: locale).hasSuffix("before reset"))
        #expect(!atRisk.compactLabel(now: now, calendar: cal, locale: locale).contains("before reset"))

        let fits = UsageForecast(projectedPercent: 82.4, runsOutAt: nil, resetsAt: reset, ratePerHour: 1, basis: .recent, risk: .safe)
        #expect(fits.compactLabel(now: now, calendar: cal, locale: locale) == "fits, ends at ~82%")
        let done = UsageForecast(projectedPercent: 100, runsOutAt: nil, resetsAt: reset, ratePerHour: 0, basis: .recent, risk: .exhausted)
        #expect(done.compactLabel(now: now, calendar: cal, locale: locale) == "limit reached")
    }

    @Test func compactRemaining() {
        #expect(now.addingTimeInterval(4 * 86_400 + 21 * 3_600).compactRemainingLabel(now: now) == "4d")
        #expect(now.addingTimeInterval(2 * 3_600 + 6 * 60).compactRemainingLabel(now: now) == "2h")
        #expect(now.addingTimeInterval(35 * 60).compactRemainingLabel(now: now) == "35m")
        #expect(now.addingTimeInterval(30).compactRemainingLabel(now: now) == "1m")
        #expect(now.addingTimeInterval(-1).compactRemainingLabel(now: now) == "passed")
    }

    @Test func primaryWindowChoice() {
        let reset = now.addingTimeInterval(86_400)
        let cursor = UsageSnapshot(provider: .cursor, account: nil, plan: nil, windows: [
            UsageWindow(id: "plan", kind: .monthly, title: "Included total", usedPercent: 32, resetsAt: reset),
            UsageWindow(id: "auto", kind: .model, title: "Auto", usedPercent: 39, resetsAt: reset),
            UsageWindow(id: "api", kind: .model, title: "Other models", usedPercent: 5, resetsAt: reset, prominent: false),
            UsageWindow(id: "grok-bot", kind: .weekly, title: "Grok Bot", usedPercent: 53, resetsAt: reset),
        ], deviceName: "test")

        let standard = cursor.overviewLayout()
        #expect(standard.main?.id == "plan")
        #expect(standard.cards.map(\.id) == ["auto", "grok-bot"])

        let grok = cursor.overviewLayout(primaryWindowID: "grok-bot")
        #expect(grok.main?.id == "grok-bot")
        #expect(grok.cards.map(\.id) == ["plan", "auto"])

        // A sub-window the user picked becomes the big bar even though the overview hides it.
        let api = cursor.overviewLayout(primaryWindowID: "api")
        #expect(api.main?.id == "api")
        #expect(api.cards.map(\.id) == ["plan", "auto", "grok-bot"])

        // A pick that is no longer reported falls back to the default.
        #expect(cursor.overviewLayout(primaryWindowID: "gone").main?.id == "plan")

        let claude = UsageSnapshot(provider: .claude, account: nil, plan: nil, windows: [
            UsageWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: 2, resetsAt: reset),
            UsageWindow(id: "session", kind: .session, title: "Session", usedPercent: 16, resetsAt: reset),
        ], deviceName: "test")
        #expect(claude.overviewLayout().main?.id == "session")
        #expect(claude.overviewLayout().cards.map(\.id) == ["weekly"])
    }

    @Test func atRiskSubWindowBecomesACard() {
        let reset = now.addingTimeInterval(86_400)
        // Auto just under the total: the provider marks it minor, so the overview alone hides it.
        let cursor = UsageSnapshot(provider: .cursor, account: nil, plan: nil, windows: [
            UsageWindow(id: "plan", kind: .monthly, title: "Included total", usedPercent: 32, resetsAt: reset),
            UsageWindow(id: "auto", kind: .model, title: "Auto", usedPercent: 30, resetsAt: reset, prominent: false),
            UsageWindow(id: "grok-bot", kind: .weekly, title: "Grok Bot", usedPercent: 53, resetsAt: reset),
        ], deviceName: "test")
        #expect(cursor.overviewLayout().cards.map(\.id) == ["grok-bot"])
        let promoted = cursor.overviewLayout { $0.id == "auto" }
        #expect(promoted.main?.id == "plan")
        #expect(promoted.cards.map(\.id) == ["grok-bot", "auto"])
        // Promoting an already shown window does not duplicate it.
        #expect(cursor.overviewLayout { _ in true }.cards.map(\.id) == ["grok-bot", "auto"])
    }
}
