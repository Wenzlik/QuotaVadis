import Foundation

/// Per-file scan results keyed by path, invalidated when size or mtime changes. Session logs are append-only,
/// so unchanged files never get re-read; changed files are re-read whole (simple and correct).
struct LogScanCache<Entry: Codable & Sendable>: Codable, Sendable {
    struct Stamp: Codable, Sendable, Hashable { var size: Int; var mtime: TimeInterval }
    var files: [String: (Stamp, Entry)] = [:]

    private struct Row: Codable { var stamp: Stamp; var entry: Entry }
    init() {}
    init(from decoder: Decoder) throws {
        let rows = try decoder.singleValueContainer().decode([String: Row].self)
        files = rows.mapValues { ($0.stamp, $0.entry) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(files.mapValues { Row(stamp: $0.0, entry: $0.1) })
    }

    static func stamp(of url: URL) -> Stamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return Stamp(size: (attrs[.size] as? Int) ?? 0, mtime: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
    }

    static func load(_ url: URL) -> Self {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }

    func save(_ url: URL) {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }
}

enum LogFiles {
    /// All `.jsonl` files under `root` modified within the last `days` days.
    static func recentJSONL(under root: URL, days: Int) -> [URL] {
        let cutoff = Date.now.addingTimeInterval(-Double(days + 1) * 86_400)
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return [] }
        var out: [URL] = []
        for case let url as URL in e where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let modified = values?.contentModificationDate, modified > cutoff else { continue }
            out.append(url)
        }
        return out
    }

    /// Streams a file line by line without loading it whole; 100 MB session logs exist.
    static func forEachLine(of url: URL, _ body: (Substring) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var carry = Data()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            carry.append(chunk)
            while let nl = carry.firstIndex(of: 0x0A) {
                let line = carry.subdata(in: carry.startIndex..<nl)
                carry.removeSubrange(carry.startIndex...nl)
                if let s = String(data: line, encoding: .utf8) { body(Substring(s)) }
            }
        }
        if !carry.isEmpty, let s = String(data: carry, encoding: .utf8) { body(Substring(s)) }
    }
}

/// One usage row extracted from a log; the cached unit per file.
struct UsageRow: Codable, Sendable, Hashable {
    var timestamp: Date
    var model: String
    var project: String?
    var tokens: TokenCounts
    /// Provider-reported cost when the log carries one (Cursor); nil means "price it at list rates".
    var reportedCostUSD: Double?
}

extension CostAccumulator {
    mutating func add(_ rows: [UsageRow], pricing: Pricing, since: Date) async {
        for row in rows where row.timestamp >= since {
            let cost: Double
            if let reported = row.reportedCostUSD { cost = reported } else { cost = await pricing.cost(model: row.model, tokens: row.tokens) ?? 0 }
            add(date: row.timestamp, model: row.model, project: row.project, tokens: row.tokens, costUSD: cost)
        }
    }
}
