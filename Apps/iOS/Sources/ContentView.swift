import SwiftUI
import QuotaCore
import QuotaUI

struct ContentView: View {
    @Bindable var store: DeviceStore

    var body: some View {
        NavigationStack {
            Group {
                if let device = store.selectedDevice {
                    deviceList(device)
                } else {
                    emptyState
                }
            }
            .navigationTitle("QuotaVadis")
            .toolbar {
                if store.devices.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) { devicePicker }
                }
            }
            .refreshable { await store.refresh() }
        }
    }

    private func deviceList(_ device: DevicePayload) -> some View {
        List {
            ForEach(ProviderID.allCases.filter { device.snapshot(for: $0) != nil }) { id in
                ProviderRow(provider: id, state: .fresh(device.snapshot(for: id)!), cost: device.cost(for: id),
                            isExpanded: store.expanded.contains(id)) {
                    withAnimation(.snappy(duration: 0.2)) {
                        if store.expanded.contains(id) { store.expanded.remove(id) } else { store.expanded.insert(id) }
                    }
                }
                .padding(.vertical, 6)
            }
            Section {
                LabeledContent("Mac", value: device.deviceName)
                LabeledContent("Published", value: device.updatedAt.formatted(.relative(presentation: .named)))
                if let error = store.lastError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            } footer: {
                Text("Numbers come from QuotaVadis on your Mac through your iCloud private database. Nothing is fetched from the providers on this device.")
            }
        }
        .listStyle(.insetGrouped)
    }

    private var devicePicker: some View {
        Menu {
            Picker("Mac", selection: Binding(get: { store.selectedDevice?.deviceID ?? "" }, set: { store.selectedDeviceID = $0 })) {
                ForEach(store.devices) { d in
                    Text(d.deviceName).tag(d.deviceID)
                }
            }
        } label: {
            Label(store.selectedDevice?.deviceName ?? "Mac", systemImage: "desktopcomputer")
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch store.status {
        case .noAccount:
            ContentUnavailableView("Sign in to iCloud", systemImage: "icloud.slash",
                                   description: Text("QuotaVadis syncs through your iCloud account. Sign in in Settings and pull to refresh."))
        case .restricted:
            ContentUnavailableView("iCloud is restricted", systemImage: "icloud.slash")
        case .unavailable(let why):
            ContentUnavailableView("iCloud unavailable", systemImage: "icloud.slash", description: Text(why))
        case .unknown, .available:
            if store.isRefreshing && store.devices.isEmpty {
                ProgressView("Looking for your Mac…")
            } else {
                ContentUnavailableView("No Mac publishing yet", systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                                       description: Text("Run QuotaVadis on a Mac signed in to the same iCloud account with “Sync to iCloud” on. Then pull to refresh."))
            }
        }
    }
}
