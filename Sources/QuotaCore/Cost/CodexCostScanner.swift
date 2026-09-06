import Foundation

/// Sums Codex CLI usage from `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`.
/// `token_count` events carry a running `total_token_usage`; consecutive deltas give per-request usage
/// and survive repeated events. The active model comes from the most recent `turn_context`.
public struct CodexCostScanner: Sendable {
    public static let windowDays = 30
    public init() {}

    static var sessionsRoot: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return home.appendingPathComponent("sessions")
    }

    private static let cacheURL = Pricing.cacheURL.deletingLastPathComponent().appendingPathComponent("codex-scan.json")

    /// `fastModeAt2x`: price priority-processing requests at OpenAI's 2x rate instead of list price.
    public func report(now: Date = .now, fastModeAt2x: Bool = false) async -> CostReport? {
        let root = Self.sessionsRoot
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        var cache = LogScanCache<[UsageRow]>.load(Self.cacheURL)
        var rows: [UsageRow] = []
        for url in LogFiles.recentJSONL(under: root, days: Self.windowDays) {
            guard let stamp = LogScanCache<[UsageRow]>.stamp(of: url) else { continue }
            if let (cached, entry) = cache.files[url.path], cached == stamp {
                rows += entry
            } else {
                let scanned = Self.scan(url)
                cache.files[url.path] = (stamp, scanned)
                rows += scanned
            }
        }
        cache.files = cache.files.filter { FileManager.default.fileExists(atPath: $0.key) }
        cache.save(Self.cacheURL)

        let pricing = Pricing.shared
        await pricing.prepare()
        var acc = CostAccumulator()
        let since = Calendar.current.startOfDay(for: now).addingTimeInterval(-Double(Self.windowDays - 1) * 86_400)
        await acc.add(rows, pricing: pricing, since: since, applyMultipliers: fastModeAt2x)
        return acc.report(provider: .codex, windowDays: Self.windowDays,
                          source: fastModeAt2x
                              ? "Estimated from local Codex session logs at API list prices, Fast mode at 2x; not a subscription bill."
                              : "Estimated from local Codex session logs at API list prices; not a subscription bill.")
    }

    static func scan(_ url: URL) -> [UsageRow] {
        var rows: [UsageRow] = []
        var model = "unknown"
        var project: String?
        var previous = TokenCounts()
        var priority = false
        LogFiles.forEachLine(of: url) { line in
            guard line.contains("turn_context") || line.contains("token_count") || line.contains("session_meta") || line.contains("thread_settings_applied"),
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any] else { return }
            switch obj["type"] as? String {
            case "turn_context":
                if let m = payload["model"] as? String, !m.isEmpty { model = m }
                if let cwd = payload["cwd"] as? String { project = cwd }
            case "session_meta":
                if let cwd = payload["cwd"] as? String { project = cwd }
            case "event_msg" where payload["type"] as? String == "thread_settings_applied":
                // Fast mode = OpenAI priority processing, billed at 2x. Settings arrive as JSON or a dict.
                if let settings = payload["thread_settings"] as? [String: Any] {
                    priority = settings["service_tier"] as? String == "priority"
                    if let m = settings["model"] as? String, !m.isEmpty { model = m }
                } else if let text = payload["thread_settings"] as? String {
                    priority = text.contains("'service_tier': 'priority'") || text.contains("\"service_tier\":\"priority\"")
                    if let range = text.range(of: #"'model': '([^']+)'"#, options: .regularExpression) {
                        let m = text[range].split(separator: "'").last.map(String.init) ?? ""
                        if !m.isEmpty { model = m }
                    }
                }
            case "event_msg":
                guard payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let total = info["total_token_usage"] as? [String: Any],
                      let ts = ISO8601DateFormatter.parseAny(obj["timestamp"] as? String) else { return }
                let input = total["input_tokens"] as? Int ?? 0
                let cached = total["cached_input_tokens"] as? Int ?? 0
                let current = TokenCounts(input: max(0, input - cached),
                                          output: total["output_tokens"] as? Int ?? 0,
                                          cacheRead: cached,
                                          cacheWrite: total["cache_write_input_tokens"] as? Int ?? 0)
                var delta = TokenCounts(input: current.input - previous.input, output: current.output - previous.output,
                                        cacheRead: current.cacheRead - previous.cacheRead, cacheWrite: current.cacheWrite - previous.cacheWrite)
                // Totals restart when a session is compacted or resumed: a negative delta means the new total is fresh usage.
                if delta.input < 0 || delta.output < 0 || delta.cacheRead < 0 || delta.cacheWrite < 0 { delta = current }
                previous = current
                guard delta.total > 0 else { return }
                rows.append(UsageRow(timestamp: ts, model: model, project: project, tokens: delta, priceMultiplier: priority ? 2 : 1))
            default: break
            }
        }
        return rows
    }
}
