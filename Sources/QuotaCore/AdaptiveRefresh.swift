import Foundation

/// Picks the next refresh delay from how recently the user looked and whether the tools are busy.
/// Pure: no clock, no ProcessInfo; callers gather the signals. Same table CodexBar documents.
public enum AdaptiveRefreshPolicy {
    public struct Input: Sendable {
        public var now: Date
        public var lastPanelOpen: Date?
        public var lastCodingActivity: Date?
        public var lowPowerOrHot: Bool
        public init(now: Date = .now, lastPanelOpen: Date? = nil, lastCodingActivity: Date? = nil, lowPowerOrHot: Bool = false) {
            self.now = now; self.lastPanelOpen = lastPanelOpen; self.lastCodingActivity = lastCodingActivity; self.lowPowerOrHot = lowPowerOrHot
        }
    }

    public enum Reason: String, Sendable { case constrained, recentInteraction, warm, codingActivity, idle, longIdle }

    public static func next(_ input: Input) -> (delay: TimeInterval, reason: Reason) {
        if input.lowPowerOrHot { return (30 * 60, .constrained) }
        let sinceOpen = input.lastPanelOpen.map { input.now.timeIntervalSince($0) }
        if let sinceOpen, sinceOpen <= 5 * 60 { return (2 * 60, .recentInteraction) }
        if let sinceOpen, sinceOpen <= 60 * 60 { return (5 * 60, .warm) }
        if let activity = input.lastCodingActivity, input.now.timeIntervalSince(activity) < 5 * 60 { return (5 * 60, .codingActivity) }
        if let sinceOpen, sinceOpen <= 4 * 60 * 60 { return (15 * 60, .idle) }
        return (30 * 60, .longIdle)
    }
}

/// Cheap "is anyone coding right now?" signal: newest modification among the tools' session stores.
/// Directory mtimes only, no file scans, so it is safe to call every tick.
public enum ActivityProbe {
    public static func lastCodingActivity(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> Date? {
        var candidates: [URL] = []
        let claude = home.appendingPathComponent(".claude/projects")
        if let dirs = try? FileManager.default.contentsOfDirectory(at: claude, includingPropertiesForKeys: [.contentModificationDateKey]) {
            candidates += dirs
        }
        let sessions = home.appendingPathComponent(".codex/sessions")
        let c = Calendar.current, now = Date()
        for day in [now, c.date(byAdding: .day, value: -1, to: now)!] {
            let p = c.dateComponents([.year, .month, .day], from: day)
            candidates.append(sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", p.year!, p.month!, p.day!)))
        }
        candidates.append(home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb"))
        candidates.append(home.appendingPathComponent(".gemini/antigravity/conversations"))
        return candidates.compactMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }.max()
    }
}
