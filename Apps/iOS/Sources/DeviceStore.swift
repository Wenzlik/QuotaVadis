import Foundation
import Observation
import SwiftUI
import UserNotifications
import WidgetKit
import QuotaCore

/// Reads every Mac's published payload from the iCloud private database. No fetching of provider APIs on iOS.
@MainActor
@Observable
final class DeviceStore {
    static let shared = DeviceStore()
    enum RefreshResult { case newData, noData, failed }
    private var refreshTask: Task<RefreshResult, Never>?
    var devices: [DevicePayload] = []
    var status: CloudSync.Status = .unknown
    var lastRefresh: Date?
    var lastError: String?
    var isRefreshing = false
    var expanded: Set<String> = []
    /// Samples of what the Macs measured, recorded here as payloads arrive (foreground, push, background refresh).
    /// The Mac's own history is not synced; see `recordHistory`.
    private(set) var history = UsageHistory.load()
    private let historyWriter = UsageHistoryWriter()
    @ObservationIgnored private var historyRevision = 0
    /// Big-bar pick per provider instance, same key and format as the Mac app (its own defaults, not synced).
    var primaryWindowIDs: [String: String] {
        didSet { UserDefaults.standard.set(primaryWindowIDs, forKey: "primaryWindowIDs") }
    }

    // Notifications, evaluated locally whenever new numbers arrive (foreground or silent push).
    var notificationsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled")
            if notificationsEnabled { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
        }
    }
    var warnAtPercent: Int { didSet { UserDefaults.standard.set(warnAtPercent, forKey: "warnAtPercent"); alerts.warnAtPercent = warnAtPercent } }
    var notifyOnReset: Bool { didSet { UserDefaults.standard.set(notifyOnReset, forKey: "notifyOnReset"); alerts.notifyOnReset = notifyOnReset } }
    var notifyExtraUsage: Bool { didSet { UserDefaults.standard.set(notifyExtraUsage, forKey: "notifyExtraUsage"); alerts.notifyExtraUsage = notifyExtraUsage } }
    private var alerts: QuotaAlertEngine

    /// Remembered device choice; falls back to the most recently updated Mac.
    var selectedDeviceID: String? {
        didSet { UserDefaults.standard.set(selectedDeviceID, forKey: "selectedDeviceID"); updateWidgets() }
    }

    /// Same samples as the Mac app's Settings button.
    func sendTestNotifications() {
        let now = Date(); let soon = now.addingTimeInterval(30 * 60)
        let samples = [
            QuotaAlert(kind: .threshold, key: "test/threshold", title: "Claude Code: Session at 85%", body: "15% left · resets \(soon.resetLabel(now: now))"),
            QuotaAlert(kind: .reset, key: "test/reset", title: "Codex: Weekly reset", body: "Back to 100% available."),
            QuotaAlert(kind: .extraUsageUnexpected, key: "test/extra-unexpected", title: "Claude Code: paying extra usage while limits remain",
                       body: "Extra usage grew by $0.42 to $3.17 although no window is exhausted. A model outside your seat (e.g. Fable on a Standard seat) is billed separately."),
            QuotaAlert(kind: .extraUsageAtLimit, key: "test/extra-limit", title: "Claude Code: paying extra usage, reset in 30 min",
                       body: "Session is exhausted; further use is billed. Extra usage is at $3.59. Resets \(soon.resetLabel(now: now))."),
        ]
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            for alert in samples {
                let content = UNMutableNotificationContent()
                content.title = alert.title; content.body = alert.body
                content.sound = alert.kind == .reset ? nil : .default
                try? await center.add(UNNotificationRequest(identifier: alert.id + "/" + UUID().uuidString, content: content,
                                                 trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)))
            }
        }
    }

    private func evaluateAlerts() async {
        guard notificationsEnabled, let device = selectedDevice else { return }
        var titles: [String: String] = [:]
        for s in device.snapshots { titles[s.instanceID] = s.displayTitle }
        let due = alerts.evaluate(snapshots: device.alertableSnapshots, titles: titles)
        UserDefaults.standard.set(alerts.warned.sorted(), forKey: "warnedKeys")
        UserDefaults.standard.set(alerts.creditBaseline, forKey: "creditBaseline")
        let center = UNUserNotificationCenter.current()
        for alert in due {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = alert.kind == .reset ? nil : .default
            content.threadIdentifier = alert.key.split(separator: "/").first.map(String.init) ?? "quota"
            try? await center.add(UNNotificationRequest(identifier: alert.id + "/" + UUID().uuidString, content: content, trigger: nil))
        }
    }

    private func updateWidgets() {
        if let device = selectedDevice { SharedStore.write(device) }
        else { SharedStore.clear() }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private let cloud = CloudSync()
    private static let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("devices.json")

    init() {
        let d = UserDefaults.standard
        notificationsEnabled = d.object(forKey: "notificationsEnabled") as? Bool ?? false
        warnAtPercent = d.object(forKey: "warnAtPercent") as? Int ?? 80
        notifyOnReset = d.object(forKey: "notifyOnReset") as? Bool ?? true
        notifyExtraUsage = d.object(forKey: "notifyExtraUsage") as? Bool ?? true
        alerts = QuotaAlertEngine(warnAtPercent: d.object(forKey: "warnAtPercent") as? Int ?? 80,
                                  notifyOnReset: d.object(forKey: "notifyOnReset") as? Bool ?? true,
                                  notifyExtraUsage: d.object(forKey: "notifyExtraUsage") as? Bool ?? true,
                                  warned: Set(d.stringArray(forKey: "warnedKeys") ?? []),
                                  creditBaseline: d.dictionary(forKey: "creditBaseline") as? [String: Double] ?? [:])
        selectedDeviceID = UserDefaults.standard.string(forKey: "selectedDeviceID")
        primaryWindowIDs = d.dictionary(forKey: "primaryWindowIDs") as? [String: String] ?? [:]
        // Last known payloads so the app opens with content offline.
        if let data = try? Data(contentsOf: Self.cacheURL),
           let cached = try? JSONDecoder.iso.decode([DevicePayload].self, from: data) {
            devices = cached
        }
    }

    var selectedDevice: DevicePayload? {
        devices.first { $0.deviceID == selectedDeviceID } ?? devices.first
    }

    func start() async {
        // After an app update the widget file is still there; let the new extension draw it before iCloud answers.
        WidgetCenter.shared.reloadAllTimelines()
        await refresh()
        try? await cloud.ensureSubscription()
    }

    @discardableResult
    func refresh() async -> RefreshResult {
        // A push joining an ongoing foreground refresh must wait for its writes as well.
        if let refreshTask { return await refreshTask.value }
        let task = Task { await performRefresh() }
        refreshTask = task
        let result = await task.value
        refreshTask = nil
        return result
    }

    func refreshIfNeeded() async {
        if lastRefresh.map({ Date.now.timeIntervalSince($0) < 60 }) != true { await refresh() }
    }

    private func performRefresh() async -> RefreshResult {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            status = try await withTimeout(seconds: 10) { await self.cloud.accountStatus() }
            guard status == .available else {
                lastError = "iCloud is unavailable. Check your account and connection, then refresh."
                return .failed
            }
            let fetched = try await withTimeout(seconds: 15) { try await self.cloud.fetchAll() }
            let changed = devices != fetched
            // A successful empty response clears the cache; a read failure keeps the last good devices.
            let data = try JSONEncoder.iso.encode(fetched)
            try data.write(to: Self.cacheURL, options: .atomic)
            devices = fetched
            await recordHistory()
            updateWidgets()
            await evaluateAlerts()
            lastRefresh = .now
            // Data arrived; a widget-file problem or a skipped Mac record is shown as a note, not as a failed refresh.
            let readWarning = await cloud.lastReadWarning
            lastError = SharedStore.lastError.map { "Widgets could not be updated: \($0)" } ?? readWarning
            return changed ? .newData : .noData
        } catch {
            lastError = error.localizedDescription
            return .failed
        }
    }
}

extension DeviceStore {
    /// Each Mac's snapshots at their measurement time. Saved off the main thread by one writer, newest revision wins;
    /// the refresh waits for the save, so a background refresh reports completion only once it is on disk. The file
    /// is a few hundred KB at most (600 samples per window, pruned to the window's length).
    private func recordHistory() async {
        history.record(payloads: devices)
        historyRevision += 1
        try? await historyWriter.save(history, revision: historyRevision)
    }

    func forecast(_ window: UsageWindow, of snapshot: UsageSnapshot, in device: DevicePayload, now: Date) -> UsageForecast? {
        history.forecast(for: window, snapshot: snapshot, in: device, now: now)
    }

    /// The overview's "Most at risk" card and the Limits tab badge, for the selected Mac.
    func riskSummary(now: Date = .now) -> RiskSummary? {
        guard let device = selectedDevice else { return nil }
        let items = device.snapshots.flatMap { snapshot in
            RiskItem.items(for: snapshot, name: snapshot.displayTitle, now: now) { forecast($0, of: snapshot, in: device, now: now) }
        }
        return RiskSummary(items: items)
    }

    /// Picker binding: a pick the snapshot no longer reports reads as Default but stays saved for its return.
    func primaryWindowBinding(_ snapshot: UsageSnapshot) -> Binding<String?> {
        Binding(get: { snapshot.reportedWindowID(self.primaryWindowIDs[snapshot.instanceID]) },
                set: { self.primaryWindowIDs[snapshot.instanceID] = $0 })
    }
}

extension JSONEncoder { static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }() }
extension JSONDecoder { static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }() }
