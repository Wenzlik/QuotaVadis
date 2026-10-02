import Foundation

/// A read-only panel summary. Quota/credit readings are account-wide; local log costs are additive.
/// No merged payload is published back to iCloud.
public struct CombinedUsage {
    public struct Reading: Identifiable {
        public var id: String { "\(deviceID)/\(snapshot.instanceID)" }
        public let deviceID: String
        public let deviceName: String
        public let snapshot: UsageSnapshot
        public let status: ProviderSyncStatus
    }

    public struct CostTotal: Identifiable {
        public var id: ProviderID { provider }
        public let provider: ProviderID
        public var tokens = 0
        public var costUSD = 0.0
        public var reports = 0
    }

    public let devices: [DevicePayload]
    public let readings: [Reading]
    public let costs: [CostTotal]
    public let unidentifiedCursorReports: Int

    private struct AccountKey: Hashable {
        let provider: ProviderID
        let account: String
        let organization: String?
        let unknownInstance: String?
    }

    public init(devices: [DevicePayload], now: Date = .now) {
        // Keep one payload per installation; callers put the live local payload first.
        var seen = Set<String>()
        self.devices = devices.filter { seen.insert($0.deviceID).inserted }
        var latest: [AccountKey: Reading] = [:]
        var localCosts: [CostReport] = []
        var cursorCosts: [String: CostReport] = [:]
        var unidentified = 0
        for device in self.devices {
            for snapshot in device.snapshots {
                let account = Self.account(snapshot.account)
                // ponytail: organization names identify workspaces in schema v1; use stable account/org IDs if added to the payload.
                let key = AccountKey(provider: snapshot.provider, account: account ?? device.deviceID,
                                     organization: snapshot.organization,
                                     unknownInstance: account == nil ? snapshot.instanceID : nil)
                if latest[key].map({ $0.snapshot.fetchedAt >= snapshot.fetchedAt }) != true {
                    latest[key] = Reading(deviceID: device.deviceID, deviceName: device.deviceName,
                                          snapshot: snapshot, status: device.status(for: snapshot))
                }
            }
            for report in device.costs {
                switch report.provider {
                case .claude, .codex:
                    // ponytail: assumes separate local logs; mirrored log directories need event IDs before summing safely.
                    localCosts.append(report)
                case .cursor:
                    guard let account = Self.account(device.snapshot(for: .cursor)?.account) else {
                        unidentified += 1
                        continue
                    }
                    if cursorCosts[account].map({ $0.generatedAt >= report.generatedAt }) != true {
                        cursorCosts[account] = report
                    }
                case .gemini: break // No device-local cost source exists for Gemini.
                }
            }
        }
        readings = latest.values.sorted {
            if $0.snapshot.provider != $1.snapshot.provider { return $0.snapshot.provider.rawValue < $1.snapshot.provider.rawValue }
            return $0.id < $1.id
        }
        var totals: [ProviderID: CostTotal] = [:]
        for report in localCosts + Array(cursorCosts.values) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = report.timeZoneID.flatMap(TimeZone.init(identifier:)) ?? .current
            let start = calendar.date(byAdding: .day, value: -29, to: now) ?? now
            let first = CostAccumulator.dayKey(start, calendar: calendar)
            let last = CostAccumulator.dayKey(now, calendar: calendar)
            var total = totals[report.provider] ?? CostTotal(provider: report.provider)
            for day in report.days where day.id >= first && day.id <= last {
                total.tokens += day.tokens.total
                total.costUSD += day.costUSD
            }
            total.reports += 1
            totals[report.provider] = total
        }
        costs = ProviderID.allCases.compactMap { totals[$0] }
        unidentifiedCursorReports = unidentified
    }

    private static func account(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value.lowercased()
    }
}
