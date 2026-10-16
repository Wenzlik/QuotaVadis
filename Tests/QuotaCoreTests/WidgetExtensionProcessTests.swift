#if os(macOS)
import Foundation
import Testing
@testable import QuotaCore

// After a Sparkle update the old widget extension process kept running the replaced binary; chronod rejected what it
// drew and the desktop widgets went black until someone killed it. These tests pin which processes the app ends
// for that — only our own extension, and only when it is (or may be) the old build.

private let me: UInt32 = 501
private let installed = "/Applications/QuotaVadis.app/Contents/PlugIns/QuotaWidgets-Mac.appex/Contents/MacOS/QuotaWidgets-Mac"
private let updatedAt = Date(timeIntervalSince1970: 1_000_000)

private func process(_ pid: Int32, uid: UInt32 = me, path: String? = installed, name: String = "QuotaWidgets-Mac",
                     startedAt: Date = updatedAt.addingTimeInterval(60)) -> WidgetExtensionProcess.Candidate {
    .init(pid: pid, uid: uid, path: path, name: name, startedAt: startedAt)
}

@Test func onlyOurOwnExtensionProcessesAreCandidates() {
    let candidates = [
        process(1),
        process(2, uid: 502),                                                  // another user's widget
        process(3, path: "/Applications/Other.app/Contents/MacOS/QuotaWidgets-Mac"), // same name, other bundle
        process(4, path: "/System/Library/CoreServices/chronod", name: "chronod"),
        process(5, path: "/private/var/folders/x/QuotaVadis.app/Contents/PlugIns/QuotaWidgets-Mac.appex/Contents/MacOS/QuotaWidgets-Mac"),
        process(6, path: nil),                                                 // binary deleted by the update
        process(7, path: nil, name: "QuotaWidgets"),
        process(8, name: "QuotaWidgets-Ma"),                                   // pbi_comm cut to 15 characters
    ]
    #expect(WidgetExtensionProcess.ours(candidates, uid: me).map(\.pid) == [1, 5, 6, 8])
}

@Test func aNewAppVersionRestartsEveryOwnExtensionProcess() {
    let candidates = [process(1), process(2, uid: 502), process(4, path: "/usr/libexec/chronod", name: "chronod")]
    #expect(WidgetExtensionProcess.toRestart(candidates, uid: me, appVersion: "42", lastSeenAppVersion: "41",
                                             binaryChangedAt: nil, report: nil) == [1])
    #expect(WidgetExtensionProcess.toRestart(candidates, uid: me, appVersion: "42", lastSeenAppVersion: nil,
                                             binaryChangedAt: nil, report: nil) == [1])
}

@Test func sameVersionLeavesACurrentProcessAlone() {
    let current = process(1, startedAt: updatedAt.addingTimeInterval(5))
    let report = WidgetExtensionReport(version: "42", pid: 1, startedAt: current.startedAt)
    #expect(WidgetExtensionProcess.toRestart([current], uid: me, appVersion: "42", lastSeenAppVersion: "42",
                                             binaryChangedAt: updatedAt, report: report).isEmpty)
    #expect(WidgetExtensionProcess.toRestart([current], uid: me, appVersion: "42", lastSeenAppVersion: "42",
                                             binaryChangedAt: updatedAt, report: report, force: true) == [1])
}

@Test func aProcessOlderThanTheBinaryOnDiskIsRestarted() {
    let old = process(1, startedAt: updatedAt.addingTimeInterval(-3600))
    #expect(WidgetExtensionProcess.toRestart([old, process(2)], uid: me, appVersion: "42", lastSeenAppVersion: "42",
                                             binaryChangedAt: updatedAt, report: nil) == [1])
}

@Test func aReportedOlderVersionIsRestartedAndShownInSettings() {
    let running = process(1)
    let stale = WidgetExtensionReport(version: "41", pid: 1, startedAt: running.startedAt.addingTimeInterval(1))
    #expect(WidgetExtensionProcess.toRestart([running], uid: me, appVersion: "42", lastSeenAppVersion: "42",
                                             binaryChangedAt: nil, report: stale) == [1])
    #expect(WidgetExtensionProcess.staleVersion([running], uid: me, appVersion: "42", report: stale) == "41")
    let current = WidgetExtensionReport(version: "42", pid: 1, startedAt: running.startedAt)
    #expect(WidgetExtensionProcess.staleVersion([running], uid: me, appVersion: "42", report: current) == nil)
}

@Test func aReportFromAnEndedProcessDoesNotCount() {
    let running = process(1)
    let otherPID = WidgetExtensionReport(version: "41", pid: 9, startedAt: running.startedAt)
    let reusedPID = WidgetExtensionReport(version: "41", pid: 1, startedAt: running.startedAt.addingTimeInterval(-3600))
    for report in [otherPID, reusedPID] {
        #expect(WidgetExtensionProcess.toRestart([running], uid: me, appVersion: "42", lastSeenAppVersion: "42",
                                                 binaryChangedAt: nil, report: report).isEmpty)
        #expect(WidgetExtensionProcess.staleVersion([running], uid: me, appVersion: "42", report: report) == nil)
    }
    #expect(WidgetExtensionProcess.staleVersion([], uid: me, appVersion: "42", report: otherPID) == nil)
}
#endif
