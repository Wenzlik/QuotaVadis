import Foundation

/// Runs the three cost sources concurrently. Local scans are cheap after the first pass (per-file cache);
/// Cursor is a paged network call, so callers should throttle this to every 15 minutes or a manual refresh.
public actor CostService {
    public init() {}

    public func refresh(enabled: Set<ProviderID>, fastModeAt2x: Bool = false) async -> [ProviderID: CostReport] {
        await withTaskGroup(of: (ProviderID, CostReport?).self) { group in
            if enabled.contains(.claude) { group.addTask { (.claude, await ClaudeCostScanner().report()) } }
            if enabled.contains(.codex) { group.addTask { (.codex, await CodexCostScanner().report(fastModeAt2x: fastModeAt2x)) } }
            if enabled.contains(.cursor) { group.addTask { (.cursor, try? await CursorCostFetcher().report()) } }
            var out: [ProviderID: CostReport] = [:]
            for await (id, report) in group { if let report { out[id] = report } }
            return out
        }
    }
}
