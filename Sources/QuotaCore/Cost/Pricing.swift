import Foundation

/// USD per million tokens for one model.
public struct ModelPrice: Codable, Sendable, Hashable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    /// Higher rates once a request's context exceeds `threshold` tokens (e.g. GPT-6 Astra above 272k).
    public var longContextThreshold: Int?
    public var longContext: Rates?

    public struct Rates: Codable, Sendable, Hashable {
        public var input: Double, output: Double, cacheRead: Double, cacheWrite: Double
    }

    public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double, longContextThreshold: Int? = nil, longContext: Rates? = nil) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
        self.longContextThreshold = longContextThreshold; self.longContext = longContext
    }

    /// Context = everything sent in: fresh input plus cache reads and writes.
    public func cost(_ t: TokenCounts) -> Double {
        let context = t.input + t.cacheRead + t.cacheWrite
        if let threshold = longContextThreshold, let long = longContext, context > threshold {
            return (Double(t.input) * long.input + Double(t.output) * long.output + Double(t.cacheRead) * long.cacheRead + Double(t.cacheWrite) * long.cacheWrite) / 1_000_000
        }
        return (Double(t.input) * input + Double(t.output) * output + Double(t.cacheRead) * cacheRead + Double(t.cacheWrite) * cacheWrite) / 1_000_000
    }
}

/// Model list prices from models.dev, cached for a day, with a bundled fallback so cost still works offline.
public actor Pricing {
    public static let shared = Pricing()

    private var table: [String: ModelPrice] = Pricing.bundled
    private var loadedAt: Date?

    static let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("QuotaVadis")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("models-dev.json")
    }()

    /// Refreshes from disk cache or network when older than a day. Never throws; falls back to what it has.
    public func prepare() async {
        if let loadedAt, Date.now.timeIntervalSince(loadedAt) < 86_400 { return }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: Self.cacheURL.path),
           let modified = attrs[.modificationDate] as? Date, Date.now.timeIntervalSince(modified) < 86_400,
           let data = try? Data(contentsOf: Self.cacheURL), let parsed = Self.parse(data) {
            table.merge(parsed) { _, new in new }; loadedAt = .now; return
        }
        if let data = try? await HTTP.get(URL(string: "https://models.dev/api.json")!, headers: ["User-Agent": "QuotaVadis"]),
           let parsed = Self.parse(data) {
            table.merge(parsed) { _, new in new }; loadedAt = .now
            try? data.write(to: Self.cacheURL, options: .atomic)
        } else if let data = try? Data(contentsOf: Self.cacheURL), let parsed = Self.parse(data) {
            table.merge(parsed) { _, new in new }; loadedAt = .now
        }
    }

    /// Exact id first, then the longest known id the model name starts with (dated variants, "-latest").
    public func price(for model: String) -> ModelPrice? {
        let key = model.lowercased()
        if let exact = table[key] { return exact }
        let candidates = table.keys.filter { key.hasPrefix($0) || $0.hasPrefix(key) }
        return candidates.max { $0.count < $1.count }.flatMap { table[$0] }
    }

    public func cost(model: String, tokens: TokenCounts) -> Double? { price(for: model)?.cost(tokens) }

    static func parse(_ data: Data) -> [String: ModelPrice]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var out: [String: ModelPrice] = [:]
        for provider in ["anthropic", "openai", "xai", "google"] {
            guard let models = (root[provider] as? [String: Any])?["models"] as? [String: Any] else { continue }
            for (id, value) in models {
                guard let cost = (value as? [String: Any])?["cost"] as? [String: Any],
                      let input = cost["input"] as? Double, let output = cost["output"] as? Double else { continue }
                var price = ModelPrice(input: input, output: output,
                                       cacheRead: cost["cache_read"] as? Double ?? input,
                                       cacheWrite: cost["cache_write"] as? Double ?? input)
                // models.dev: `tiers: [{input, output, cache_read, cache_write, tier: {type: "context", size}}]`
                if let tiers = cost["tiers"] as? [[String: Any]],
                   let tier = tiers.first(where: { ($0["tier"] as? [String: Any])?["type"] as? String == "context" }),
                   let size = (tier["tier"] as? [String: Any])?["size"] as? Int,
                   let tInput = tier["input"] as? Double, let tOutput = tier["output"] as? Double {
                    price.longContextThreshold = size
                    price.longContext = .init(input: tInput, output: tOutput,
                                              cacheRead: tier["cache_read"] as? Double ?? tInput,
                                              cacheWrite: tier["cache_write"] as? Double ?? tInput)
                }
                out[id.lowercased()] = price
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Snapshot of models.dev on 2026-09-22; only used until the live catalog loads.
    static let bundled: [String: ModelPrice] = [
        "claude-fable-5-1": .init(input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5),
        "claude-fable-5": .init(input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5),
        "claude-opus-5-5": .init(input: 4, output: 20, cacheRead: 0.2, cacheWrite: 5),
        "claude-opus-5": .init(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-5": .init(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-sonnet-5": .init(input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5),
        "claude-sonnet-4-6": .init(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        "claude-haiku-4-5": .init(input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25),
        "gpt-6-astra": .init(input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5, longContextThreshold: 272_000,
                             longContext: .init(input: 20, output: 75, cacheRead: 2, cacheWrite: 25)),
        "gpt-5.3-codex": .init(input: 1.75, output: 14, cacheRead: 0.175, cacheWrite: 1.75),
        "gpt-5.3-codex-spark": .init(input: 1.75, output: 14, cacheRead: 0.175, cacheWrite: 1.75),
        // models.dev lists no cache_write for xAI, so it falls back to input like `parse` does.
        "grok-4.7": .init(input: 2, output: 6, cacheRead: 0.5, cacheWrite: 2, longContextThreshold: 200_000,
                          longContext: .init(input: 4, output: 12, cacheRead: 1, cacheWrite: 4)),
    ]
}
