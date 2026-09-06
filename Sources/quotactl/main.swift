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
if CommandLine.arguments.contains("--raw") {
    for fetcher in UsageService.allFetchers where fetcher.isAvailable() {
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
    let snapshots = ProviderID.allCases.compactMap { states[$0]?.snapshot }
    print(String(decoding: try encoder.encode(snapshots), as: UTF8.self))
} else {
    let rel = RelativeDateTimeFormatter()
    rel.unitsStyle = .abbreviated
    for id in ProviderID.allCases {
        guard let state = states[id] else { continue }
        switch state {
        case .unavailable:
            print("\(id.displayName): not installed")
        case .failed(let error, _):
            print("\(id.displayName): ERROR \(error.localizedDescription)")
        case .fresh(let s):
            let who = [s.plan, s.seat, s.account].compactMap { $0 }.joined(separator: " · ")
            print("\(id.displayName)\(who.isEmpty ? "" : " (\(who))")")
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
