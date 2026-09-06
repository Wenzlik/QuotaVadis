import CloudKit
import Foundation

/// iCloud private database, default zone, record type `Device`, record name = device id.
/// Publisher (Mac) overwrites its own record and adds itself to a fixed `DeviceIndex` record; readers (iOS,
/// other Macs) fetch the index and then each device by id. No queries, so no CloudKit indexes are required
/// (the Development environment never auto-creates the `recordName` queryable index a query would need).
public actor CloudSync {
    public static let containerID = "iCloud.cz.zmrhal.QuotaVadis"
    public static let recordType = "Device"
    static let indexType = "DeviceIndex"
    static let indexRecordName = "device-index"
    static let indexField = "deviceIDs"
    static let payloadField = "payload"
    static let updatedField = "updatedAt"
    static let nameField = "deviceName"
    static let subscriptionID = "device-changes"

    public enum Status: Sendable, Hashable {
        case unknown, available, noAccount, restricted, unavailable(String)
    }

    private let container: CKContainer
    private var database: CKDatabase { container.privateCloudDatabase }

    public init(containerID: String = CloudSync.containerID) {
        container = CKContainer(identifier: containerID)
    }

    public func accountStatus() async -> Status {
        do {
            switch try await container.accountStatus() {
            case .available: return .available
            case .noAccount: return .noAccount
            case .restricted: return .restricted
            case .couldNotDetermine: return .unavailable("Could not determine iCloud status")
            case .temporarilyUnavailable: return .unavailable("iCloud temporarily unavailable")
            @unknown default: return .unknown
            }
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    /// Save-or-replace this device's record, then make sure the index lists it.
    public func publish(_ payload: DevicePayload) async throws {
        let id = CKRecord.ID(recordName: payload.deviceID)
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record[Self.payloadField] = try payload.encoded() as NSData
        record[Self.updatedField] = payload.updatedAt as NSDate
        record[Self.nameField] = payload.deviceName as NSString
        try await save(record, policy: .allKeys)
        try await updateIndex { ids in ids.contains(payload.deviceID) ? nil : ids + [payload.deviceID] }
    }

    /// Remove this device's record and index entry (sync switched off or app removed).
    public func unpublish(deviceID: String) async throws {
        _ = try? await database.deleteRecord(withID: CKRecord.ID(recordName: deviceID))
        try await updateIndex { ids in ids.contains(deviceID) ? ids.filter { $0 != deviceID } : nil }
    }

    /// All devices' latest payloads, newest first. Unreadable records (future schema) are skipped;
    /// index entries whose record is gone are dropped.
    public func fetchAll() async throws -> [DevicePayload] {
        let ids = try await indexIDs()
        guard !ids.isEmpty else { return [] }
        let results = try await database.records(for: ids.map { CKRecord.ID(recordName: $0) })
        var payloads: [DevicePayload] = []
        for (_, result) in results {
            guard case .success(let record) = result,
                  let data = record[Self.payloadField] as? Data,
                  let payload = try? DevicePayload.decode(data),
                  payload.schemaVersion <= DevicePayload.schemaVersion else { continue }
            payloads.append(payload)
        }
        return payloads.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Index record

    private func indexIDs() async throws -> [String] {
        do {
            let record = try await database.record(for: CKRecord.ID(recordName: Self.indexRecordName))
            return record[Self.indexField] as? [String] ?? []
        } catch let error as CKError where error.code == .unknownItem {
            return []
        }
    }

    /// Read-modify-write with one retry on a concurrent change from another Mac. `transform` returns nil for no-op.
    private func updateIndex(_ transform: ([String]) -> [String]?) async throws {
        for attempt in 0..<2 {
            let recordID = CKRecord.ID(recordName: Self.indexRecordName)
            let record: CKRecord
            do { record = try await database.record(for: recordID) }
            catch let error as CKError where error.code == .unknownItem { record = CKRecord(recordType: Self.indexType, recordID: recordID) }
            let current = record[Self.indexField] as? [String] ?? []
            guard let next = transform(current) else { return }
            record[Self.indexField] = next as NSArray
            do {
                try await save(record, policy: .ifServerRecordUnchanged)
                return
            } catch let error as CKError where error.code == .serverRecordChanged && attempt == 0 {
                continue
            }
        }
    }

    private func save(_ record: CKRecord, policy: CKModifyRecordsOperation.RecordSavePolicy) async throws {
        let op = CKModifyRecordsOperation(recordsToSave: [record])
        op.savePolicy = policy
        op.qualityOfService = .utility
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success: c.resume()
                case .failure(let error): c.resume(throwing: error)
                }
            }
            database.add(op)
        }
    }

    /// Silent-push subscription for readers; idempotent.
    public func ensureSubscription() async throws {
        let sub = CKQuerySubscription(recordType: Self.recordType, predicate: NSPredicate(value: true),
                                      subscriptionID: Self.subscriptionID,
                                      options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion])
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        _ = try await database.save(sub)
    }
}
