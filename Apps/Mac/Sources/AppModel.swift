import AppKit
import CoreImage
import Foundation
import Observation
import ServiceManagement
import SwiftUI
import UserNotifications
import WidgetKit
import QuotaCore

/// What the menu bar number (or one bar, in `.bars` style) represents.
enum MenuBarSource: Hashable, Codable {
    /// Highest usage across every visible provider.
    case worst
    /// One instance's primary (session) or secondary (weekly/monthly) window.
    case provider(String, secondary: Bool)
    /// One instance's spend against a cap (Claude "Extra usage", Cursor usage-based cost).
    case spend(String)
    /// One instance's specific window by id — the only way to reach a window that is neither primary nor
    /// secondary, e.g. Cursor's Grok Bot or Claude's per-model Sonnet/Opus weekly windows.
    case window(String, windowID: String)

    var storageKey: String {
        switch self {
        case .worst: "worst"
        case .provider(let id, let secondary): "\(id)|\(secondary ? "secondary" : "primary")"
        case .spend(let id): "\(id)|spend"
        case .window(let id, let windowID): "\(id)|window|\(windowID)"
        }
    }

    init(storageKey: String) {
        let parts = storageKey.split(separator: "|", omittingEmptySubsequences: false)
        if parts.count == 3, parts[1] == "window" {
            self = .window(String(parts[0]), windowID: String(parts[2]))
        } else if parts.count == 2 {
            self = parts[1] == "spend" ? .spend(String(parts[0])) : .provider(String(parts[0]), secondary: parts[1] == "secondary")
        } else {
            self = .worst
        }
    }
}

/// Icon glyph, or up to `AppModel.maxBars` CodexBar-style filled bars (see `menuBarBarSources`).
enum MenuBarDisplayStyle: String, Codable, CaseIterable {
    case icon
    case bars
}

/// Where a bar's percent text goes; only meaningful when `showPercentInMenuBar` is on.
enum MenuBarPercentPlacement: String, Codable, CaseIterable {
    case beside
    case inside
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
            if !applyingOnboarding { Task { await refresh() } }
        }
    }
    /// Seconds between limit refreshes for the fixed cadence; 0 = adaptive (2–30 min by interaction and activity).
    var refreshIntervalSeconds: Int {
        didSet { defaults.set(refreshIntervalSeconds, forKey: "refreshIntervalSeconds"); scheduleRefresh() }
    }
    var isAdaptiveRefresh: Bool { refreshIntervalSeconds == 0 }
    /// Why the current adaptive delay was chosen, for Settings.
    private(set) var adaptiveReason: AdaptiveRefreshPolicy.Reason?
    private(set) var nextRefreshAt: Date?
    private var lastPanelOpen: Date?
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
    var menuBarDisplayStyle: MenuBarDisplayStyle {
        didSet { defaults.set(menuBarDisplayStyle.rawValue, forKey: "menuBarDisplayStyle") }
    }
    /// 1–4 sources shown as filled bars instead of the icon glyph, style `.bars` only.
    var menuBarBarSources: [MenuBarSource] {
        didSet { defaults.set(menuBarBarSources.map(\.storageKey), forKey: "menuBarBarSources") }
    }
    var menuBarPercentPlacement: MenuBarPercentPlacement {
        didSet { defaults.set(menuBarPercentPlacement.rawValue, forKey: "menuBarPercentPlacement") }
    }
    /// A small colourless vendor mark (Claude/Cursor/Gemini; Codex and Grok Bot fall back to a system glyph
    /// — no freely licensed mark exists for either) drawn ahead of each bar.
    var menuBarShowVendorIcons: Bool {
        didSet { defaults.set(menuBarShowVendorIcons, forKey: "menuBarShowVendorIcons") }
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
    /// Where Claude limits come from: Claude Code login, claude.ai web session (desktop app / Chrome / pasted key), or both.
    var claudeSource: UsageService.ClaudeSource {
        didSet { defaults.set(claudeSource.rawValue, forKey: "claudeSource"); rebuildFetchers() }
    }
    /// Pasted claude.ai session key (kept in our own Keychain item), for people without the desktop app or Chrome.
    var manualClaudeSessionKey: String {
        didSet { ClaudeWebSession.saveManualKey(manualClaudeSessionKey); rebuildFetchers() }
    }
    var claudeCodeAvailable: Bool { ClaudeCredentials.isAvailable() }
    var claudeWebAvailable: Bool { ClaudeWebSession.isAvailable() }

    // MARK: - QuotaVadis's own Claude sign-in
    // The one Claude source that never reads another app's Keychain item, and so the one that never raises the
    // Allow/Deny dialog. One coordinator owns the attempt so the welcome window and Settings show the same one.

    private(set) var claudeOwnLoginActive = ClaudeOwnLogin.isSignedIn
    let claudeSignIn = ClaudeSignInCoordinator { NSWorkspace.shared.open($0) }

    enum ClaudeConnection { case notConnected, connected, reconnectRequired }

    /// "Connected" is a stored login; a login the API has started rejecting asks for Reconnect instead, while
    /// the stored item stays in place until a new sign-in actually replaces it.
    var claudeConnection: ClaudeConnection {
        guard claudeOwnLoginActive else { return .notConnected }
        if case .failed(let error, _) = states["claude"], error == .unauthorized || error == .tokenExpired { return .reconnectRequired }
        return .connected
    }

    /// Existing installs keep whatever source they had; this is the one-time nudge towards an own login.
    var claudeConnectTipDismissed: Bool {
        didSet { defaults.set(claudeConnectTipDismissed, forKey: "claudeConnectTipDismissed") }
    }
    var showClaudeConnectTip: Bool {
        hasOnboarded && !claudeOwnLoginActive && !claudeConnectTipDismissed && enabledProviders.contains(.claude)
    }

    /// The new login is in the Keychain. Pick it up: an explicit web-only choice moves to automatic (own login
    /// first), and the fetchers are rebuilt so the new account replaces whatever was shown before.
    private func claudeDidConnect() {
        claudeOwnLoginActive = true
        ClaudeCredentials.invalidate()
        if claudeSource == .web { claudeSource = .automatic } else { rebuildFetchers() }
    }

    /// Stops using the QuotaVadis login without reaching for another app's: no user-initiated refresh follows,
    /// so nothing here can surface Claude Code's Keychain prompt. Connect again from the same card.
    func signOutClaudeOwnLogin() {
        claudeSignIn.cancel()
        ClaudeOwnLogin.signOut()
        claudeOwnLoginActive = false
        ClaudeCredentials.invalidate()
        rebuildFetchers(userRefresh: false)
    }

    /// Organizations already shown through Claude Code logins; the web path skips them in automatic mode.
    private var coveredOrganizations: Set<String> {
        Set(states.filter { $0.key == "claude" || $0.key.hasPrefix("claude:") }.compactMap { $0.value.snapshot?.organization })
    }

    /// Every caller changes which Claude account(s) are read, so the service drops what it holds for Claude.
    private func rebuildFetchers(userRefresh: Bool = true) {
        let fetchers = UsageService.defaultFetchers(extraClaudeServices: extraClaudeServices, claudeSource: claudeSource,
                                                    coveredOrganizations: coveredOrganizations)
        states = states.filter { key, _ in !key.hasPrefix("claude") }
        pendingWebStates.removeAll()
        Task {
            await service.setFetchers(fetchers, invalidating: [.claude])
            if userRefresh, !applyingOnboarding { await ProviderInteractionContext.$userInitiated.withValue(true) { await refresh() } }
        }
    }

    /// Extra Claude logins (Keychain services of other organizations' Claude Code profiles).
    var extraClaudeServices: [String] {
        didSet {
            defaults.set(extraClaudeServices, forKey: "extraClaudeServices")
            rebuildFetchers()
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
    /// True while the screen is locked: a background refresh here would hit a locked login Keychain and pop
    /// a password prompt with nobody at the machine to answer it, so refreshes are skipped until unlock.
    private var isScreenLocked = false

    init() {
        let stored = defaults.stringArray(forKey: "enabledProviders")?.compactMap(ProviderID.init(rawValue:))
        enabledProviders = stored.map(Set.init) ?? Set(ProviderID.allCases)
        if let seconds = defaults.object(forKey: "refreshIntervalSeconds") as? Int {
            refreshIntervalSeconds = seconds == 0 ? 0 : max(30, seconds)
        } else if let legacyMinutes = defaults.object(forKey: "refreshIntervalMinutes") as? Int {
            refreshIntervalSeconds = max(30, legacyMinutes * 60)   // migrate the pre-0.2 setting
        } else {
            refreshIntervalSeconds = 0   // adaptive by default
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
        menuBarDisplayStyle = MenuBarDisplayStyle(rawValue: defaults.string(forKey: "menuBarDisplayStyle") ?? "") ?? .icon
        menuBarBarSources = defaults.stringArray(forKey: "menuBarBarSources").map { $0.map(MenuBarSource.init(storageKey:)) } ?? [.worst]
        menuBarPercentPlacement = MenuBarPercentPlacement(rawValue: defaults.string(forKey: "menuBarPercentPlacement") ?? "") ?? .beside
        menuBarShowVendorIcons = defaults.bool(forKey: "menuBarShowVendorIcons")
        showPercentInMenuBar = defaults.object(forKey: "showPercentInMenuBar") as? Bool ?? true
        useAppIconInMenuBar = defaults.object(forKey: "useAppIconInMenuBar") as? Bool ?? false
        menuBarExcluded = Set(defaults.stringArray(forKey: "menuBarExcluded") ?? [])
        fastModeAt2x = defaults.bool(forKey: "fastModeAt2x")
        syncEnabled = defaults.object(forKey: "syncEnabled") as? Bool ?? true
        lastSyncPush = defaults.object(forKey: "lastSyncPush") as? Date
        lastSyncError = defaults.string(forKey: "lastSyncError")
        expanded = Set(defaults.stringArray(forKey: "expandedInstances") ?? [])
        extraClaudeServices = defaults.stringArray(forKey: "extraClaudeServices") ?? []
        claudeSource = UsageService.ClaudeSource(rawValue: defaults.string(forKey: "claudeSource") ?? "") ?? .automatic
        manualClaudeSessionKey = ClaudeWebSession.manualKey() ?? ""
        service = UsageService(fetchers: UsageService.defaultFetchers(
            extraClaudeServices: defaults.stringArray(forKey: "extraClaudeServices") ?? [],
            claudeSource: UsageService.ClaudeSource(rawValue: defaults.string(forKey: "claudeSource") ?? "") ?? .automatic))
        hasOnboarded = defaults.bool(forKey: "hasOnboarded")
        claudeConnectTipDismissed = defaults.bool(forKey: "claudeConnectTipDismissed")
        observeScreenLock()
        scheduleRefresh()
        if !syncEnabled && defaults.bool(forKey: "pendingCloudRemoval") { requestSync() }
        // First launch reads nothing until the welcome window is finished (see `refresh`).
        if hasOnboarded { Task { await refresh() } }
        claudeSignIn.onConnected = { [weak self] in self?.claudeDidConnect() }
    }

    /// False until the welcome flow is finished. Until then nothing reads a provider, scans logs or publishes
    /// to iCloud — panel, timers, unlock and Settings callbacks all go through `refresh()`/`refreshCosts()`.
    private(set) var hasOnboarded: Bool
    /// Settings sidebar selection, so the panel can open Settings straight at Accounts.
    var settingsSection: SettingsSection = .general

    /// The welcome window's draft choices, applied in one go.
    /// The setters' own refresh side effects are held back so the one refresh that follows runs under the
    /// user's click (the only kind allowed to show a Keychain dialog) and with the final fetchers.
    func completeOnboarding(providers: Set<ProviderID>, claudeSource source: UsageService.ClaudeSource, sync: Bool) {
        hasOnboarded = true
        defaults.set(true, forKey: "hasOnboarded")
        applyingOnboarding = true
        if enabledProviders != providers { enabledProviders = providers }
        if claudeSource != source { claudeSource = source }
        if syncEnabled != sync { syncEnabled = sync }
        // Choosing Claude Code's login in the welcome flow was informed; the panel's nudge is for older installs.
        if source == .claudeCode { claudeConnectTipDismissed = true }
        let fetchers = UsageService.defaultFetchers(extraClaudeServices: extraClaudeServices, claudeSource: claudeSource)
        Task {
            await service.setFetchers(fetchers, invalidating: [.claude])
            applyingOnboarding = false
            await ProviderInteractionContext.$userInitiated.withValue(true) {
                await refresh()
                await refreshCosts()
            }
        }
    }

    private var applyingOnboarding = false

    // MARK: - Command line tool

    static let cliLinkPath = "/usr/local/bin/quotavadis"
    var cliBundledURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/quotavadis-cli")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
    var cliInstalled: Bool {
        guard let target = cliBundledURL, let link = try? FileManager.default.destinationOfSymbolicLink(atPath: Self.cliLinkPath) else { return false }
        return link == target.path
    }
    var cliInstallMessage: String?

    /// Symlinks the bundled CLI into /usr/local/bin (asks for an administrator password once).
    func installCLI() {
        guard let target = cliBundledURL else { cliInstallMessage = "This build does not bundle the command line tool."; return }
        let script = "mkdir -p /usr/local/bin && ln -sf '\(target.path)' '\(Self.cliLinkPath)'"
        let apple = "do shell script \"\(script.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: apple)?.executeAndReturnError(&error)
        cliInstallMessage = error == nil ? "Installed: run `quotavadis` in Terminal." : "Not installed: \(error?[NSAppleScript.errorMessage] ?? "cancelled")"
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

    /// Instances in display order: primary Claude, extra Claude logins, Codex, Cursor. A provider with no
    /// detected login and no cached data from an earlier successful fetch stays out of sight entirely —
    /// Settings ▸ Track is where an unused tool gets discovered and turned on, not the main panel.
    var visibleInstances: [Instance] {
        var out: [Instance] = []
        for provider in ProviderID.allCases where enabledProviders.contains(provider) {
            var ids: [String] = [provider.rawValue]
            if provider == .claude {
                let useClaudeCode = claudeSource == .claudeCode || (claudeSource == .automatic && (claudeOwnLoginActive || claudeCodeAvailable))
                ids = useClaudeCode ? ["claude"] + extraClaudeServices.map { "claude:" + Self.suffix($0) } : []
                let web = states.keys.filter { $0.hasPrefix("claude-web:") }.sorted()
                ids += web
            } else if !isDetected(provider) && states[provider.rawValue] == nil {
                ids = []
            }
            for id in ids { out.append(Instance(id: id, provider: provider)) }
        }
        return out
    }

    /// Cheap, no-UI presence check (installed/logged in) — not a full credential load like `CredentialStatus`,
    /// which is reserved for Settings since it can touch the Keychain for real data.
    private func isDetected(_ provider: ProviderID) -> Bool {
        switch provider {
        case .claude: return claudeOwnLoginActive || claudeCodeAvailable || claudeWebAvailable
        case .codex: return CodexUsageFetcher().isAvailable()
        case .cursor: return CursorUsageFetcher().isAvailable()
        case .gemini: return AntigravityUsageFetcher().isAvailable()
        }
    }

    var worstPercent: Double? {
        visibleInstances.compactMap { states[$0.id]?.snapshot?.worstWindow?.usedPercent }.max()
    }

    /// The number shown in the menu bar, per the user's `menuBarSource` choice.
    var menuBarPercent: Double? { percent(for: menuBarSource) }
    var menuBarMeasurement: (snapshot: UsageSnapshot, window: UsageWindow)? { measurement(for: menuBarSource) }
    var menuBarIsStale: Bool { isStale(for: menuBarSource) }
    var menuBarAccessibilityLabel: String {
        guard percent(for: menuBarSource) != nil else { return "QuotaVadis, no usage data. Open to set up tools." }
        return accessibilityLabel(for: menuBarSource)
    }

    /// `.bars` style: one reading per bar, in order.
    var menuBarBarPercents: [Double?] { menuBarBarSources.map { percent(for: $0) } }
    var menuBarBarVendorIcons: [MenuBarVendorMark?] { menuBarBarSources.map { vendorIcon(for: $0) } }
    /// Drawn smaller: a visual cue that this bar's window is the short one (session/5h) when a same-provider
    /// pair of bars (e.g. Claude 5h + Claude weekly) would otherwise show two identical marks.
    var menuBarBarIconIsShortWindow: [Bool] { menuBarBarSources.map { measurement(for: $0)?.window.kind == .session } }
    var menuBarBarIsStale: Bool { menuBarBarSources.contains { isStale(for: $0) } }
    var menuBarBarAccessibilityLabel: String {
        menuBarBarSources.map { accessibilityLabel(for: $0) }.joined(separator: "; ")
    }

    private func measurement(for source: MenuBarSource) -> (snapshot: UsageSnapshot, window: UsageWindow)? {
        switch source {
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
        case .window(let id, let windowID):
            guard let snapshot = states[id]?.snapshot, let window = snapshot.windows.first(where: { $0.id == windowID }) else { return nil }
            return (snapshot, window)
        case .spend:
            return nil
        }
    }

    /// Spend (Claude "Extra usage", Cursor usage-based cost) as a percent of its cap; nil without a cap.
    private func spendPercent(for id: String) -> Double? { states[id]?.snapshot?.credits.first?.usedPercent }

    private func percent(for source: MenuBarSource) -> Double? {
        if case .spend(let id) = source { return spendPercent(for: id) }
        return measurement(for: source)?.window.usedPercent
    }

    /// A mark to draw ahead of a bar. Claude/Cursor/Gemini use bundled colourless template marks (CC0-licensed,
    /// see Apps/Mac/Resources/Assets.xcassets). Grok Bot prefers the real, full-colour icon of the "Grok Bot"
    /// app when it's installed locally — reading an already-installed app's own `.icns` isn't redistributing
    /// anything, unlike bundling a copy of a mark neither OpenAI nor xAI license freely — falling back to a
    /// hand-drawn original shape when it isn't. Codex has no local app to read an icon from, so it stays a
    /// plain SF Symbol.
    private func vendorIcon(for source: MenuBarSource) -> MenuBarVendorMark? {
        if case .window(_, let windowID) = source, windowID == "grok-bot" {
            if let real = Self.installedAppIcon("Grok Bot") { return MenuBarVendorMark(image: Self.desaturated(real), isTemplate: false) }
            return MenuBarVendorMark(image: OriginalVendorIcons.grok, isTemplate: true)
        }
        guard let id = instanceID(for: source), let provider = states[id]?.snapshot?.provider else { return nil }
        switch provider {
        case .claude: return NSImage(named: "VendorClaude").map { MenuBarVendorMark(image: $0, isTemplate: true) }
        case .cursor: return NSImage(named: "VendorCursor").map { MenuBarVendorMark(image: $0, isTemplate: true) }
        case .gemini: return NSImage(named: "VendorGemini").map { MenuBarVendorMark(image: $0, isTemplate: true) }
        case .codex: return NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "Codex").map { MenuBarVendorMark(image: $0, isTemplate: true) }
        }
    }

    /// `.icns` of a locally installed app, read straight off disk — never bundled or redistributed.
    private static func installedAppIcon(_ appName: String) -> NSImage? {
        for base in ["/Applications", NSHomeDirectory() + "/Applications"] {
            let path = "\(base)/\(appName).app"
            if FileManager.default.fileExists(atPath: path) { return NSWorkspace.shared.icon(forFile: path) }
        }
        return nil
    }

    /// Desaturates a real app icon to grayscale so it reads as "colourless" like the other marks, while
    /// keeping its actual shape/shading detail — unlike tinting via its (rounded-square) alpha shape, which
    /// would just draw a plain rounded square and lose everything that makes the icon recognisable.
    private static func desaturated(_ icon: NSImage) -> NSImage {
        guard let tiff = icon.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let cgImage = bitmap.cgImage,
              let filter = CIFilter(name: "CIColorMonochrome") else { return icon }
        filter.setValue(CIImage(cgImage: cgImage), forKey: kCIInputImageKey)
        filter.setValue(CIColor(red: 0.5, green: 0.5, blue: 0.5), forKey: kCIInputColorKey)
        filter.setValue(1.0, forKey: kCIInputIntensityKey)
        guard let output = filter.outputImage else { return icon }
        let result = NSImage(size: icon.size)
        result.addRepresentation(NSCIImageRep(ciImage: output))
        return result
    }

    private func instanceID(for source: MenuBarSource) -> String? {
        switch source {
        case .worst: return measurement(for: .worst)?.snapshot.instanceID
        case .provider(let id, _), .spend(let id), .window(let id, _): return id
        }
    }

    private func isStale(for source: MenuBarSource) -> Bool {
        guard let id = instanceID(for: source) else { return false }
        let provider = states[id]?.snapshot?.provider ?? ProviderID.allCases.first { id.hasPrefix($0.rawValue) } ?? .claude
        return ProviderSyncStatus(instanceID: id, provider: provider, state: states[id] ?? .unavailable, lastAttemptAt: nil,
                                  refreshInterval: TimeInterval(refreshIntervalSeconds)).freshness() != .fresh
    }

    private func accessibilityLabel(for source: MenuBarSource) -> String {
        if case .spend(let id) = source {
            guard let snapshot = states[id]?.snapshot, let credits = snapshot.credits.first else { return "\(id), no spend data." }
            return "\(snapshot.provider.displayName), \(credits.title), \(Int((credits.usedPercent ?? 0).rounded())) percent of cap used"
        }
        guard let measurement = measurement(for: source) else { return "No usage data." }
        return "\(measurement.snapshot.provider.displayName), \(measurement.window.title), \(Int(measurement.window.usedPercent.rounded())) percent used, " +
            "\(isStale(for: source) ? "stale measurement" : "fresh measurement")"
    }

    func title(for instance: Instance) -> String {
        guard instance.provider == .claude, instance.id != "claude" else { return instance.provider.displayName }
        let base = instance.id.hasPrefix("claude-web") ? "Claude" : instance.provider.displayName
        guard let org = states[instance.id]?.snapshot?.organization else { return base }
        return "\(base) · \(org)"
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
            if let credits = snapshot?.credits.first, credits.limit != nil {
                options.append((.spend(instance.id), "\(name) · \(credits.title)"))
            }
            // Any window beyond primary/secondary (Cursor's Grok Bot, Claude's per-model Sonnet/Opus weekly
            // windows) is otherwise unreachable — primary/secondary only ever resolve to one window each.
            let extras = (snapshot?.windows ?? []).filter { $0.id != snapshot?.primaryWindow?.id && $0.id != snapshot?.secondaryWindow?.id }
            for w in extras { options.append((.window(instance.id, windowID: w.id), "\(name) · \(w.title)")) }
        }
        return options
    }

    /// `.bars` style holds 1–4; a picker binds to `barSource(at:)`/`setBarSource(_:at:)`.
    static let maxBars = 4
    func barSource(at index: Int) -> MenuBarSource { menuBarBarSources.indices.contains(index) ? menuBarBarSources[index] : .worst }
    func setBarSource(_ source: MenuBarSource, at index: Int) {
        var sources = menuBarBarSources
        while sources.count <= index { sources.append(.worst) }
        sources[index] = source
        menuBarBarSources = Array(sources.prefix(Self.maxBars))
    }
    func addBar() { if menuBarBarSources.count < Self.maxBars { menuBarBarSources.append(.worst) } }
    func removeBar(at index: Int) { if menuBarBarSources.count > 1 { menuBarBarSources.remove(at: index) } }

    /// com.apple.screenIsLocked/Unlocked fire for both the screensaver lock and the login window after sleep.
    private func observeScreenLock() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.isScreenLocked = true
        }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isScreenLocked else { return }
            self.isScreenLocked = false
            Task { @MainActor in await self.refresh() }
        }
    }

    func refresh() async {
        guard hasOnboarded, !isScreenLocked else { return }
        guard !isRefreshing else { refreshAgain = true; return }
        isRefreshing = true
        defer {
            isRefreshing = false
            // A plain `Task { }` here would inherit whatever ProviderInteractionContext this refresh() call
            // happened to run under (e.g. a genuinely user-initiated one) — but a call arriving while busy and
            // getting coalesced into "run me again after" is not itself a fresh user action.
            if refreshAgain { refreshAgain = false; Task { await ProviderInteractionContext.$userInitiated.withValue(false) { await refresh() } } }
        }
        for instance in visibleInstances { lastAttempts[instance.id] = .now }
        let result = await service.refresh(enabled: enabledProviders) { [weak self] id, state in
            await self?.received(id: id, state: state)
        }
        // claude-web rows were held back in `pendingWebStates` while streaming (see `received`) precisely so
        // they land already deduped, in the same tick as this cleanup — never shown then yanked a moment later.
        for (id, state) in pendingWebStates { states[id] = state }
        pendingWebStates.removeAll()
        updateWidgets()
        // Drop web rows the service discarded (same organization as a Claude Code login) and any web rows
        // that disappeared from this refresh.
        for key in states.keys where key.hasPrefix("claude-web:") && result[key] == nil { states[key] = nil }
        let covered = Set(states.filter { $0.key == "claude" || $0.key.hasPrefix("claude:") }.compactMap { $0.value.snapshot?.organization })
        for (key, state) in states where key.hasPrefix("claude-web:") {
            if let org = state.snapshot?.organization, covered.contains(org) { states[key] = nil }
        }
        lastRefresh = .now
        notifyIfNeeded()
        schedulePublish()
        if isAdaptiveRefresh { scheduleRefresh() }
        if lastCostRefresh.map({ !Calendar.current.isDateInToday($0) || Date.now.timeIntervalSince($0) > costInterval }) ?? true {
            Task { await refreshCosts() }
        }
    }

    /// Claude Code's own row is usually slower to fetch than claude.ai's cookie/session read, so streaming a
    /// claude-web row in immediately used to flash a duplicate "Claude" row that a moment later turned out to
    /// be the same organization and got removed. Hold web rows back until `refresh()` knows the final set.
    private var pendingWebStates: [String: ProviderState] = [:]

    private func received(id: String, state: ProviderState) {
        if id.hasPrefix("claude-web:") { pendingWebStates[id] = state; return }
        states[id] = state
        updateWidgets()
        schedulePublish()
    }

    func refreshCosts() async {
        guard hasOnboarded, !isRefreshingCosts else { return }
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
        guard hasOnboarded else { return }
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
                                             state: states[$0.id] ?? .unavailable, lastAttemptAt: lastAttempts[$0.id],
                                             refreshInterval: TimeInterval(refreshIntervalSeconds))
                      })
    }

    /// Widgets on this Mac read the App Group file; no iCloud round trip.
    private func updateWidgets() {
        SharedStore.write(currentPayload)
        widgetHandoffError = SharedStore.lastError
        widgetHandoffWrittenAt = SharedStore.lastWriteAt
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Why the last hand-off to the widgets failed, nil when it worked. Shown in Settings ▸ iCloud & Updates.
    private(set) var widgetHandoffError: String? = SharedStore.lastError
    private(set) var widgetHandoffWrittenAt: Date? = SharedStore.lastWriteAt

    /// Settings button: rewrite the file and ask WidgetKit to reload, without a full provider refresh.
    func refreshWidgetsNow() { updateWidgets() }

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
                guard hasOnboarded else { return }
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

    /// Fixed cadence: repeating timer. Adaptive: one-shot timer re-armed after every tick with the policy's delay.
    private func scheduleRefresh() {
        timer?.invalidate()
        if isAdaptiveRefresh {
            let input = AdaptiveRefreshPolicy.Input(
                lastPanelOpen: lastPanelOpen,
                lastCodingActivity: ActivityProbe.lastCodingActivity(),
                lowPowerOrHot: ProcessInfo.processInfo.isLowPowerModeEnabled || [.serious, .critical].contains(ProcessInfo.processInfo.thermalState))
            let (delay, reason) = AdaptiveRefreshPolicy.next(input)
            adaptiveReason = reason
            nextRefreshAt = .now.addingTimeInterval(delay)
            timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
                Task { @MainActor in await self.refresh() }
            }
            timer?.tolerance = min(60, delay / 10)
        } else {
            adaptiveReason = nil
            nextRefreshAt = .now.addingTimeInterval(TimeInterval(refreshIntervalSeconds))
            timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(refreshIntervalSeconds), repeats: true) { _ in
                Task { @MainActor in await self.refresh() }
            }
            timer?.tolerance = min(30, TimeInterval(refreshIntervalSeconds) / 6)
        }
    }

    /// The panel was opened: remember it for the adaptive policy and refresh if the numbers are older than 30 s.
    func panelOpened() {
        guard hasOnboarded else { return }
        lastPanelOpen = .now
        if isAdaptiveRefresh { scheduleRefresh() }
        if lastRefresh.map({ Date.now.timeIntervalSince($0) > 30 }) ?? true { refreshNow() }
    }

    /// The user explicitly asked for fresh numbers (the panel's Refresh button) — unlike a timer tick, this
    /// is free to touch the Keychain for real and show the OS prompt if it's genuinely needed.
    func refreshNow() {
        Task { await ProviderInteractionContext.$userInitiated.withValue(true) { await refresh(); await refreshCosts() } }
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
