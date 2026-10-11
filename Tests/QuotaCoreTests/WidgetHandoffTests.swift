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

// MARK: - App → widget hand-off after the fix for widgets that stopped updating (stale or blank tiles)

@Test func payloadWrittenByTheAppIsWhatTheWidgetReads() throws {
    let url = tempFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let measured = Date(timeIntervalSince1970: 1_790_000_000)
    let snapshot = UsageSnapshot(provider: .codex, account: "a@b.c", plan: "Plus", windows: [window(73)], fetchedAt: measured)
    let status = ProviderSyncStatus(instanceID: snapshot.instanceID, provider: .codex, state: .fresh(snapshot),
                                    lastAttemptAt: measured, refreshInterval: 600)
    let written = DevicePayload(deviceID: "mac", deviceName: "Mac mini", snapshots: [snapshot], costs: [],
                                providerStatuses: [status], updatedAt: measured)
    // Same bytes `SharedStore.write` stores, written directly: going through it would reset the process-wide
    // `lastError` while the failure test above, running in parallel, is checking it.
    try written.encoded().write(to: url)

    let read = try SharedStore.readResult(at: url).get()
    #expect(read == written)
    // The measurement time survives the round trip, so a widget can say how old its numbers are.
    #expect(read.status(for: snapshot).lastSuccessAt == measured)
    #expect(read.status(for: snapshot).staleAfter == 1260) // two missed 10-minute refreshes + 1 min
}

@Test func oldDataIsLabelledStaleWithItsAgeNotShownAsCurrent() {
    let measured = Date(timeIntervalSince1970: 1_790_000_000)
    let snapshot = UsageSnapshot(provider: .claude, account: nil, plan: nil, windows: [window(40)], fetchedAt: measured)
    let payload = DevicePayload(deviceID: "mac", deviceName: "Mac", snapshots: [snapshot], costs: [], updatedAt: measured)
    let status = payload.status(for: snapshot)
    let eightDaysLater = measured.addingTimeInterval(8 * 86400)

    #expect(status.freshness(now: measured.addingTimeInterval(60)) == .fresh)
    #expect(status.freshness(now: eightDaysLater) == .stale)
    #expect(status.label(now: eightDaysLater).hasPrefix("Stale · measured"))
    // Old data is still drawn (with that label); it is not an empty state.
    #expect(WidgetContent.providerState(.success(payload), provider: .claude) == .ready)
}

@Test func timelineFlipsToStaleOnItsOwnBeforeTheNextReload() {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let snapshot = UsageSnapshot(provider: .claude, account: nil, plan: nil,
                                 windows: [UsageWindow(id: "session", kind: .session, title: "Session", usedPercent: 10,
                                                       resetsAt: now.addingTimeInterval(20 * 60))],
                                 fetchedAt: now.addingTimeInterval(-10 * 60))
    let payload = DevicePayload(deviceID: "mac", deviceName: "Mac", snapshots: [snapshot], costs: [])
    let dates = WidgetContent.entryDates(for: payload, now: now)

    let staleAt = snapshot.fetchedAt.addingTimeInterval(ProviderSyncStatus.minimumStaleAfter + 1)
    #expect(dates == [now, staleAt, now.addingTimeInterval(20 * 60)])
    #expect(dates.allSatisfy { $0 < now.addingTimeInterval(WidgetContent.reloadInterval) })
    #expect(payload.status(for: snapshot).freshness(now: dates[1]) == .stale)
}

@Test func timelineWithoutDataStillHasAnEntry() {
    // WidgetKit draws nothing for an empty timeline; there must always be an entry to carry the empty state.
    let now = Date()
    #expect(WidgetContent.entryDates(for: nil, now: now) == [now])
    let longAgo = DevicePayload(deviceID: "mac", deviceName: "Mac",
                                snapshots: [UsageSnapshot(provider: .cursor, account: nil, plan: nil, windows: [],
                                                          fetchedAt: now.addingTimeInterval(-8 * 86400))], costs: [])
    #expect(WidgetContent.entryDates(for: longAgo, now: now) == [now])
}

@Test func onlyTheInstalledCopyRepairsWidgetRegistration() {
    let home = URL(fileURLWithPath: "/Users/someone")
    #expect(WidgetRegistration.isInstalled(URL(fileURLWithPath: "/Applications/QuotaVadis.app"), home: home))
    #expect(WidgetRegistration.isInstalled(URL(fileURLWithPath: "/Users/someone/Applications/QuotaVadis.app"), home: home))
    // Build products that merely live in a folder called Applications must not unregister the installed app.
    #expect(!WidgetRegistration.isInstalled(URL(fileURLWithPath:
        "/proj/.build/dd/Build/Intermediates.noindex/ArchiveIntermediates/QuotaVadis/InstallationBuildProductsLocation/Applications/QuotaVadis.app"), home: home))
    #expect(!WidgetRegistration.isInstalled(URL(fileURLWithPath: "/proj/dist/export/QuotaVadis.app"), home: home))
    #expect(!WidgetRegistration.isInstalled(URL(fileURLWithPath: "/Volumes/QuotaVadis/QuotaVadis.app"), home: home))
}

@Test func ghostRegistrationsAreReadFromTheLaunchServicesDump() {
    // `lsregister -dump Bundle | grep -E '^(path|identifier):'`, as captured on a Mac whose widgets had stopped:
    // the archive and the DMG mount no longer exist on disk, NSWorkspace does not list them, LaunchServices still does.
    let dump = """
    path:                       /Applications/QuotaVadis.app (0x663c)
    identifier:                 cz.zmrhal.QuotaVadis
    path:                       /Applications/Notion.app (0x1234)
    identifier:                 notion.id
    path:                       /Volumes/T5 500GB/QuotaVadis/dist/QuotaVadis.xcarchive/Products/Applications/QuotaVadis.app (0x562c)
    identifier:                 cz.zmrhal.QuotaVadis
    path:                       /Volumes/QuotaVadis/QuotaVadis.app (0x45a8)
    identifier:                 cz.zmrhal.QuotaVadis
    path:                       /Applications/QuotaVadis.app/Contents/PlugIns/QuotaWidgets-Mac.appex (0x7000)
    identifier:                 cz.zmrhal.QuotaVadis.widgets
    identifier:                 cz.zmrhal.QuotaVadis
    path:                       /Applications/QuotaVadis.app (0x663c)
    identifier:                 cz.zmrhal.QuotaVadis
    """
    #expect(WidgetRegistration.registeredPaths(bundleID: "cz.zmrhal.QuotaVadis", dump: dump) == [
        "/Applications/QuotaVadis.app",
        "/Volumes/T5 500GB/QuotaVadis/dist/QuotaVadis.xcarchive/Products/Applications/QuotaVadis.app",
        "/Volumes/QuotaVadis/QuotaVadis.app",
    ])
    #expect(WidgetRegistration.registeredPaths(bundleID: "cz.zmrhal.QuotaVadis", dump: "").isEmpty)
}

@Test func everyOtherRegisteredCopyIsDroppedButNeverTheRunningOne() {
    let home = URL(fileURLWithPath: "/Users/someone")
    let onDisk: Set = ["/Applications/QuotaVadis.app", "/Users/someone/Applications/QuotaVadis.app", "/Volumes/QuotaVadis/QuotaVadis.app"]
    let registered = [
        "/Applications/QuotaVadis.app/",
        "/Users/someone/Applications/QuotaVadis.app",
        "/Volumes/QuotaVadis/QuotaVadis.app",
        "/proj/dist/QuotaVadis.xcarchive/Products/Applications/QuotaVadis.app",  // ghost
        "/Users/someone/Library/Caches/cz.zmrhal.QuotaVadis/org.sparkle-project.Sparkle/Installation/x/QuotaVadis.app",  // ghost
    ]
    let drop = { (running: String) in
        WidgetRegistration.copiesToUnregister(running: URL(fileURLWithPath: running), registered: registered,
                                              exists: onDisk.contains, home: home)
    }
    // The other install stays registered whichever one runs, so the two never unregister each other in turn.
    #expect(drop("/Applications/QuotaVadis.app") == Array(registered[2...]))
    #expect(drop("/Users/someone/Applications/QuotaVadis.app") == Array(registered[2...]))
    // An install whose files are gone is just another ghost.
    #expect(WidgetRegistration.copiesToUnregister(running: URL(fileURLWithPath: "/Applications/QuotaVadis.app"),
                                                  registered: ["/Users/someone/Applications/QuotaVadis.app"],
                                                  exists: { _ in false }, home: home) == ["/Users/someone/Applications/QuotaVadis.app"])
    #expect(WidgetRegistration.copiesToUnregister(running: URL(fileURLWithPath: "/Applications/QuotaVadis.app"),
                                                  registered: ["/Applications/QuotaVadis.app"], home: home).isEmpty)
}

@Test func iOSBackgroundRefreshIsPermittedByItsInfoPlist() throws {
    // A submit with an identifier missing from BGTaskSchedulerPermittedIdentifiers fails, and the widgets age silently.
    let plistURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Apps/iOS/Info.plist")
    let plist = try #require(NSDictionary(contentsOf: plistURL) as? [String: Any])
    #expect((plist["BGTaskSchedulerPermittedIdentifiers"] as? [String])?.contains(WidgetContent.backgroundRefreshID) == true)
    #expect((plist["UIBackgroundModes"] as? [String])?.contains("fetch") == true)
}
