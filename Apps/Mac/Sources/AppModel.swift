import Foundation
import Observation
import ServiceManagement
import SwiftUI
import UserNotifications
import QuotaCore

/// Single source of truth for the Mac app: settings, latest provider states, refresh loop.
@MainActor
@Observable
final class AppModel {
    var states: [ProviderID: ProviderState] = [:]
    var lastRefresh: Date?
    var isRefreshing = false

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

    private let defaults = UserDefaults.standard
    private let service = UsageService()
    private var timer: Timer?
    private var warned: Set<String> = []

    init() {
        let stored = defaults.stringArray(forKey: "enabledProviders")?.compactMap(ProviderID.init(rawValue:))
        enabledProviders = stored.map(Set.init) ?? Set(ProviderID.allCases)
        refreshIntervalMinutes = max(1, defaults.object(forKey: "refreshIntervalMinutes") as? Int ?? 5)
        warnAtPercent = defaults.object(forKey: "warnAtPercent") as? Int ?? 80
        launchAtLogin = SMAppService.mainApp.status == .enabled
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

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let result = await service.refresh(enabled: enabledProviders)
        states.merge(result) { _, new in new }
        lastRefresh = .now
        notifyIfNeeded()
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
