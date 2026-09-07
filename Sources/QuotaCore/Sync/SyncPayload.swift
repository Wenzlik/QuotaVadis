import Foundation

/// Everything one Mac publishes to iCloud: its latest snapshots and cost reports. Usage, costs and account/project metadata,
/// never credentials. One record per device, whole payload replaced on every publish.
public struct DevicePayload: Codable, Sendable, Hashable, Identifiable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var deviceID: String
    public var deviceName: String
    public var snapshots: [UsageSnapshot]
    public var costs: [CostReport]
    public var providerStatuses: [ProviderSyncStatus]?
    /// Time of transfer, not the time of measurement.
    public var updatedAt: Date

    public var id: String { deviceID }

    public init(deviceID: String, deviceName: String, snapshots: [UsageSnapshot], costs: [CostReport], providerStatuses: [ProviderSyncStatus]? = nil, updatedAt: Date = .now) {
        self.schemaVersion = Self.schemaVersion
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.snapshots = snapshots
        self.costs = costs
        self.providerStatuses = providerStatuses
        self.updatedAt = updatedAt
    }

    public func snapshot(for provider: ProviderID) -> UsageSnapshot? { snapshots.first { $0.provider == provider } }
    public func cost(for provider: ProviderID) -> CostReport? { costs.first { $0.provider == provider } }

    /// Old payloads still use the original measurement date; publication never makes them fresh.
    public func status(for snapshot: UsageSnapshot) -> ProviderSyncStatus {
        providerStatuses?.first { $0.instanceID == snapshot.instanceID } ??
            ProviderSyncStatus(instanceID: snapshot.instanceID, provider: snapshot.provider,
                               state: .fresh(snapshot), lastAttemptAt: nil)
    }

    public var freshSnapshots: [UsageSnapshot] {
        snapshots.filter { status(for: $0).freshness() == .fresh }
    }

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    public func encoded() throws -> Data { try Self.encoder.encode(self) }
    public static func decode(_ data: Data) throws -> DevicePayload { try decoder.decode(DevicePayload.self, from: data) }
}

/// Stable per-install identifier, kept in UserDefaults so a reinstall on the same Mac keeps its record.
public enum DeviceIdentity {
    static let key = "cz.zmrhal.QuotaVadis.deviceID"
    public static var id: String {
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }
}

public enum SyncPrivacy {
    public static let summary = "Optional iCloud sync sends usage limits, reset times, cost estimates, account email, organization and plan, Mac name, and project names and full paths to your private iCloud database. Login credentials and raw logs are not synced."
}
