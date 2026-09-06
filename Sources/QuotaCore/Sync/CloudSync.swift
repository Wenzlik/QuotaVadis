import CloudKit
import Foundation

/// iCloud private database, default zone, record type `Device`, record name = device id.
/// Publisher (Mac) overwrites its own record; readers (iOS, other Macs) query all `Device` records.
public actor CloudSync {
    public static let containerID = "iCloud.cz.zmrhal.QuotaVadis"
    public static let recordType = "Device"
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

    /// Save-or-replace this device's record. Uses `changedKeys` policy so we never fight a stale server copy.
    public func publish(_ payload: DevicePayload) async throws {
        let id = CKRecord.ID(recordName: payload.deviceID)
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record[Self.payloadField] = try payload.encoded() as NSData
        record[Self.updatedField] = payload.updatedAt as NSDate
        record[Self.nameField] = payload.deviceName as NSString
        let op = CKModifyRecordsOperation(recordsToSave: [record])
        op.savePolicy = .allKeys
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

    /// Remove this device's record (sync switched off or app removed).
    public func unpublish(deviceID: String) async throws {
        _ = try await database.deleteRecord(withID: CKRecord.ID(recordName: deviceID))
    }

    /// All devices' latest payloads, newest first. Unreadable records (future schema) are skipped.
    public func fetchAll() async throws -> [DevicePayload] {
        let query = CKQuery(recordType: Self.recordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: Self.updatedField, ascending: false)]
        var payloads: [DevicePayload] = []
        var cursor: CKQueryOperation.Cursor?
        repeat {
            let (results, next) = cursor == nil
                ? try await database.records(matching: query, resultsLimit: 50)
                : try await database.records(continuingMatchFrom: cursor!, resultsLimit: 50)
            for (_, result) in results {
                guard case .success(let record) = result,
                      let data = record[Self.payloadField] as? Data,
                      let payload = try? DevicePayload.decode(data),
                      payload.schemaVersion <= DevicePayload.schemaVersion else { continue }
                payloads.append(payload)
            }
            cursor = next
        } while cursor != nil
        return payloads
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
