import Foundation

/// What the widget extension process reports about itself when it starts, kept in the App Group defaults.
public struct WidgetExtensionReport: Equatable, Sendable {
    public var version: String
    public var pid: Int32
    public var startedAt: Date
    /// The executable the process was started from; nil from builds that did not report it.
    public var executable: String?

    public init(version: String, pid: Int32, startedAt: Date, executable: String? = nil) {
        self.version = version
        self.pid = pid
        self.startedAt = startedAt
        self.executable = executable
    }
}

extension SharedStore {
    static let extensionVersionKey = "widgetExtensionVersion"
    static let extensionPIDKey = "widgetExtensionPID"
    static let extensionStartedAtKey = "widgetExtensionStartedAt"
    static let extensionExecutableKey = "widgetExtensionExecutable"

    /// The last widget extension process that started, as it reported itself; nil before any has.
    public static var widgetExtensionReport: WidgetExtensionReport? {
        let defaults = sharedDefaults
        guard let version = defaults.string(forKey: extensionVersionKey),
              let startedAt = defaults.object(forKey: extensionStartedAtKey) as? Date else { return nil }
        return WidgetExtensionReport(version: version, pid: Int32(truncatingIfNeeded: defaults.integer(forKey: extensionPIDKey)), startedAt: startedAt,
                                     executable: defaults.string(forKey: extensionExecutableKey))
    }

    private static let launchRecorded: Void = {
        let defaults = sharedDefaults
        defaults.set(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "", forKey: extensionVersionKey)
        defaults.set(Int(ProcessInfo.processInfo.processIdentifier), forKey: extensionPIDKey)
        defaults.set(Date.now, forKey: extensionStartedAtKey)
        defaults.set(Bundle.main.executablePath, forKey: extensionExecutableKey)
    }()

    /// Called by the widget extension at start; records its `CFBundleVersion`, PID, start and executable once per process.
    public static func recordWidgetExtensionLaunch() { _ = launchRecorded }
}

#if os(macOS)
/// Which running widget extension processes are ours and still run an older binary.
///
/// A Sparkle update replaces the bundle on disk but leaves the old `QuotaWidgets-Mac` process running. chronod keeps
/// using it and drops what it draws ("Bundle version did not match", timelineReloadFailed), so the desktop widgets
/// go black until that process exits. The app finds it here and ends it; the listing and `kill` stay in the app.
public enum WidgetExtensionProcess {
    /// Tail of the extension's executable path, wherever the bundle it was started from now lives.
    public static let executableSuffix = "/QuotaWidgets-Mac.appex/Contents/MacOS/QuotaWidgets-Mac"

    /// One running process as `proc_pidinfo`/`proc_pidpath` see it.
    public struct Candidate: Equatable, Sendable {
        public var pid: Int32
        public var uid: UInt32
        /// Executable path as the kernel has it, even when no file is left there; nil when it has none.
        public var path: String?
        public var startedAt: Date

        public init(pid: Int32, uid: UInt32, path: String?, startedAt: Date) {
            self.pid = pid
            self.uid = uid
            self.path = path
            self.startedAt = startedAt
        }
    }

    /// The extension's executable inside the app bundle at `app`.
    public static func executable(inApp app: URL) -> String { app.path + "/Contents/PlugIns" + executableSuffix }

    /// Our own extension processes: same user, and shown to come from `executable`, the one in this installation —
    /// the kernel has that path, or the process reported it at start (when Sparkle moved and deleted the old bundle the
    /// kernel path no longer says). A process name or a missing file proves nothing, so another bundle or another
    /// installed copy of the app keeps its process.
    public static func ours(_ candidates: [Candidate], uid: UInt32, executable: String, report: WidgetExtensionReport?) -> [Candidate] {
        candidates.filter { $0.uid == uid && ($0.path == executable || reported(by: $0, report)?.executable == executable) }
    }

    /// `report` when `process` wrote it; nil when it belongs to another process.
    static func reported(by process: Candidate, _ report: WidgetExtensionReport?) -> WidgetExtensionReport? {
        guard let report, report.pid == process.pid, abs(report.startedAt.timeIntervalSince(process.startedAt)) < 10 else { return nil }
        return report
    }

    /// Processes to end so WidgetKit starts the extension from the current binary. All of ours on the first launch of a new
    /// app version (or when `force`d from Settings); otherwise those started before the binary on disk last changed
    /// or that reported another version than the app's.
    public static func toRestart(_ candidates: [Candidate], uid: UInt32, executable: String, appVersion: String,
                                 lastSeenAppVersion: String?, binaryChangedAt: Date?, report: WidgetExtensionReport?,
                                 force: Bool = false) -> [Candidate] {
        let own = ours(candidates, uid: uid, executable: executable, report: report)
        if force || appVersion != lastSeenAppVersion { return own }
        return own.filter { process in
            if let binaryChangedAt, process.startedAt < binaryChangedAt { return true }
            if let version = reported(by: process, report)?.version, version != appVersion { return true }
            return false
        }
    }

    /// The older version a running extension of ours reported, for Settings; nil when it matches or none is running.
    public static func staleVersion(_ candidates: [Candidate], uid: UInt32, executable: String, appVersion: String,
                                    report: WidgetExtensionReport?) -> String? {
        ours(candidates, uid: uid, executable: executable, report: report).lazy.compactMap { reported(by: $0, report)?.version }.first { $0 != appVersion }
    }
}
#endif
