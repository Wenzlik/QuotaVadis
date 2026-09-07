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
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            for alert in samples {
                let content = UNMutableNotificationContent()
                content.title = alert.title; content.body = alert.body
                content.sound = alert.kind == .reset ? nil : .default
                center.add(UNNotificationRequest(identifier: alert.id + "/" + UUID().uuidString, content: content,
                                                 trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)))
            }
        }
    }

    private func evaluateAlerts() {
        guard notificationsEnabled, let device = selectedDevice else { return }
        var titles: [String: String] = [:]
        for s in device.snapshots { titles[s.instanceID] = s.displayTitle }
        let due = alerts.evaluate(snapshots: device.snapshots, titles: titles)
        UserDefaults.standard.set(alerts.warned.sorted(), forKey: "warnedKeys")
        UserDefaults.standard.set(alerts.creditBaseline, forKey: "creditBaseline")
        let center = UNUserNotificationCenter.current()
        for alert in due {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = alert.kind == .reset ? nil : .default
            content.threadIdentifier = alert.key.split(separator: "/").first.map(String.init) ?? "quota"
            center.add(UNNotificationRequest(identifier: alert.id + "/" + UUID().uuidString, content: content, trigger: nil))
        }
    }

    private func updateWidgets() {
        guard let device = selectedDevice else { return }
        SharedStore.write(device)
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

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        status = await cloud.accountStatus()
        guard status == .available else { return }
        do {
            devices = try await cloud.fetchAll()
            lastRefresh = .now
            lastError = nil
            if let data = try? JSONEncoder.iso.encode(devices) { try? data.write(to: Self.cacheURL, options: .atomic) }
            updateWidgets()
            evaluateAlerts()
        } catch {
            lastError = error.localizedDescription
        }
    }
}

extension JSONEncoder { static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }() }
extension JSONDecoder { static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }() }
