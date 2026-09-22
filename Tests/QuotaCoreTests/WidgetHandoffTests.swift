import Foundation
import Testing
@testable import QuotaCore

// The macOS desktop widgets shipped empty because every reason for "no content" ended up looking the same to
// the views: a nil payload, an undecodable file and a payload whose snapshots carried no windows all fell
// through to either a bare "Open QuotaVadis" or to nothing at all. These tests pin the seam that now
// distinguishes them, so an empty widget always has a sentence to show.

private func window(_ percent: Double) -> UsageWindow {
    UsageWindow(id: "session", kind: .session, title: "Session", usedPercent: percent, resetsAt: nil)
}

private func payload(_ snapshots: [UsageSnapshot]) -> DevicePayload {
    DevicePayload(deviceID: "test", deviceName: "Mac", snapshots: snapshots, costs: [])
}

private func tempFile(_ name: String = "payload.json") -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
}

@Test func payloadRoundTripsThroughTheAppGroupFile() throws {
    let url = tempFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let original = payload([UsageSnapshot(provider: .claude, account: nil, plan: "Max", windows: [window(42)])])
    try original.encoded().write(to: url, options: .atomic)

    let result = SharedStore.readResult(at: url)
    let decoded = try result.get()
    #expect(decoded.snapshots.count == 1)
    #expect(decoded.snapshot(for: .claude)?.worstWindow?.usedPercent == 42)
    #expect(WidgetContent.providerState(result, provider: .claude) == .ready)
}

@Test func missingFileIsReportedAsNeverWrittenRatherThanAsNothing() {
    let result = SharedStore.readResult(at: tempFile())
    #expect(result == .failure(.neverWritten))
    #expect(WidgetContent.overviewState(result) == .unavailable(.neverWritten))
    #expect(!WidgetContent.overviewState(result).detail.isEmpty)
}

@Test func undecodablePayloadIsDistinguishedFromAMissingOne() throws {
    let url = tempFile()
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("not json at all".utf8).write(to: url)

    let result = SharedStore.readResult(at: url)
    guard case .failure(.unreadable(let why)) = result else { Issue.record("expected .unreadable, got \(result)"); return }
    #expect(!why.isEmpty)
    #expect(WidgetContent.providerState(result, provider: .claude).headline == "Data unreadable")
}

@Test func writeRecordsTheFailureInsteadOfThrowingItAway() {
    let unwritable = URL(fileURLWithPath: "/System/this-path-cannot-be-written/payload.json")
    SharedStore.write(Data("{}".utf8), to: unwritable)
    #expect(SharedStore.lastError != nil)

    let url = tempFile()
    defer { try? FileManager.default.removeItem(at: url) }
    SharedStore.write(Data("{}".utf8), to: url)
    #expect(SharedStore.lastError == nil)
    #expect(SharedStore.lastWriteAt != nil)
}

@Test func emptySnapshotListIsNotTrackedToolsNotAMissingPayload() {
    let result = Result<DevicePayload, SharedStore.ReadFailure>.success(payload([]))
    #expect(WidgetContent.overviewState(result) == .noTrackedTools)
    #expect(WidgetContent.providerState(result, provider: .codex) == .noTrackedTools)
}

@Test func aToolTheAppIsNotTrackingSaysSoInsteadOfGoingBlank() {
    let result = Result<DevicePayload, SharedStore.ReadFailure>.success(
        payload([UsageSnapshot(provider: .claude, account: nil, plan: nil, windows: [window(10)])]))
    #expect(WidgetContent.providerState(result, provider: .cursor) == .toolNotTracked(.cursor))
    #expect(WidgetContent.providerState(result, provider: .claude) == .ready)
}

@Test func snapshotsWithoutWindowsAreTheBlankTileCaseAndAreNamed() {
    let windowless = UsageSnapshot(provider: .claude, account: nil, plan: "Max", windows: [])
    let result = Result<DevicePayload, SharedStore.ReadFailure>.success(payload([windowless]))
    // Every view iterates over window lists; with none, the old code drew a title and whitespace.
    #expect(WidgetContent.providerState(result, provider: .claude) == .noLimits(.claude))
    #expect(WidgetContent.overviewState(result) == .noLimits(nil))
    #expect(!WidgetContent.overviewState(result).detail.isEmpty)
}

@Test func everyEmptyStateCarriesAHeadlineAndASentence() {
    let states: [WidgetContentState] = [
        .unavailable(.noContainer), .unavailable(.neverWritten), .unavailable(.unreadable("boom")),
        .noTrackedTools, .toolNotTracked(.codex), .noLimits(.claude), .noLimits(nil),
    ]
    for state in states {
        #expect(!state.headline.isEmpty, "\(state) has no headline")
        #expect(!state.detail.isEmpty, "\(state) has no detail")
        #expect(!state.isReady)
    }
    #expect(WidgetContentState.ready.isReady)
}
