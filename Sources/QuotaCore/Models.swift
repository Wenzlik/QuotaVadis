import Foundation

/// The three tools QuotaVadis tracks. Raw values are stable identifiers used in sync records.
public enum ProviderID: String, Codable, CaseIterable, Sendable, Identifiable {
    case claude, codex, cursor, antigravity

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .antigravity: "Antigravity"
        }
    }

    /// Short label for tight spaces (widget tabs).
    public var shortName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .antigravity: "AG"
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
    /// Distinguishes several logins of one provider (e.g. two Claude organizations). Defaults to the provider id.
    public var instanceID: String
    public var account: String?
    /// Organization / workspace name when the provider has one (Claude org, Codex workspace).
    public var organization: String?
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

    public var id: String { "\(deviceName)/\(instanceID)" }

    public init(provider: ProviderID, instanceID: String? = nil, account: String?, organization: String? = nil, plan: String?, seat: String? = nil, windows: [UsageWindow], credits: [UsageCredits] = [], resetCreditsAvailable: Int? = nil, resetCreditExpiries: [Date] = [], fetchedAt: Date = .now, deviceName: String = DeviceInfo.name) {
        self.provider = provider
        self.instanceID = instanceID ?? provider.rawValue
        self.organization = organization
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

    enum CodingKeys: String, CodingKey {
        case provider, instanceID, account, organization, plan, seat, windows, credits, resetCreditsAvailable, resetCreditExpiries, fetchedAt, deviceName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(ProviderID.self, forKey: .provider)
        instanceID = try c.decodeIfPresent(String.self, forKey: .instanceID) ?? provider.rawValue
        account = try c.decodeIfPresent(String.self, forKey: .account)
        organization = try c.decodeIfPresent(String.self, forKey: .organization)
        plan = try c.decodeIfPresent(String.self, forKey: .plan)
        seat = try c.decodeIfPresent(String.self, forKey: .seat)
        windows = try c.decodeIfPresent([UsageWindow].self, forKey: .windows) ?? []
        credits = try c.decodeIfPresent([UsageCredits].self, forKey: .credits) ?? []
        resetCreditsAvailable = try c.decodeIfPresent(Int.self, forKey: .resetCreditsAvailable)
        resetCreditExpiries = try c.decodeIfPresent([Date].self, forKey: .resetCreditExpiries) ?? []
        fetchedAt = try c.decodeIfPresent(Date.self, forKey: .fetchedAt) ?? .now
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? ""
    }

    /// Header subtitle: organization, plan and seat in one line.
    public var subtitle: String? {
        let parts = [organization, plan, seat].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
    case appNotRunning

    public var errorDescription: String? {
        switch self {
        case .notInstalled: "Not installed on this Mac"
        case .notLoggedIn: "Not logged in"
        case .tokenExpired: "Session expired. Open the tool once so it refreshes its login"
        case .unauthorized: "Token rejected, log in again"
        case .rateLimited: "Usage API is rate limited, retrying later"
        case .http(let code): "HTTP \(code)"
        case .decoding(let why): "Unexpected response: \(why)"
        case .network(let why): "Network: \(why)"
        case .keychainDenied: "Keychain access denied. Click Refresh and choose Always Allow"
        case .appNotRunning: "Open the app once; its quota is only readable while it runs"
        }
    }
}

public protocol UsageFetcher: Sendable {
    var provider: ProviderID { get }
    /// Unique per login; equals `provider.rawValue` for the primary instance.
    var instanceID: String { get }
    /// True when the tool's credentials exist on this machine. Cheap; no network.
    func isAvailable() -> Bool
    func fetch() async throws -> UsageSnapshot
    /// Raw API response, for debugging shapes with `quotactl --raw`.
    func fetchRaw() async throws -> Data
}

public extension UsageFetcher {
    var instanceID: String { provider.rawValue }
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

public extension Date {
    /// "in 1 hr · 14:35" — relative distance plus the exact clock time; adds the weekday when it is not today,
    /// and the date when it is more than a week away.
    func resetLabel(now: Date = .now, calendar: Calendar = .current) -> String {
        let relative = formatted(.relative(presentation: .numeric))
        let exact: String
        if calendar.isDate(self, inSameDayAs: now) {
            exact = formatted(date: .omitted, time: .shortened)
        } else if let week = calendar.date(byAdding: .day, value: 7, to: now), self < week {
            exact = formatted(.dateTime.weekday(.abbreviated).hour().minute())
        } else {
            exact = formatted(.dateTime.day().month(.abbreviated).hour().minute())
        }
        return "\(relative) · \(exact)"
    }
}
