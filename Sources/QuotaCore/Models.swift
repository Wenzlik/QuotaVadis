import Foundation

/// The three tools QuotaBar tracks. Raw values are stable identifiers used in sync records.
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

    public init(id: String, kind: Kind, title: String, usedPercent: Double, resetsAt: Date?) {
        self.id = id
        self.kind = kind
        self.title = title
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Double { max(0, 100 - usedPercent) }
}

/// Everything the UI needs for one provider at one point in time. This is also the unit of iCloud sync.
public struct UsageSnapshot: Codable, Sendable, Hashable, Identifiable {
    public var provider: ProviderID
    public var account: String?
    public var plan: String?
    public var windows: [UsageWindow]
    public var fetchedAt: Date
    public var deviceName: String

    public var id: String { "\(deviceName)/\(provider.rawValue)" }

    public init(provider: ProviderID, account: String?, plan: String?, windows: [UsageWindow], fetchedAt: Date = .now, deviceName: String = DeviceInfo.name) {
        self.provider = provider
        self.account = account
        self.plan = plan
        self.windows = windows
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
        case .keychainDenied: "Keychain access denied"
        }
    }
}

public protocol UsageFetcher: Sendable {
    var provider: ProviderID { get }
    /// True when the tool's credentials exist on this machine. Cheap; no network.
    func isAvailable() -> Bool
    func fetch() async throws -> UsageSnapshot
}
