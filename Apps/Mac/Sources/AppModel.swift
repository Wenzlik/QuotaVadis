import Foundation
import Observation
import ServiceManagement
import SwiftUI
import UserNotifications
import QuotaCore

/// What the menu bar number represents.
enum MenuBarSource: Hashable, Codable {
    /// Highest usage across every visible provider.
    case worst
    /// One provider's primary (session) or secondary (weekly/monthly) window.
    case provider(ProviderID, secondary: Bool)

    var storageKey: String {
        switch self {
        case .worst: "worst"
        case .provider(let id, let secondary): "\(id.rawValue):\(secondary ? "secondary" : "primary")"
        }
    }

    init(storageKey: String) {
        let parts = storageKey.split(separator: ":")
        if parts.count == 2, let id = ProviderID(rawValue: String(parts[0])) {
            self = .provider(id, secondary: parts[1] == "secondary")
        } else {
            self = .worst
        }
    }
}

/// Single source of truth for the Mac app: settings, latest provider states, refresh loop.
@MainActor
@Observable
final class AppModel {
    var states: [ProviderID: ProviderState] = [:]
    var costs: [ProviderID: CostReport] = [:]
    var lastRefresh: Date?
    var isRefreshing = false
    var isRefreshingCosts = false

    // iCloud sync
    var syncStatus: CloudSync.Status = .unknown
    var lastSyncPush: Date?
    var lastSyncError: String?

    // Settings. Stored directly in UserDefaults; @AppStorage inside @Observable is not supported.
    var enabledProviders: Set<ProviderID> {
        didSet { defaults.set(enabledProviders.map(\.rawValue).sorted(), forKey: "enabledProviders"); scheduleRefresh() }
    }
    var refreshIntervalMinutes: Int {
        didSet { defaults.set(refreshIntervalMinutes, forKey: "refreshIntervalMinutes"); scheduleRefresh() }
    }
    var warnAtPercent: Int {
        didSet { defaults.set(warnAtPercent, forKey: "warnAtPercent") }
    }
    var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }
    var menuBarSource: MenuBarSource {
        didSet { defaults.set(menuBarSource.storageKey, forKey: "menuBarSource") }
    }
    var showPercentInMenuBar: Bool {
        didSet { defaults.set(showPercentInMenuBar, forKey: "showPercentInMenuBar") }
    }
    /// Colour app icon instead of the monochrome flame glyph.
    var useAppIconInMenuBar: Bool {
        didSet { defaults.set(useAppIconInMenuBar, forKey: "useAppIconInMenuBar") }
    }
    /// Price Codex Fast mode (priority processing) at OpenAI's 2x rate. Off = list price, same as CodexBar.
    var fastModeAt2x: Bool {
        didSet { defaults.set(fastModeAt2x, forKey: "fastModeAt2x"); Task { lastCostRefresh = nil; await refreshCosts() } }
    }
    /// Publish snapshots + cost reports to the iCloud private database for the iOS companion and other Macs.
    var syncEnabled: Bool {
        didSet {
            defaults.set(syncEnabled, forKey: "syncEnabled")
            Task { syncEnabled ? await publishToCloud() : await unpublishFromCloud() }
        }
    }
    /// Providers whose row is expanded to the full detail. Remembered across launches.
    var expanded: Set<ProviderID> {
        didSet { defaults.set(expanded.map(\.rawValue).sorted(), forKey: "expandedProviders") }
    }

    private let defaults = UserDefaults.standard
    private let service = UsageService()
    private let costService = CostService()
    private let cloud = CloudSync()
    private var publishTask: Task<Void, Never>?
    private var lastCostRefresh: Date?
    /// Cost scanning reads hundreds of MB of logs on a cold start and pages Cursor's dashboard; 15 min is plenty.
    private let costInterval: TimeInterval = 15 * 60
    private var timer: Timer?
    private var warned: Set<String> = []

    init() {
        let stored = defaults.stringArray(forKey: "enabledProviders")?.compactMap(ProviderID.init(rawValue:))
        enabledProviders = stored.map(Set.init) ?? Set(ProviderID.allCases)
        refreshIntervalMinutes = max(1, defaults.object(forKey: "refreshIntervalMinutes") as? Int ?? 5)
        warnAtPercent = defaults.object(forKey: "warnAtPercent") as? Int ?? 80
        launchAtLogin = SMAppService.mainApp.status == .enabled
        menuBarSource = MenuBarSource(storageKey: defaults.string(forKey: "menuBarSource") ?? "worst")
        showPercentInMenuBar = defaults.object(forKey: "showPercentInMenuBar") as? Bool ?? true
        useAppIconInMenuBar = defaults.object(forKey: "useAppIconInMenuBar") as? Bool ?? false
        fastModeAt2x = defaults.bool(forKey: "fastModeAt2x")
        syncEnabled = defaults.object(forKey: "syncEnabled") as? Bool ?? true
        lastSyncPush = defaults.object(forKey: "lastSyncPush") as? Date
        lastSyncError = defaults.string(forKey: "lastSyncError")
        expanded = Set(defaults.stringArray(forKey: "expandedProviders")?.compactMap(ProviderID.init(rawValue:)) ?? [])
        scheduleRefresh()
        Task { await refresh() }
    }

    /// Providers in display order: enabled ones whose tool exists on this Mac.
    var visibleProviders: [ProviderID] {
        ProviderID.allCases.filter { enabledProviders.contains($0) && states[$0] != .unavailable }
    }

    var worstPercent: Double? {
        visibleProviders.compactMap { states[$0]?.snapshot?.worstWindow?.usedPercent }.max()
    }

    /// The number shown in the menu bar, per the user's `menuBarSource` choice.
    var menuBarPercent: Double? {
        switch menuBarSource {
        case .worst:
            return worstPercent
        case .provider(let id, let secondary):
            guard let snapshot = states[id]?.snapshot else { return nil }
            return (secondary ? snapshot.secondaryWindow : snapshot.primaryWindow)?.usedPercent ?? snapshot.worstWindow?.usedPercent
        }
    }

    /// Menu bar choices that make sense right now: only windows the providers actually report.
    var menuBarSourceOptions: [(MenuBarSource, String)] {
        var options: [(MenuBarSource, String)] = [(.worst, "Highest usage")]
        for id in ProviderID.allCases where enabledProviders.contains(id) {
            let snapshot = states[id]?.snapshot
            if let w = snapshot?.primaryWindow { options.append((.provider(id, secondary: false), "\(id.displayName) · \(w.title)")) }
            if let w = snapshot?.secondaryWindow, w.id != snapshot?.primaryWindow?.id {
                options.append((.provider(id, secondary: true), "\(id.displayName) · \(w.title)"))
            }
        }
        return options
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let result = await service.refresh(enabled: enabledProviders)
        states.merge(result) { _, new in new }
        lastRefresh = .now
        notifyIfNeeded()
        schedulePublish()
        if lastCostRefresh.map({ Date.now.timeIntervalSince($0) > costInterval }) ?? true {
            Task { await refreshCosts() }
        }
    }

    func refreshCosts() async {
        guard !isRefreshingCosts else { return }
        isRefreshingCosts = true
        defer { isRefreshingCosts = false }
        let result = await costService.refresh(enabled: enabledProviders, fastModeAt2x: fastModeAt2x)
        costs.merge(result) { _, new in new }
        lastCostRefresh = .now
        schedulePublish()
    }

    // MARK: - iCloud

    /// Coalesces the usage and cost publishes that land a few seconds apart into one record write.
    private func schedulePublish() {
        guard syncEnabled else { return }
        publishTask?.cancel()
        publishTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await publishToCloud()
        }
    }

    func publishToCloud() async {
        guard syncEnabled else { return }
        syncStatus = await cloud.accountStatus()
        guard syncStatus == .available else { return }
        let payload = DevicePayload(
            deviceID: DeviceIdentity.id,
            deviceName: DeviceInfo.name,
            snapshots: ProviderID.allCases.compactMap { states[$0]?.snapshot },
            costs: ProviderID.allCases.compactMap { costs[$0] })
        do {
            try await cloud.publish(payload)
            lastSyncPush = .now
            lastSyncError = nil
        } catch {
            lastSyncError = error.localizedDescription
        }
        // Persisted so the status survives relaunch and can be inspected with `defaults read`.
        defaults.set(lastSyncPush, forKey: "lastSyncPush")
        defaults.set(lastSyncError, forKey: "lastSyncError")
    }

    private func unpublishFromCloud() async {
        try? await cloud.unpublish(deviceID: DeviceIdentity.id)
        lastSyncPush = nil
    }

    private func scheduleRefresh() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(refreshIntervalMinutes * 60), repeats: true) { _ in
            Task { @MainActor in await self.refresh() }
        }
        timer?.tolerance = 30
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    /// One notification per window per crossing of the threshold; resets once the window drops back under.
    private func notifyIfNeeded() {
        let center = UNUserNotificationCenter.current()
        for id in visibleProviders {
            guard let snapshot = states[id]?.snapshot else { continue }
            for window in snapshot.windows {
                let key = "\(id.rawValue)/\(window.id)"
                if window.usedPercent >= Double(warnAtPercent) {
                    guard !warned.contains(key) else { continue }
                    warned.insert(key)
                    let content = UNMutableNotificationContent()
                    content.title = "\(id.displayName) \(window.title) at \(Int(window.usedPercent))%"
                    if let reset = window.resetsAt {
                        content.body = "Resets \(reset.formatted(.relative(presentation: .named)))"
                    }
                    center.requestAuthorization(options: [.alert]) { granted, _ in
                        guard granted else { return }
                        center.add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
                    }
                } else {
                    warned.remove(key)
                }
            }
        }
    }
}
