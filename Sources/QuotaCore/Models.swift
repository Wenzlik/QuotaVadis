import Foundation

/// The three tools QuotaVadis tracks. Raw values are stable identifiers used in sync records.
public enum ProviderID: String, Codable, CaseIterable, Sendable, Identifiable {
    case claude, codex, cursor

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }
}

/// One rate-limit window: "session 5h", "weekly", "monthly plan", ...
public struct UsageWindow: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case session, weekly, monthly, model, credits
    }

    public var id: String
    public var kind: Kind
    public var title: String
    /// 0...100. Values above 100 are clamped by the UI, not here.
    public var usedPercent: Double
    public var resetsAt: Date?
    /// Shown in the collapsed row. False for breakdown sub-windows (Cursor Auto/Other, Codex extra limits).
    public var prominent: Bool

    public init(id: String, kind: Kind, title: String, usedPercent: Double, resetsAt: Date?, prominent: Bool = true) {
        self.id = id
        self.kind = kind
        self.title = title
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.prominent = prominent
    }

    public var remainingPercent: Double { max(0, 100 - usedPercent) }

    /// Classifies a rolling window by its length: up to 6 hours is a session, around a week is weekly.
    public static func kind(forSeconds seconds: Int) -> Kind {
        switch seconds {
        case ...(6 * 3600): .session
        case ...(8 * 86400): .weekly
        default: .monthly
        }
    }
}

/// Everything the UI needs for one provider at one point in time. This is also the unit of iCloud sync.
public struct UsageSnapshot: Codable, Sendable, Hashable, Identifiable {
    public var provider: ProviderID
    public var account: String?
    public var plan: String?
    /// The seat/tier assigned to this user inside the plan, e.g. "Premium seat · Max 5x".
    public var seat: String?
    public var windows: [UsageWindow]
    public var credits: [UsageCredits]
    /// Codex: number of rate-limit resets the user can still redeem. nil when the provider has no such concept.
    public var resetCreditsAvailable: Int?
    /// Codex: expiry of each available reset credit, soonest first.
    public var resetCreditExpiries: [Date]
    public var fetchedAt: Date
    public var deviceName: String

    public var id: String { "\(deviceName)/\(provider.rawValue)" }

    public init(provider: ProviderID, account: String?, plan: String?, seat: String? = nil, windows: [UsageWindow], credits: [UsageCredits] = [], resetCreditsAvailable: Int? = nil, resetCreditExpiries: [Date] = [], fetchedAt: Date = .now, deviceName: String = DeviceInfo.name) {
        self.provider = provider
        self.account = account
        self.plan = plan
        self.seat = seat
        self.windows = windows
        self.credits = credits
        self.resetCreditsAvailable = resetCreditsAvailable
        self.resetCreditExpiries = resetCreditExpiries
        self.fetchedAt = fetchedAt
        self.deviceName = deviceName
    }

    /// The window that matters most right now: highest utilization.
    public var worstWindow: UsageWindow? { windows.max { $0.usedPercent < $1.usedPercent } }
    public var primaryWindow: UsageWindow? { windows.first { $0.kind == .session } ?? windows.first }
    public var secondaryWindow: UsageWindow? { windows.first { $0.kind == .weekly || $0.kind == .monthly } }
}

public enum DeviceInfo {
    public static var name: String {
        #if os(macOS)
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }
}

/// Why a provider has no fresh data. Every case has a one-line user-facing explanation.
public enum ProviderError: Error, LocalizedError, Sendable, Hashable {
    case notInstalled
    case notLoggedIn
    case tokenExpired
    case unauthorized
    case rateLimited
    case http(Int)
    case decoding(String)
    case network(String)
    case keychainDenied

    public var errorDescription: String? {
        switch self {
        case .notInstalled: "Not installed on this Mac"
        case .notLoggedIn: "Not logged in"
        case .tokenExpired: "Session expired, open the tool once to refresh"
        case .unauthorized: "Token rejected, log in again"
        case .rateLimited: "Usage API is rate limited, retrying later"
        case .http(let code): "HTTP \(code)"
        case .decoding(let why): "Unexpected response: \(why)"
        case .network(let why): "Network: \(why)"
        case .keychainDenied: "Keychain access denied. Click Refresh and choose Always Allow"
        }
    }
}

public protocol UsageFetcher: Sendable {
    var provider: ProviderID { get }
    /// True when the tool's credentials exist on this machine. Cheap; no network.
    func isAvailable() -> Bool
    func fetch() async throws -> UsageSnapshot
    /// Raw API response, for debugging shapes with `quotactl --raw`.
    func fetchRaw() async throws -> Data
}

/// Money-style quota: how much was spent against a limit (extra usage, on-demand, credits).
public struct UsageCredits: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var used: Double
    /// nil = no cap (pay as you go / unlimited).
    public var limit: Double?
    public var currency: String
    public var resetsAt: Date?

    public init(id: String, title: String, used: Double, limit: Double?, currency: String = "USD", resetsAt: Date? = nil) {
        self.id = id
        self.title = title
        self.used = used
        self.limit = limit
        self.currency = currency
        self.resetsAt = resetsAt
    }

    public var usedPercent: Double? {
        guard let limit, limit > 0 else { return nil }
        return used / limit * 100
    }
}
