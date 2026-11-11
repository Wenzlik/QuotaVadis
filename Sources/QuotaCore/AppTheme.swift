import Foundation

/// The visual theme picked in Settings. `auto` is resolved per render from the snapshots the app already has
/// (see `resolved(for:)`); every other case is a manual choice and always wins over Auto.
public enum AppTheme: String, CaseIterable, Codable, Sendable {
    case auto, standard, observatory, goodLimits

    /// Key in the app's own defaults and, mirrored, in the App Group suite the widgets read.
    public static let storageKey = "appTheme"
    /// The pre-picker Observatory toggle. Read only for the one-time migration.
    public static let legacyObservatoryKey = "observatoryModeEnabled"

    public var displayName: String {
        switch self {
        case .auto: "Auto"
        case .standard: "Default"
        case .observatory: "Observatory"
        case .goodLimits: "GoodLimits.ai"
        }
    }

    /// The theme to draw. Never `.auto`: Auto becomes GoodLimits.ai when any snapshot belongs to a GoodData
    /// account, the default look otherwise.
    public func resolved(for snapshots: [UsageSnapshot]) -> AppTheme {
        guard self == .auto else { return self }
        return GoodDataAccountDetector.isGoodData(snapshots) ? .goodLimits : .standard
    }

    /// Whether the GoodLimits.ai app icon should show. nil = no evidence yet (Auto with nothing read, e.g. at launch
    /// or while a refresh empties the list): keep whatever icon is showing, so it does not flip back and forth.
    public func wantsGoodLimitsIcon(for snapshots: [UsageSnapshot]) -> Bool? {
        if self == .auto && snapshots.isEmpty { return nil }
        return resolved(for: snapshots) == .goodLimits
    }

    /// The stored choice. No choice yet: whoever had turned the old Observatory toggle on keeps Observatory,
    /// everyone else gets Auto.
    public static func stored(in defaults: UserDefaults) -> AppTheme {
        if let raw = defaults.string(forKey: storageKey), let theme = AppTheme(rawValue: raw) { return theme }
        return defaults.bool(forKey: legacyObservatoryKey) ? .observatory : .auto
    }

    /// Writes the migrated choice once, so `@AppStorage(AppTheme.storageKey)` sees it, and returns it.
    @discardableResult
    public static func migrate(_ defaults: UserDefaults) -> AppTheme {
        let theme = stored(in: defaults)
        if defaults.string(forKey: storageKey) != theme.rawValue { defaults.set(theme.rawValue, forKey: storageKey) }
        return theme
    }
}

/// Recognises a GoodData account from identity QuotaVadis already reads (`UsageSnapshot.account` email,
/// `UsageSnapshot.organization` name). No network calls of its own.
public enum GoodDataAccountDetector {
    static let emailDomain = "gooddata.com"
    static let organizationNames: Set<String> = ["gooddata", "gooddata.ai"]

    /// `…@gooddata.com` or any subdomain of it, case-insensitive. Lookalikes such as `gooddata.com.evil.io`,
    /// `notgooddata.com` or `gooddata.ai` do not match.
    public static func isGoodDataEmail(_ email: String?) -> Bool {
        guard let email = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let at = email.lastIndex(of: "@"), at != email.startIndex else { return false }
        var domain = String(email[email.index(after: at)...])
        if domain.hasSuffix(".") { domain.removeLast() }   // fully qualified form "gooddata.com."
        guard !domain.isEmpty, !domain.split(separator: ".", omittingEmptySubsequences: false).contains("") else { return false }
        return domain == emailDomain || domain.hasSuffix("." + emailDomain)
    }

    /// Exactly "GoodData" or "GoodData.AI" (any case, surrounding whitespace ignored). Not a substring match.
    public static func isGoodDataOrganization(_ name: String?) -> Bool {
        guard let name else { return false }
        return organizationNames.contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// One snapshot of any provider is enough.
    public static func isGoodData(_ snapshots: [UsageSnapshot]) -> Bool {
        snapshots.contains { isGoodDataEmail($0.account) || isGoodDataOrganization($0.organization) }
    }
}
