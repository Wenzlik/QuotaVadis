import Foundation

/// Sums Claude Code's per-request usage from `~/.claude/projects/**/*.jsonl`.
/// Each assistant line carries `message.usage`; the same message can appear on several lines
/// (streaming updates), so rows are deduplicated by message id + request id, keeping the last.
public struct ClaudeCostScanner: Sendable {
    public static let windowDays = 30
    public init() {}

    static var projectsRoot: URL {
        let root = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return root.appendingPathComponent("projects")
    }

    private static let cacheURL = Pricing.cacheURL.deletingLastPathComponent().appendingPathComponent("claude-scan.json")

    public func report(now: Date = .now) async -> CostReport? {
        let root = Self.projectsRoot
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
        await acc.add(rows, pricing: pricing, since: since)
        return acc.report(provider: .claude, windowDays: Self.windowDays,
                          source: "Estimated from local Claude Code logs at API list prices; subscription usage is not billed per token.")
    }

    /// Parses one session file. Kept static and pure for tests.
    static func scan(_ url: URL) -> [UsageRow] {
        var byKey: [String: UsageRow] = [:]
        var order: [String] = []
        LogFiles.forEachLine(of: url) { line in
            // Cheap prefilter before JSON parsing: only assistant lines carry usage.
            guard line.contains("\"usage\""), line.contains("\"assistant\""),
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let model = message["model"] as? String, !model.isEmpty, model != "<synthetic>",
                  let ts = ISO8601DateFormatter.parseAny(obj["timestamp"] as? String) else { return }
            let tokens = TokenCounts(input: usage["input_tokens"] as? Int ?? 0,
                                     output: usage["output_tokens"] as? Int ?? 0,
                                     cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
                                     cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0)
            let key = "\(message["id"] as? String ?? UUID().uuidString)/\(obj["requestId"] as? String ?? "")"
            if byKey[key] == nil { order.append(key) }
            byKey[key] = UsageRow(timestamp: ts, model: model, project: projectName(obj["cwd"] as? String), tokens: tokens)
        }
        return order.compactMap { byKey[$0] }
    }

    static func projectName(_ cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return cwd
    }
}
