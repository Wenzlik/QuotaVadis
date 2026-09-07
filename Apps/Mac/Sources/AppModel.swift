import Foundation
import Observation
import ServiceManagement
import SwiftUI
import UserNotifications
import WidgetKit
import QuotaCore

/// What the menu bar number represents.
enum MenuBarSource: Hashable, Codable {
    /// Highest usage across every visible provider.
    case worst
    /// One instance's primary (session) or secondary (weekly/monthly) window.
    case provider(String, secondary: Bool)

    var storageKey: String {
        switch self {
        case .worst: "worst"
        case .provider(let id, let secondary): "\(id)|\(secondary ? "secondary" : "primary")"
        }
    }

    init(storageKey: String) {
        let parts = storageKey.split(separator: "|")
        if parts.count == 2 {
            self = .provider(String(parts[0]), secondary: parts[1] == "secondary")
        } else {
            self = .worst
        }
    }
}

/// Single source of truth for the Mac app: settings, latest provider states, refresh loop.
@MainActor
@Observable
final class AppModel {
    /// Keyed by instance id: "claude", "claude:<suffix>", "codex", "cursor".
    var states: [String: ProviderState] = [:]
    var lastAttempts: [String: Date] = [:]
    var costs: [ProviderID: CostReport] = [:]
    var lastRefresh: Date?
    var isRefreshing = false
    var isRefreshingCosts = false

    // iCloud sync
    var syncStatus: CloudSync.Status = .unknown
    var lastSyncPush: Date?
    var lastSyncAttempt: Date?
    var lastSyncError: String?
    var isSyncing = false

    // Settings. Stored directly in UserDefaults; @AppStorage inside @Observable is not supported.
    var enabledProviders: Set<ProviderID> {
        didSet {
            defaults.set(enabledProviders.map(\.rawValue).sorted(), forKey: "enabledProviders")
            if case .provider(let id, _) = menuBarSource,
               !enabledProviders.contains(where: { id == $0.rawValue || id.hasPrefix($0.rawValue + ":") }) {
                menuBarSource = .worst
            }
            updateWidgets()
            schedulePublish()
            Task { await refresh() }
        }
    }
    /// Seconds between limit refreshes. Default one minute; 30 s is the floor so the provider APIs are not hammered.
    var refreshIntervalSeconds: Int {
        didSet { defaults.set(refreshIntervalSeconds, forKey: "refreshIntervalSeconds"); scheduleRefresh() }
    }
    var warnAtPercent: Int {
        didSet { defaults.set(warnAtPercent, forKey: "warnAtPercent"); alerts.warnAtPercent = warnAtPercent }
    }
    var notifyOnReset: Bool {
        didSet { defaults.set(notifyOnReset, forKey: "notifyOnReset"); alerts.notifyOnReset = notifyOnReset }
    }
    var notifyExtraUsage: Bool {
        didSet { defaults.set(notifyExtraUsage, forKey: "notifyExtraUsage"); alerts.notifyExtraUsage = notifyExtraUsage }
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
    /// Windows left out of the "Highest usage" menu bar number, as "<instanceID>/<windowID>". New windows count by default.
    var menuBarExcluded: Set<String> {
        didSet { defaults.set(menuBarExcluded.sorted(), forKey: "menuBarExcluded") }
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
            syncGeneration += 1
            defaults.set(!syncEnabled, forKey: "pendingCloudRemoval")
            requestSync()
        }
    }
    /// Instances whose row is expanded to the full detail. Remembered across launches.
    var expanded: Set<String> {
        didSet { defaults.set(expanded.sorted(), forKey: "expandedInstances") }
    }
    /// Extra Claude logins (Keychain services of other organizations' Claude Code profiles).
    var extraClaudeServices: [String] {
        didSet {
            defaults.set(extraClaudeServices, forKey: "extraClaudeServices")
            Task {
                await service.setFetchers(UsageService.defaultFetchers(extraClaudeServices: extraClaudeServices))
                states = states.filter { key, _ in !key.hasPrefix("claude:") || extraClaudeServices.contains { key == "claude:" + Self.suffix($0) } }
                await refresh()
            }
        }
    }

    static func suffix(_ service: String) -> String {
        service.replacingOccurrences(of: ClaudeCredentials.keychainService, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private let defaults = UserDefaults.standard
    private let service: UsageService
    private let costService = CostService()
    private let cloud = CloudSync()
    private let syncQueue = SerialOperationQueue()
    private var syncGeneration = 0
    private var refreshAgain = false
    private var publishTask: Task<Void, Never>?
    private var lastCostRefresh: Date?
    /// Cost scanning reads hundreds of MB of logs on a cold start and pages Cursor's dashboard; 15 min is plenty.
    private let costInterval: TimeInterval = 15 * 60
    private var timer: Timer?
    private var alerts: QuotaAlertEngine
    private let notifications = NotificationCoordinator()

    init() {
        let stored = defaults.stringArray(forKey: "enabledProviders")?.compactMap(ProviderID.init(rawValue:))
        enabledProviders = stored.map(Set.init) ?? Set(ProviderID.allCases)
        if let seconds = defaults.object(forKey: "refreshIntervalSeconds") as? Int {
            refreshIntervalSeconds = max(30, seconds)
        } else if let legacyMinutes = defaults.object(forKey: "refreshIntervalMinutes") as? Int {
            refreshIntervalSeconds = max(30, legacyMinutes * 60)   // migrate the pre-0.2 setting
        } else {
            refreshIntervalSeconds = 60
        }
        warnAtPercent = defaults.object(forKey: "warnAtPercent") as? Int ?? 80
        notifyOnReset = defaults.object(forKey: "notifyOnReset") as? Bool ?? true
        notifyExtraUsage = defaults.object(forKey: "notifyExtraUsage") as? Bool ?? true
        alerts = QuotaAlertEngine(warnAtPercent: defaults.object(forKey: "warnAtPercent") as? Int ?? 80,
                                  notifyOnReset: defaults.object(forKey: "notifyOnReset") as? Bool ?? true,
                                  notifyExtraUsage: defaults.object(forKey: "notifyExtraUsage") as? Bool ?? true,
                                  warned: Set(defaults.stringArray(forKey: "warnedKeys") ?? []),
                                  creditBaseline: defaults.dictionary(forKey: "creditBaseline") as? [String: Double] ?? [:])
        launchAtLogin = SMAppService.mainApp.status == .enabled
        menuBarSource = MenuBarSource(storageKey: defaults.string(forKey: "menuBarSource") ?? "worst")
        showPercentInMenuBar = defaults.object(forKey: "showPercentInMenuBar") as? Bool ?? true
        useAppIconInMenuBar = defaults.object(forKey: "useAppIconInMenuBar") as? Bool ?? false
        menuBarExcluded = Set(defaults.stringArray(forKey: "menuBarExcluded") ?? [])
        fastModeAt2x = defaults.bool(forKey: "fastModeAt2x")
        syncEnabled = defaults.object(forKey: "syncEnabled") as? Bool ?? true
        lastSyncPush = defaults.object(forKey: "lastSyncPush") as? Date
        lastSyncError = defaults.string(forKey: "lastSyncError")
        expanded = Set(defaults.stringArray(forKey: "expandedInstances") ?? [])
        extraClaudeServices = defaults.stringArray(forKey: "extraClaudeServices") ?? []
        service = UsageService(fetchers: UsageService.defaultFetchers(extraClaudeServices: defaults.stringArray(forKey: "extraClaudeServices") ?? []))
        hasOnboarded = defaults.bool(forKey: "hasOnboarded")
        scheduleRefresh()
        if !syncEnabled && defaults.bool(forKey: "pendingCloudRemoval") { requestSync() }
        // First launch waits for the welcome window so the Keychain prompt is explained before it appears.
        if hasOnboarded { Task { await refresh() } }
    }

    private(set) var hasOnboarded: Bool

    func completeOnboarding() {
        hasOnboarded = true
        defaults.set(true, forKey: "hasOnboarded")
        Task { await refresh() }
    }

    /// Per-provider login source and validity for Settings; refreshed on demand.
    var credentialStatuses: [ProviderID: CredentialStatus] = [:]
    func refreshCredentialStatuses() {
        for provider in ProviderID.allCases { credentialStatuses[provider] = CredentialStatus.status(for: provider) }
    }

    struct Instance: Hashable, Identifiable {
        let id: String
        let provider: ProviderID
    }

    /// Instances in display order: primary Claude, extra Claude logins, Codex, Cursor; including enabled tools that need setup.
    var visibleInstances: [Instance] {
        var out: [Instance] = []
        for provider in ProviderID.allCases where enabledProviders.contains(provider) {
            let ids = [provider.rawValue] + (provider == .claude ? extraClaudeServices.map { "claude:" + Self.suffix($0) } : [])
            for id in ids { out.append(Instance(id: id, provider: provider)) }
        }
        return out
    }

    var worstPercent: Double? {
        visibleInstances.compactMap { states[$0.id]?.snapshot?.worstWindow?.usedPercent }.max()
    }

    /// The number shown in the menu bar, per the user's `menuBarSource` choice.
    var menuBarPercent: Double? { menuBarMeasurement?.window.usedPercent }

    var menuBarMeasurement: (snapshot: UsageSnapshot, window: UsageWindow)? {
        switch menuBarSource {
        case .worst:
            return visibleInstances.compactMap { instance -> (snapshot: UsageSnapshot, window: UsageWindow)? in
                guard let snapshot = states[instance.id]?.snapshot else { return nil }
                let candidates = (snapshot.alertWindows.isEmpty ? snapshot.windows : snapshot.alertWindows)
                    .filter { !menuBarExcluded.contains("\(instance.id)/\($0.id)") }
                guard let window = candidates.max(by: { $0.usedPercent < $1.usedPercent }) else { return nil }
                return (snapshot, window)
            }.max { $0.window.usedPercent < $1.window.usedPercent }
        case .provider(let id, let secondary):
            guard visibleInstances.contains(where: { $0.id == id }), let snapshot = states[id]?.snapshot,
                  let window = (secondary ? snapshot.secondaryWindow : snapshot.primaryWindow) ?? snapshot.worstWindow else { return nil }
            return (snapshot, window)
        }
    }

    var menuBarIsStale: Bool {
        guard let measurement = menuBarMeasurement else { return false }
        let snapshot = measurement.snapshot
        return ProviderSyncStatus(instanceID: snapshot.instanceID, provider: snapshot.provider,
                                  state: states[snapshot.instanceID] ?? .unavailable, lastAttemptAt: nil).freshness() != .fresh
    }

    var menuBarAccessibilityLabel: String {
        guard let measurement = menuBarMeasurement else { return "QuotaVadis, no usage data. Open to set up tools." }
        return "\(measurement.snapshot.provider.displayName), \(measurement.window.title), \(Int(measurement.window.usedPercent.rounded())) percent used, \(menuBarIsStale ? "stale measurement" : "fresh measurement")"
    }

    func title(for instance: Instance) -> String {
        guard instance.provider == .claude, instance.id != "claude", let org = states[instance.id]?.snapshot?.organization else {
            return instance.provider.displayName
        }
        return "\(instance.provider.displayName) · \(org)"
    }

    /// Every window that can feed "Highest usage", for the Settings checklist.
    var menuBarCandidates: [(key: String, label: String)] {
        visibleInstances.flatMap { instance -> [(key: String, label: String)] in
            guard let snapshot = states[instance.id]?.snapshot else { return [] }
            let windows = snapshot.alertWindows.isEmpty ? snapshot.windows : snapshot.alertWindows
            return windows.map { ("\(instance.id)/\($0.id)", "\(title(for: instance)) · \($0.title)") }
        }
    }

    /// Menu bar choices that make sense right now: only windows the providers actually report.
    var menuBarSourceOptions: [(MenuBarSource, String)] {
        var options: [(MenuBarSource, String)] = [(.worst, "Highest usage")]
        for instance in visibleInstances {
            let snapshot = states[instance.id]?.snapshot
            let name = title(for: instance)
            if let w = snapshot?.primaryWindow { options.append((.provider(instance.id, secondary: false), "\(name) · \(w.title)")) }
            if let w = snapshot?.secondaryWindow, w.id != snapshot?.primaryWindow?.id {
                options.append((.provider(instance.id, secondary: true), "\(name) · \(w.title)"))
            }
        }
        return options
    }

    func refresh() async {
        guard !isRefreshing else { refreshAgain = true; return }
        isRefreshing = true
        defer {
            isRefreshing = false
            if refreshAgain { refreshAgain = false; Task { await refresh() } }
        }
        for instance in visibleInstances { lastAttempts[instance.id] = .now }
        _ = await service.refresh(enabled: enabledProviders) { [weak self] id, state in
            await self?.received(id: id, state: state)
        }
        lastRefresh = .now
        notifyIfNeeded()
        schedulePublish()
        if lastCostRefresh.map({ !Calendar.current.isDateInToday($0) || Date.now.timeIntervalSince($0) > costInterval }) ?? true {
            Task { await refreshCosts() }
        }
    }

    private func received(id: String, state: ProviderState) {
        states[id] = state
        updateWidgets()
        schedulePublish()
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
        publishTask?.cancel()
        publishTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await publishToCloud()
        }
    }

    private var currentPayload: DevicePayload {
        DevicePayload(deviceID: DeviceIdentity.id, deviceName: DeviceInfo.name,
                      snapshots: visibleInstances.compactMap { states[$0.id]?.snapshot },
                      costs: ProviderID.allCases.filter { enabledProviders.contains($0) }.compactMap { costs[$0] },
                      providerStatuses: visibleInstances.map {
                          ProviderSyncStatus(instanceID: $0.id, provider: $0.provider,
                                             state: states[$0.id] ?? .unavailable, lastAttemptAt: lastAttempts[$0.id])
                      })
    }

    /// Widgets on this Mac read the App Group file; no iCloud round trip.
    private func updateWidgets() {
        SharedStore.write(currentPayload)
        WidgetCenter.shared.reloadAllTimelines()
    }

    @discardableResult
    private func requestSync() -> Task<Void, Never> {
        updateWidgets()
        let generation = syncGeneration
        let enabled = syncEnabled
        return syncQueue.enqueue { [weak self] in
            await self?.performSync(enabled: enabled, generation: generation)
        }
    }

    func publishToCloud() async { await requestSync().value }

    private func performSync(enabled: Bool, generation: Int) async {
        guard generation == syncGeneration else { return }
        isSyncing = true
        defer { isSyncing = false }
        lastSyncAttempt = .now
        do {
            if !enabled {
                // A queued removal runs after every older write, even if disabled during accountStatus.
                try await withTimeout(seconds: 60) { try await self.cloud.unpublish(deviceID: DeviceIdentity.id) }
                defaults.set(false, forKey: "pendingCloudRemoval")
                lastSyncPush = nil
                lastSyncError = nil
            } else {
                syncStatus = try await withTimeout(seconds: 20) { await self.cloud.accountStatus() }
                guard generation == syncGeneration, syncEnabled else { return }
                guard syncStatus == .available else { throw ProviderError.network("iCloud not available: \(syncStatus)") }
                let payload = currentPayload
                try await withTimeout(seconds: 60) { try await self.cloud.publish(payload) }
                lastSyncPush = .now
                lastSyncError = nil
            }
        } catch {
            lastSyncError = (enabled ? "Sync failed: " : "Removal failed; will retry: ") +
                (error is TimeoutError ? "iCloud timed out" : error.localizedDescription)
        }
        defaults.set(lastSyncPush, forKey: "lastSyncPush")
        defaults.set(lastSyncError, forKey: "lastSyncError")
    }

    private func scheduleRefresh() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(refreshIntervalSeconds), repeats: true) { _ in
            Task { @MainActor in await self.refresh() }
        }
        timer?.tolerance = min(30, TimeInterval(refreshIntervalSeconds) / 6)
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    /// Sends one sample of each alert kind so the user can see and hear what they look like.
    func sendTestNotifications() {
        let now = Date()
        let soon = now.addingTimeInterval(30 * 60)
        let samples = [
            QuotaAlert(kind: .threshold, key: "test/threshold", title: "Claude Code: Session at 85%",
                       body: "15% left · resets \(soon.resetLabel(now: now))"),
            QuotaAlert(kind: .reset, key: "test/reset", title: "Codex: Weekly reset", body: "Back to 100% available."),
            QuotaAlert(kind: .extraUsageUnexpected, key: "test/extra-unexpected", title: "Claude Code: paying extra usage while limits remain",
                       body: "Extra usage grew by $0.42 to $3.17 although no window is exhausted. A model outside your seat (e.g. Fable on a Standard seat) is billed separately."),
            QuotaAlert(kind: .extraUsageAtLimit, key: "test/extra-limit", title: "Claude Code: paying extra usage, reset in 30 min",
                       body: "Session is exhausted; further use is billed. Extra usage is at $3.59. Resets \(soon.resetLabel(now: now))."),
        ]
        notifications.onSnooze = { _ in }
        notifications.deliver(samples)
    }

    /// Threshold crossings and resets, via the shared alert engine. Snooze comes back from the notification action.
    private func notifyIfNeeded() {
        var titles: [String: String] = [:]
        for instance in visibleInstances { titles[instance.id] = title(for: instance) }
        let snapshots = visibleInstances.compactMap { instance -> UsageSnapshot? in
            if case .fresh(let snapshot) = states[instance.id] { return snapshot }; return nil
        }
        let due = alerts.evaluate(snapshots: snapshots, titles: titles)
        defaults.set(alerts.warned.sorted(), forKey: "warnedKeys")
        defaults.set(alerts.creditBaseline, forKey: "creditBaseline")
        // Threshold/reset alerts respect "Never"; extra-usage alerts have their own switch.
        let filtered = due.filter { $0.kind == .extraUsageUnexpected || $0.kind == .extraUsageAtLimit || warnAtPercent <= 100 }
        guard !filtered.isEmpty else { return }
        notifications.onSnooze = { [weak self] key in self?.alerts.snooze(key: key) }
        notifications.deliver(filtered)
    }

}
