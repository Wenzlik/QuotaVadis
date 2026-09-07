import CloudKit
import Foundation
import os

let syncLog = Logger(subsystem: "cz.zmrhal.QuotaVadis", category: "sync")

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
        syncLog.info("accountStatus: asking")
        do {
            let status = try await container.accountStatus()
            syncLog.info("accountStatus: \(status.rawValue)")
            switch status {
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
        syncLog.info("publish: start device=\(payload.deviceID, privacy: .public) snapshots=\(payload.snapshots.count)")
        defer { syncLog.info("publish: end") }
        let id = CKRecord.ID(recordName: payload.deviceID)
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record[Self.payloadField] = try payload.encoded() as NSData
        record[Self.updatedField] = payload.updatedAt as NSDate
        record[Self.nameField] = payload.deviceName as NSString
        try await save(record, policy: .allKeys)
        syncLog.info("publish: device record saved")
        try Task.checkCancellation()
        try await updateIndex { ids in ids.contains(payload.deviceID) ? nil : ids + [payload.deviceID] }
        syncLog.info("publish: index updated")
    }

    /// Remove this device's record and index entry (sync switched off or app removed).
    public func unpublish(deviceID: String) async throws {
        do { try await modify(deleting: [CKRecord.ID(recordName: deviceID)]) }
        catch let error as CKError where error.code == .unknownItem {}
        try await updateIndex { ids in ids.contains(deviceID) ? ids.filter { $0 != deviceID } : nil }
    }

    /// Human-readable note about records skipped by the last `fetchAll` (e.g. a Mac on a newer app version).
    public private(set) var lastReadWarning: String?

    /// All devices newest first. A record that is missing, undecodable or from a newer schema is skipped and
    /// reported through `lastReadWarning`; other Macs' data still arrives. Transport failures still throw.
    public func fetchAll() async throws -> [DevicePayload] {
        let ids = try await indexIDs()
        guard !ids.isEmpty else { lastReadWarning = nil; return [] }
        var payloads: [DevicePayload] = []
        var skipped: [String] = []
        for id in ids {
            let record: CKRecord
            do { record = try await fetchRecord(CKRecord.ID(recordName: id)) }
            catch let error as CKError where error.code == .unknownItem { continue }
            guard let data = record[Self.payloadField] as? Data, let payload = try? DevicePayload.decode(data) else {
                skipped.append(record[Self.nameField] as? String ?? id); continue
            }
            guard payload.schemaVersion <= DevicePayload.schemaVersion else {
                skipped.append("\(payload.deviceName) (newer QuotaVadis)"); continue
            }
            payloads.append(payload)
        }
        lastReadWarning = skipped.isEmpty ? nil : "Could not read \(skipped.joined(separator: ", ")). Update QuotaVadis on this device."
        return payloads.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Index record

    private func indexIDs() async throws -> [String] {
        do {
            let record = try await fetchRecord(CKRecord.ID(recordName: Self.indexRecordName))
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
            do { record = try await fetchRecord(recordID) }
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

    private func fetchRecord(_ id: CKRecord.ID) async throws -> CKRecord {
        let op = CKFetchRecordsOperation(recordIDs: [id])
        let result = AsyncResult<CKRecord>()
        op.perRecordResultBlock = { _, value in result.finish(value) }
        op.fetchRecordsResultBlock = { value in
            if case .failure(let error) = value { result.finish(.failure(error)) }
        }
        return try await execute(op, result: result)
    }

    private func save(_ record: CKRecord, policy: CKModifyRecordsOperation.RecordSavePolicy) async throws {
        try await modify(saving: [record], policy: policy)
    }

    private func modify(saving: [CKRecord] = [], deleting: [CKRecord.ID] = [],
                        policy: CKModifyRecordsOperation.RecordSavePolicy = .allKeys) async throws {
        let op = CKModifyRecordsOperation(recordsToSave: saving, recordIDsToDelete: deleting)
        op.savePolicy = policy
        let result = AsyncResult<Void>()
        // Wait for the terminal operation callback before the queue may start a removal.
        op.modifyRecordsResultBlock = { value in
            result.finish(value.mapError { error in
                if let cloudError = error as? CKError,
                   let failures = cloudError.partialErrorsByItemID, failures.count == 1,
                   let recordError = failures.values.first { return recordError }
                return error
            })
        }
        try await execute(op, result: result)
    }

    private func execute<T: Sendable>(_ op: CKDatabaseOperation, result: AsyncResult<T>) async throws -> T {
        op.qualityOfService = .userInitiated
        op.configuration.timeoutIntervalForRequest = 20
        op.configuration.timeoutIntervalForResource = 60
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            database.add(op)
            return try await result.value()
        } onCancel: {
            op.cancel()
            result.finish(.failure(CancellationError()))
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
        let op = CKModifySubscriptionsOperation(subscriptionsToSave: [sub])
        let result = AsyncResult<Void>()
        op.modifySubscriptionsResultBlock = { result.finish($0) }
        try await execute(op, result: result)
    }
}
