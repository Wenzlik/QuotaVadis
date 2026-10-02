import SwiftUI
import QuotaCore
import QuotaUI

/// Cross-device readings stay in the panel; the menu bar and widgets still describe this Mac.
struct CrossDeviceSection: View {
    @Bindable var model: AppModel

    var body: some View {
        let combined = model.combinedUsage
        VStack(alignment: .leading, spacing: 10) {
            Text("Combined usage").font(.headline)
            if !model.syncEnabled {
                Text("iCloud sync is off. Showing this Mac only. Enable sync in Settings to include other Macs.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("\(combined.devices.count) \(combined.devices.count == 1 ? "Mac" : "Macs") · menu bar shows this Mac")
                    .font(.caption).foregroundStyle(.secondary)
                if model.isSyncing { ProgressView("Syncing iCloud…").controlSize(.small) }
                if let error = model.lastSyncError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                    Text("Showing the last readings received; another Mac may be missing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let warning = model.syncReadWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
                if let date = model.lastSyncRead {
                    Text("iCloud checked \(date, format: .relative(presentation: .named))").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Other Macs appear after a successful iCloud sync.").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(combined.costs) { cost in
                VStack(alignment: .leading, spacing: 3) {
                    Text(cost.provider.shortName).font(.subheadline.weight(.semibold))
                    Text("\(cost.costUSD, format: .currency(code: "USD")) · \(cost.tokens.formatted()) tokens")
                        .font(.callout.monospacedDigit())
                    Text(cost.provider == .cursor ? "Account dashboard · newest report per account" : "Local logs across Macs · estimated API value")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Reported last 30 days, using each Mac’s calendar. Older reports can miss recent activity. Local logs must be separate, not copied between Macs.")
                .font(.caption).foregroundStyle(.secondary)
            if combined.unidentifiedCursorReports > 0 {
                Text("Cursor reports without an account identifier are shown per device only.")
                    .font(.caption).foregroundStyle(.orange)
            }
            DisclosureGroup("Account quotas & credits") {
                Text("Newest measurement per account and workspace; percentages and credits are never added. Unknown accounts stay separate.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(combined.readings) { reading in
                    readingView(reading.snapshot, status: reading.status, deviceName: reading.deviceName)
                }
                if combined.readings.isEmpty { Text("No quota readings yet.").font(.caption).foregroundStyle(.secondary) }
            }
            DisclosureGroup("Per device") {
                ForEach(combined.devices) { device in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(device.deviceName + (device.deviceID == DeviceIdentity.id ? " · this Mac" : ""))
                            .font(.subheadline.weight(.semibold))
                        if device.deviceID != DeviceIdentity.id {
                            Text("Published \(device.updatedAt, format: .relative(presentation: .named))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(device.snapshots, id: \.instanceID) { snapshot in
                            readingView(snapshot, status: device.status(for: snapshot))
                        }
                        ForEach(device.costs, id: \.provider) { cost in
                            Text("\(cost.provider.shortName): \(cost.totalCostUSD, format: .currency(code: "USD")) · \(cost.totalTokens.formatted()) tokens")
                                .font(.caption.monospacedDigit())
                            Text("30-day report measured \(cost.generatedAt, format: .relative(presentation: .named))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if device.snapshots.isEmpty && device.costs.isEmpty {
                            Text("No measurements published.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
    }

    private func readingView(_ snapshot: UsageSnapshot, status: ProviderSyncStatus, deviceName: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text([snapshot.provider.shortName, snapshot.account, snapshot.organization, deviceName].compactMap { $0 }.joined(separator: " · "))
                .font(.caption.weight(.semibold))
            MeasurementStatusView(status: status)
            ForEach(snapshot.windows) { UsageBar(window: $0, compact: true) }
            ForEach(snapshot.credits) { CreditsLine(credits: $0) }
            if let resets = snapshot.resetCreditsAvailable {
                Text("Limit resets available: \(resets)").font(.caption)
            }
        }
        .padding(.vertical, 5)
    }
}
