import AppIntents
import SwiftUI
import WidgetKit
import QuotaCore

/// Widget configuration: which tool a single-provider widget shows.
enum ProviderChoice: String, AppEnum {
    case claude, codex, cursor, antigravity
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Tool")
    static let caseDisplayRepresentations: [ProviderChoice: DisplayRepresentation] = [
        .claude: "Claude Code", .codex: "Codex", .cursor: "Cursor", .antigravity: "Antigravity",
    ]
    var providerID: ProviderID { ProviderID(rawValue: rawValue)! }
}

struct ProviderIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Tool"
    static let description = IntentDescription("Which tool this widget tracks.")
    @Parameter(title: "Tool", default: .claude) var provider: ProviderChoice
}

struct QuotaEntry: TimelineEntry {
    let date: Date
    let payload: DevicePayload?
    let provider: ProviderID?

    var snapshot: UsageSnapshot? { provider.flatMap { payload?.snapshot(for: $0) } }
    var cost: CostReport? { provider.flatMap { payload?.cost(for: $0) } }

    /// Pre-schedule age/reset boundaries; re-reading an unchanged file must never rejuvenate a sample.
    static func entries(payload: DevicePayload?, provider: ProviderID?, now: Date = .now) -> [QuotaEntry] {
        let snapshots = payload?.snapshots ?? []
        let nextReload = now.addingTimeInterval(30 * 60)
        let boundaries = snapshots.flatMap { snapshot in
            [snapshot.fetchedAt.addingTimeInterval((payload?.status(for: snapshot).staleAfter ?? ProviderSyncStatus.minimumStaleAfter) + 1)] + snapshot.windows.compactMap(\.resetsAt)
        }.filter { $0 > now && $0 < nextReload }
        return ([now] + Set(boundaries).sorted()).map { QuotaEntry(date: $0, payload: payload, provider: provider) }
    }

    static let placeholder = QuotaEntry(date: .now, payload: .preview, provider: .claude)
}

/// One entry from the App Group file; the app asks for a reload whenever it writes a new payload.
struct ProviderTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry { .placeholder }
    func snapshot(for configuration: ProviderIntent, in context: Context) async -> QuotaEntry {
        QuotaEntry(date: .now, payload: SharedStore.read() ?? .preview, provider: configuration.provider.providerID)
    }
    func timeline(for configuration: ProviderIntent, in context: Context) async -> Timeline<QuotaEntry> {
        let entry = QuotaEntry(date: .now, payload: SharedStore.read(), provider: configuration.provider.providerID)
        return Timeline(entries: QuotaEntry.entries(payload: entry.payload, provider: entry.provider), policy: .after(.now.addingTimeInterval(30 * 60)))
    }
}

struct OverviewTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry { .placeholder }
    func getSnapshot(in context: Context, completion: @escaping (QuotaEntry) -> Void) {
        completion(QuotaEntry(date: .now, payload: SharedStore.read() ?? .preview, provider: nil))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaEntry>) -> Void) {
        let entry = QuotaEntry(date: .now, payload: SharedStore.read(), provider: nil)
        completion(Timeline(entries: QuotaEntry.entries(payload: entry.payload, provider: entry.provider), policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

extension DevicePayload {
    /// Gallery preview and placeholder content.
    static let preview: DevicePayload = {
        func w(_ id: String, _ kind: UsageWindow.Kind, _ title: String, _ pct: Double, hours: Double) -> UsageWindow {
            UsageWindow(id: id, kind: kind, title: title, usedPercent: pct, resetsAt: .now.addingTimeInterval(hours * 3600))
        }
        return DevicePayload(deviceID: "preview", deviceName: "MacBook Pro", snapshots: [
            UsageSnapshot(provider: .claude, account: nil, plan: "Max", windows: [w("session", .session, "Session", 42, hours: 2), w("weekly", .weekly, "Weekly", 61, hours: 70)]),
            UsageSnapshot(provider: .codex, account: nil, plan: "Plus", windows: [w("session", .session, "Session", 18, hours: 4), w("weekly", .weekly, "Weekly", 55, hours: 120)]),
            UsageSnapshot(provider: .cursor, account: nil, plan: "Pro", windows: [w("plan", .monthly, "Included total", 27, hours: 400)]),
        ], costs: [])
    }()
}
