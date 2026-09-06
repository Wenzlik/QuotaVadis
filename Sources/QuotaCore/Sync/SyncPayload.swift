import Foundation

/// Everything one Mac publishes to iCloud: its latest snapshots and cost reports. Derived numbers only,
/// never credentials. One record per device, whole payload replaced on every publish.
public struct DevicePayload: Codable, Sendable, Hashable, Identifiable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var deviceID: String
    public var deviceName: String
    public var snapshots: [UsageSnapshot]
    public var costs: [CostReport]
    public var updatedAt: Date

    public var id: String { deviceID }

    public init(deviceID: String, deviceName: String, snapshots: [UsageSnapshot], costs: [CostReport], updatedAt: Date = .now) {
        self.schemaVersion = Self.schemaVersion
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.snapshots = snapshots
        self.costs = costs
        self.updatedAt = updatedAt
    }

    public func snapshot(for provider: ProviderID) -> UsageSnapshot? { snapshots.first { $0.provider == provider } }
    public func cost(for provider: ProviderID) -> CostReport? { costs.first { $0.provider == provider } }

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
