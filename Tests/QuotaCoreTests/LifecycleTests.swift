import Foundation
import Testing
@testable import QuotaCore

@Test func timeoutDoesNotWaitForUncooperativeCallback() async {
    let callback = AsyncResult<Int>()
    let start = ContinuousClock.now
    do {
        _ = try await withTimeout(seconds: 0.04) { try await callback.value() }
        Issue.record("Expected timeout")
    } catch { #expect(error is TimeoutError) }
    #expect(start.duration(to: .now) < .seconds(1))
    callback.finish(.success(1)) // A late callback must neither crash nor replace the timeout.
}

@Test func cancellationBeforeCallbackRegistration() async {
    let callback = AsyncResult<Int>()
    callback.finish(.failure(CancellationError()))
    do { _ = try await callback.value(); Issue.record("Expected cancellation") }
    catch { #expect(error is CancellationError) }
    callback.finish(.success(2))
}

private struct FakeFetcher: UsageFetcher {
    let provider: ProviderID
    let body: @Sendable () async throws -> UsageSnapshot
    func fetchRaw() async throws -> Data { Data() }
    func isAvailable() -> Bool { true }
    func fetch() async throws -> UsageSnapshot { try await body() }
}

@Test func fastProviderArrivesBeforeBlockedProvider() async {
    let blocked = AsyncResult<UsageSnapshot>()
    let arrived = AsyncResult<Void>()
    let service = UsageService(fetchers: [
        FakeFetcher(provider: .codex) { try await blocked.value() },
        FakeFetcher(provider: .claude) { UsageSnapshot(provider: .claude, account: nil, plan: nil, windows: []) }
    ])
    let refresh = Task {
        await service.refresh(timeout: 0.2) { id, state in
            if id == "claude", case .fresh = state { arrived.finish(.success(())) }
        }
    }
    do { try await withTimeout(seconds: 0.1) { try await arrived.value() } }
    catch { Issue.record("Fast provider was held behind slow provider") }
    let result = await refresh.value
    if case .failed = result["codex"] {} else { Issue.record("Expected timeout state") }
    blocked.finish(.failure(CancellationError()))
}

@Test @MainActor func removalCannotOvertakeSuspendedPublish() async {
    let queue = SerialOperationQueue()
    let accountCheck = AsyncResult<Void>()
    let events = EventLog()
    let publish = queue.enqueue {
        try? await accountCheck.value()
        await events.append("publish")
    }
    let remove = queue.enqueue { await events.append("remove") }
    accountCheck.finish(.success(()))
    await publish.value
    await remove.value
    #expect(await events.values == ["publish", "remove"])
}

private actor EventLog {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

#if os(macOS)
@Test func helperWithNoResponseAndFullStderrIsKilled() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let helper = dir.appendingPathComponent("helper")
    let pidFile = dir.appendingPathComponent("pid")
    // Shell builtins only: no grandchildren to leak. Ignore TERM and continuously fill stderr.
    try "#!/bin/sh\necho $$ > '\(pidFile.path)'\ntrap '' TERM\nwhile :; do echo 'stderr noise stderr noise stderr noise' >&2; done\n".write(to: helper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let start = ContinuousClock.now
    do { _ = try await CodexCLI.readRateLimits(binary: helper, timeout: 1); Issue.record("Expected timeout") }
    catch { #expect(error is TimeoutError) }
    #expect(start.duration(to: .now) < .seconds(4))
    let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    #expect(kill(pid, 0) == -1)
    #expect(errno == ESRCH)
}
#endif
