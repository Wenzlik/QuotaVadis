import SwiftUI
import QuotaCore

/// Shared wording and age policy for the Mac summary and iOS cards.
public struct MeasurementStatusView: View {
    let status: ProviderSyncStatus
    public init(status: ProviderSyncStatus) { self.status = status }
    public var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Label(status.label(now: context.date), systemImage: status.freshness(now: context.date) == .fresh ? "checkmark.circle" : "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(status.freshness(now: context.date) == .fresh ? Color.secondary : .orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
