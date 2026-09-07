import Foundation
import Testing
@testable import QuotaCore

@Test func failedSnapshotKeepsAgeAcrossSyncAndLegacyDecode() throws {
    let now = Date(timeIntervalSince1970: 1_788_800_000)
    let old = now.addingTimeInterval(-86400)
    let snapshot = UsageSnapshot(provider: .claude, account: nil, plan: nil, windows: [], fetchedAt: old)
    let status = ProviderSyncStatus(instanceID: "claude", provider: .claude,
                                    state: .failed(.unauthorized, last: snapshot), lastAttemptAt: now)
    let payload = DevicePayload(deviceID: "test", deviceName: "Mac", snapshots: [snapshot], costs: [], providerStatuses: [status], updatedAt: now)
    let decoded = try DevicePayload.decode(payload.encoded())
    #expect(decoded.status(for: snapshot).lastSuccessAt == old)
    #expect(decoded.status(for: snapshot).lastAttemptAt == now)
    #expect(decoded.status(for: snapshot).errorCode == .loginRequired)
    #expect(decoded.status(for: snapshot).freshness(now: now) == .stale)
    var legacy = payload
    legacy.providerStatuses = nil
    let legacyDecoded = try DevicePayload.decode(legacy.encoded())
    #expect(legacyDecoded.status(for: snapshot).freshness(now: now) == .stale)
    #expect(legacyDecoded.updatedAt == now)
}

@Test func freshMeasurementAgesWithoutAnotherPublish() {
    let now = Date()
    let snapshot = UsageSnapshot(provider: .codex, account: nil, plan: nil, windows: [], fetchedAt: now)
    let status = ProviderSyncStatus(instanceID: "codex", provider: .codex, state: .fresh(snapshot), lastAttemptAt: now)
    #expect(status.freshness(now: now) == .fresh)
    #expect(status.freshness(now: now.addingTimeInterval(901)) == .stale)
}

@Test func confirmedEmptyDevicesClearWidgetFile() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let payload = DevicePayload(deviceID: "last-mac", deviceName: "Mac", snapshots: [], costs: [])
    try payload.encoded().write(to: url)
    try SharedStore.clear(at: url)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    try SharedStore.clear(at: url) // Idempotent removal.
}
