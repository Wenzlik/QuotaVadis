import Foundation
import QuotaCore

// Tiny harness: `quotactl` prints a table, `quotactl --json` prints snapshots as JSON.
let json = CommandLine.arguments.contains("--json")
if CommandLine.arguments.contains("--profile") {
    for (name, data) in await DebugProbes.profiles() {
        print("=== \(name)")
        if let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: pretty, as: UTF8.self))
        } else { print(String(decoding: data, as: UTF8.self)) }
    }
    exit(0)
}
if CommandLine.arguments.contains("--cost") {
    let started = Date()
    let reports = await CostService().refresh(enabled: Set(ProviderID.allCases), fastModeAt2x: CommandLine.arguments.contains("--fast-2x"))
    for id in ProviderID.allCases {
        guard let r = reports[id] else { print("\(id.displayName): no cost data"); continue }
        let today = r.today
        print("\(id.displayName): today $\(String(format: "%.2f", today?.costUSD ?? 0)) · \(today?.tokens.total ?? 0) tok · 30d $\(String(format: "%.2f", r.totalCostUSD)) · \(r.totalTokens) tok")
        for m in r.byModel.prefix(4) { print("   \(m.id.padding(toLength: 28, withPad: " ", startingAt: 0)) $\(String(format: "%8.2f", m.costUSD))  \(m.tokens.total) tok  \(m.requests) req") }
        for pr in r.byProject.prefix(3) { print("   proj \(pr.id)  $\(String(format: "%.2f", pr.costUSD))") }
        print("   last 7 days: " + r.days.suffix(7).map { String(format: "%.0f", $0.costUSD) }.joined(separator: " "))
    }
    print(String(format: "(%.1fs)", Date().timeIntervalSince(started)))
    exit(0)
}
if CommandLine.arguments.contains("--codex-cli") {
    let result = try await CodexCLI.readRateLimits()
    print(result.map { String(decoding: $0, as: UTF8.self) } ?? "codex CLI not found")
    exit(0)
}
if CommandLine.arguments.contains("--keychain") {
    for e in ClaudeCredentials.keychainEntries() {
        print("\(e.service)  created \(e.created?.formatted() ?? "?")  modified \(e.modified?.formatted() ?? "?")")
    }
    exit(0)
}
if CommandLine.arguments.contains("--raw") {
    for fetcher in UsageService.defaultFetchers() where fetcher.isAvailable() {
        print("=== \(fetcher.provider.displayName)")
        do {
            let data = try await fetcher.fetchRaw()
            let obj = try JSONSerialization.jsonObject(with: data)
            let pretty = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: pretty, as: UTF8.self))
        } catch { print("ERROR \(error)") }
    }
    exit(0)
}
let service = UsageService()
let states = await service.refresh()

if json {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let snapshots = states.keys.sorted().compactMap { states[$0]?.snapshot }
    print(String(decoding: try encoder.encode(snapshots), as: UTF8.self))
} else {
    let rel = RelativeDateTimeFormatter()
    rel.unitsStyle = .abbreviated
    for id in states.keys.sorted() {
        guard let state = states[id] else { continue }
        let name = ProviderID(rawValue: id)?.displayName ?? id
        switch state {
        case .unavailable:
            print("\(name): not installed")
        case .failed(let error, _):
            print("\(name): ERROR \(error.localizedDescription)")
        case .fresh(let s):
            let who = [s.organization, s.plan, s.seat, s.account].compactMap { $0 }.joined(separator: " · ")
            print("\(s.provider.displayName)\(who.isEmpty ? "" : " (\(who))")")
            for w in s.windows {
                let reset = w.resetsAt.map { " resets \(rel.localizedString(for: $0, relativeTo: .now))" } ?? ""
                print("  " + w.title.padding(toLength: 14, withPad: " ", startingAt: 0) + String(format: "%5.1f%%", w.usedPercent) + reset)
            }
            if let resets = s.resetCreditsAvailable { print("  resets available: \(resets)") }
            for c in s.credits {
                let limit = c.limit.map { String(format: " / %.2f", $0) } ?? ""
                print("  $ " + c.title.padding(toLength: 12, withPad: " ", startingAt: 0) + String(format: "%.2f", c.used) + limit + " " + c.currency)
            }
        }
    }
}
