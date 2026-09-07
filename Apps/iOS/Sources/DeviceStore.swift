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
        let due = alerts.evaluate(snapshots: device.freshSnapshots, titles: titles)
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
            updateWidgets()
            if let error = SharedStore.lastError { throw ProviderError.network(error) }
            await evaluateAlerts()
            lastRefresh = .now
            lastError = nil
            return changed ? .newData : .noData
        } catch {
            lastError = error.localizedDescription
            return .failed
        }
    }
}

extension JSONEncoder { static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }() }
extension JSONDecoder { static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }() }
