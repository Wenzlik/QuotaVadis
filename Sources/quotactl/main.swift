import Foundation
import QuotaCore

// Tiny harness: `quotactl` prints a table, `quotactl --json` prints snapshots as JSON.
let json = CommandLine.arguments.contains("--json")
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
            let who = [s.plan, s.account].compactMap { $0 }.joined(separator: " · ")
            print("\(id.displayName)\(who.isEmpty ? "" : " (\(who))")")
            for w in s.windows {
                let reset = w.resetsAt.map { " resets \(rel.localizedString(for: $0, relativeTo: .now))" } ?? ""
                print("  " + w.title.padding(toLength: 14, withPad: " ", startingAt: 0) + String(format: "%5.1f%%", w.usedPercent) + reset)
            }
        }
    }
}
