import Foundation
import Testing
@testable import QuotaCore

private func tempFile(_ lines: [String]) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
    try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    return url
}

@Test func claudeScanDedupesStreamingUpdates() throws {
    let usage = #"{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":300,"output_tokens":50}"#
    let line = #"{"type":"assistant","timestamp":"2026-09-05T10:00:00.000Z","cwd":"/p","requestId":"req_1","message":{"id":"msg_1","model":"claude-opus-5","usage":\#(usage)}}"#
    let other = #"{"type":"user","timestamp":"2026-09-05T10:00:01.000Z","message":{"role":"user","content":"hi"}}"#
    let url = try tempFile([line, other, line])
    let rows = ClaudeCostScanner.scan(url)
    #expect(rows.count == 1)
    #expect(rows[0].tokens == TokenCounts(input: 2, output: 50, cacheRead: 300, cacheWrite: 100))
    #expect(rows[0].project == "/p")
    // opus-5: 2*5 + 50*25 + 300*0.5 + 100*6.25 per million
    let price = Pricing.bundled["claude-opus-5"]!
    #expect(abs(price.cost(rows[0].tokens) - (10 + 1250 + 150 + 625) / 1_000_000) < 1e-12)
}

@Test func codexScanUsesRunningTotalDeltas() throws {
    func count(_ input: Int, _ cached: Int, _ output: Int) -> String {
        #"{"timestamp":"2026-09-05T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_input_tokens":0,"output_tokens":\#(output),"total_tokens":0}}}}"#
    }
    let ctx = #"{"timestamp":"2026-09-05T09:59:00.000Z","type":"turn_context","payload":{"model":"gpt-6-astra","cwd":"/w"}}"#
    let url = try tempFile([ctx, count(1000, 800, 10), count(1000, 800, 10), count(3000, 2000, 25), count(100, 0, 1)])
    let rows = CodexCostScanner.scan(url)
    #expect(rows.count == 3)
    #expect(rows[0].tokens == TokenCounts(input: 200, output: 10, cacheRead: 800, cacheWrite: 0))
    #expect(rows[1].tokens == TokenCounts(input: 800, output: 15, cacheRead: 1200, cacheWrite: 0))
    #expect(rows[2].tokens == TokenCounts(input: 100, output: 1, cacheRead: 0, cacheWrite: 0))   // after a reset
    #expect(rows.allSatisfy { $0.model == "gpt-6-astra" && $0.project == "/w" })
}

@Test func longContextTierAndFastMode() throws {
    let astra = Pricing.bundled["gpt-6-astra"]!
    let small = TokenCounts(input: 1000, output: 100)
    let big = TokenCounts(input: 300_000, output: 100)
    #expect(abs(astra.cost(small) - (1000 * 10 + 100 * 50) / 1e6) < 1e-12)
    #expect(abs(astra.cost(big) - (300_000 * 20 + 100 * 75) / 1e6) < 1e-12)

    let settings = #"{"timestamp":"2026-09-05T09:58:00.000Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":"{'model': 'gpt-6-astra', 'service_tier': 'priority'}"}}"#
    let count = #"{"timestamp":"2026-09-05T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":1}}}}"#
    let rows = CodexCostScanner.scan(try tempFile([settings, count]))
    #expect(rows.count == 1)
    #expect(rows[0].priceMultiplier == 2)
    #expect(rows[0].model == "gpt-6-astra")
}

@Test func pricingPrefixMatch() async {
    let p = Pricing.shared
    #expect(await p.price(for: "claude-opus-5-20260101") != nil)
    #expect(await p.price(for: "totally-unknown") == nil)
}

@Test func bundledPricesCoverOpus55AndGrok47() async {
    let p = Pricing()   // bundled table only, no live catalog
    let opus55 = await p.price(for: "claude-opus-5-5")
    #expect(opus55 == ModelPrice(input: 4, output: 20, cacheRead: 0.2, cacheWrite: 5))
    #expect(opus55 != Pricing.bundled["claude-opus-5"])
    #expect(await p.price(for: "claude-opus-5-5-20260901") == opus55)
    let grok = await p.price(for: "grok-4.7-high")
    #expect(grok?.input == 2 && grok?.output == 6 && grok?.cacheRead == 0.5)
    #expect(grok == Pricing.bundled["grok-4.7"])
}

@Test func reportFillsMissingDays() {
    var acc = CostAccumulator()
    let now = Date(timeIntervalSince1970: 1_788_000_000)
    acc.add(date: now, model: "m", project: nil, tokens: TokenCounts(input: 1), costUSD: 2)
    let r = acc.report(provider: .claude, windowDays: 7, source: "", now: now)
    #expect(r.days.count == 7)
    #expect(r.days.last?.costUSD == 2)
    #expect(r.days.dropLast().allSatisfy { $0.costUSD == 0 })
    #expect(r.topModel?.id == "m")
}
