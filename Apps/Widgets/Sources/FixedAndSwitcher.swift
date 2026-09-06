import AppIntents
import SwiftUI
import WidgetKit
import QuotaCore

// MARK: - Fixed single-tool widgets (no configuration step)

struct FixedProviderTimelineProvider: TimelineProvider {
    let provider: ProviderID
    func placeholder(in context: Context) -> QuotaEntry { QuotaEntry(date: .now, payload: .preview, provider: provider) }
    func getSnapshot(in context: Context, completion: @escaping (QuotaEntry) -> Void) {
        completion(QuotaEntry(date: .now, payload: SharedStore.read() ?? .preview, provider: provider))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaEntry>) -> Void) {
        completion(Timeline(entries: [QuotaEntry(date: .now, payload: SharedStore.read(), provider: provider)],
                            policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

/// Helper building the configuration for one fixed tool; the three Widget types below wrap it.
struct FixedProviderWidget {
    let provider: ProviderID

    var kind: String { "cz.zmrhal.QuotaVadis.fixed.\(provider.rawValue)" }

    @MainActor var configuration: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FixedProviderTimelineProvider(provider: provider)) { entry in
            ProviderWidgetView(entry: entry).containerBackground(.background, for: .widget)
        }
        .configurationDisplayName(provider.displayName)
        .description("\(provider.displayName) limits at a glance.")
        .supportedFamilies(families)
    }

    private var families: [WidgetFamily] {
        #if os(iOS)
        [.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline]
        #else
        [.systemSmall, .systemMedium]
        #endif
    }
}

struct ClaudeWidget: Widget { var body: some WidgetConfiguration { FixedProviderWidget(provider: .claude).configuration } }
struct CodexWidget: Widget { var body: some WidgetConfiguration { FixedProviderWidget(provider: .codex).configuration } }
struct CursorWidget: Widget { var body: some WidgetConfiguration { FixedProviderWidget(provider: .cursor).configuration } }

// MARK: - Switcher: every tool in one compact widget, tabs on top

enum SwitcherSelection {
    static let key = "switcherProvider"
    static var defaults: UserDefaults { UserDefaults(suiteName: SharedStore.appGroup) ?? .standard }

    static var current: ProviderID {
        get { defaults.string(forKey: key).flatMap(ProviderID.init(rawValue:)) ?? .claude }
        set { defaults.set(newValue.rawValue, forKey: key) }
    }
}

/// Tapping a tab in the widget runs this; WidgetKit reloads the timeline afterwards.
struct SelectProviderIntent: AppIntent {
    static let title: LocalizedStringResource = "Show tool"
    static let isDiscoverable = false

    @Parameter(title: "Tool") var provider: String

    init() {}
    init(provider: ProviderID) { self.provider = provider.rawValue }

    func perform() async throws -> some IntentResult {
        if let id = ProviderID(rawValue: provider) { SwitcherSelection.current = id }
        return .result()
    }
}

struct SwitcherTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry { QuotaEntry(date: .now, payload: .preview, provider: .claude) }
    func getSnapshot(in context: Context, completion: @escaping (QuotaEntry) -> Void) {
        completion(QuotaEntry(date: .now, payload: SharedStore.read() ?? .preview, provider: SwitcherSelection.current))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaEntry>) -> Void) {
        completion(Timeline(entries: [QuotaEntry(date: .now, payload: SharedStore.read(), provider: SwitcherSelection.current)],
                            policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

struct SwitcherWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "cz.zmrhal.QuotaVadis.switcher", provider: SwitcherTimelineProvider()) { entry in
            SwitcherWidgetView(entry: entry).containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Switcher")
        .description("All tools in one compact widget. Tap a tab to switch.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct SwitcherWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuotaEntry

    private var available: [ProviderID] {
        let present = entry.payload?.snapshots.map(\.provider) ?? []
        return ProviderID.allCases.filter { present.contains($0) }
    }

    private var selected: ProviderID {
        let wanted = entry.provider ?? .claude
        return available.contains(wanted) ? wanted : (available.first ?? wanted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            tabs
            if let snapshot = entry.payload?.snapshot(for: selected) {
                if family == .systemSmall {
                    compact(snapshot)
                } else {
                    ForEach(snapshot.windows.filter(\.prominent).prefix(3)) { w in
                        BarLine(title: w.title, percent: w.usedPercent, resetsAt: w.resetsAt)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                Spacer()
                Text("Open QuotaVadis").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(available.isEmpty ? ProviderID.allCases : available) { p in
                Button(intent: SelectProviderIntent(provider: p)) {
                    Text(short(p))
                        .font(.caption2.weight(p == selected ? .bold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background(p == selected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func short(_ p: ProviderID) -> String {
        switch p { case .claude: family == .systemSmall ? "Claude" : "Claude Code"; case .codex: "Codex"; case .cursor: "Cursor" }
    }

    private func compact(_ s: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(s.windows.filter(\.prominent).prefix(2)) { w in
                BarLine(title: w.title, percent: w.usedPercent, resetsAt: nil)
            }
            Spacer(minLength: 0)
            if let w = s.worstWindow, let reset = w.resetsAt {
                Text("resets \(reset, style: .relative)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }
}
