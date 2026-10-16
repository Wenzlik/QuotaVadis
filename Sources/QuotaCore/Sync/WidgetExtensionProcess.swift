import Foundation

/// What the widget extension process reports about itself when it starts, kept in the App Group defaults.
public struct WidgetExtensionReport: Equatable, Sendable {
    public var version: String
    public var pid: Int32
    public var startedAt: Date

    public init(version: String, pid: Int32, startedAt: Date) {
        self.version = version
        self.pid = pid
        self.startedAt = startedAt
    }
}

extension SharedStore {
    static let extensionVersionKey = "widgetExtensionVersion"
    static let extensionPIDKey = "widgetExtensionPID"
    static let extensionStartedAtKey = "widgetExtensionStartedAt"

    /// The last widget extension process that started, as it reported itself; nil before any has.
    public static var widgetExtensionReport: WidgetExtensionReport? {
        let defaults = sharedDefaults
        guard let version = defaults.string(forKey: extensionVersionKey),
              let startedAt = defaults.object(forKey: extensionStartedAtKey) as? Date else { return nil }
        return WidgetExtensionReport(version: version, pid: Int32(defaults.integer(forKey: extensionPIDKey)), startedAt: startedAt)
    }

    private static let launchRecorded: Void = {
        let defaults = sharedDefaults
        defaults.set(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "", forKey: extensionVersionKey)
        defaults.set(Int(ProcessInfo.processInfo.processIdentifier), forKey: extensionPIDKey)
        defaults.set(Date.now, forKey: extensionStartedAtKey)
    }()

    /// Called by the widget extension at start; records its `CFBundleVersion`, PID and start once per process.
    public static func recordWidgetExtensionLaunch() { _ = launchRecorded }
}

#if os(macOS)
/// Which running widget extension processes are ours and still run an older binary.
///
/// A Sparkle update replaces the bundle on disk but leaves the old `QuotaWidgets-Mac` process running. chronod keeps
/// using it and drops what it draws ("Bundle version did not match", timelineReloadFailed), so the desktop widgets
/// go black until that process exits. The app finds it here and ends it; the listing and `kill` stay in the app.
public enum WidgetExtensionProcess {
    public static let executableName = "QuotaWidgets-Mac"
    /// Tail of the extension's executable path, wherever the bundle it was started from now lives.
    public static let executableSuffix = "/QuotaWidgets-Mac.appex/Contents/MacOS/QuotaWidgets-Mac"

    /// One running process as `proc_pidinfo`/`proc_pidpath` see it.
    public struct Candidate: Equatable, Sendable {
        public var pid: Int32
        public var uid: UInt32
        /// Executable path; nil when the kernel no longer has one (the old binary was deleted by the update).
        public var path: String?
        /// Process name (`pbi_name`, or `pbi_comm` when that is empty).
        public var name: String
        public var startedAt: Date

        public init(pid: Int32, uid: UInt32, path: String?, name: String, startedAt: Date) {
            self.pid = pid
            self.uid = uid
            self.path = path
            self.name = name
            self.startedAt = startedAt
        }
    }

    /// Our own extension processes: same user, and an executable inside a `QuotaWidgets-Mac.appex`. Only when the
    /// kernel has no path left for it does the exact process name stand in for the path.
    public static func ours(_ candidates: [Candidate], uid: UInt32) -> [Candidate] {
        candidates.filter { candidate in
            guard candidate.uid == uid else { return false }
            return candidate.path.map { $0.hasSuffix(executableSuffix) } ?? (candidate.name == executableName)
        }
    }

    /// The version `report` says `process` runs; nil when the report belongs to another process.
    static func reportedVersion(of process: Candidate, report: WidgetExtensionReport?) -> String? {
        guard let report, report.pid == process.pid, abs(report.startedAt.timeIntervalSince(process.startedAt)) < 10 else { return nil }
        return report.version
    }

    /// PIDs to end so WidgetKit starts the extension from the current binary. All of ours on the first launch of a new
    /// app version (or when `force`d from Settings); otherwise those started before the binary on disk last changed
    /// or that reported another version than the app's.
    public static func toRestart(_ candidates: [Candidate], uid: UInt32, appVersion: String, lastSeenAppVersion: String?,
                                 binaryChangedAt: Date?, report: WidgetExtensionReport?, force: Bool = false) -> [Int32] {
        let own = ours(candidates, uid: uid)
        if force || appVersion != lastSeenAppVersion { return own.map(\.pid) }
        return own.filter { process in
            if let binaryChangedAt, process.startedAt < binaryChangedAt { return true }
            if let version = reportedVersion(of: process, report: report), version != appVersion { return true }
            return false
        }.map(\.pid)
    }

    /// The older version a running extension of ours reported, for Settings; nil when it matches or none is running.
    public static func staleVersion(_ candidates: [Candidate], uid: UInt32, appVersion: String, report: WidgetExtensionReport?) -> String? {
        ours(candidates, uid: uid).lazy.compactMap { reportedVersion(of: $0, report: report) }.first { $0 != appVersion }
    }
}
#endif
