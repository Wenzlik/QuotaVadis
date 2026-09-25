import SwiftUI
import QuotaCore
import QuotaUI

struct ContentView: View {
    @Bindable var store: DeviceStore

    var body: some View {
        TabView {
            OverviewView(store: store)
                .tabItem { Label("Limits", systemImage: "flame") }
            IOSSettingsView(store: store)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

struct OverviewView: View {
    @Bindable var store: DeviceStore

    var body: some View {
        NavigationStack {
            Group {
                if let device = store.selectedDevice {
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(device.snapshots) { snapshot in
                                NavigationLink {
                                    ProviderDetailView(snapshot: snapshot,
                                                       cost: snapshot.instanceID == snapshot.provider.rawValue ? device.cost(for: snapshot.provider) : nil,
                                                       deviceName: device.deviceName)
                                } label: {
                                    ProviderCard(snapshot: snapshot, status: device.status(for: snapshot))
                                }
                                .buttonStyle(.plain)
                            }
                            // Tools the Mac tracks but could not read. Tools not installed on the Mac are not the phone's problem.
                            ForEach((device.providerStatuses ?? []).filter { status in
                                !device.snapshots.contains { $0.instanceID == status.instanceID } && status.freshness() != .unavailable
                            }) { status in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 10) {
                                        ProviderMark(provider: status.provider, size: 28)
                                        Text(status.provider.displayName).font(.headline)
                                        Spacer()
                                    }
                                    MeasurementStatusView(status: status)
                                    Text(status.errorCode?.nextStep ?? "Open the tool on your Mac, sign in, then refresh.")
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                                .accentCard(status.provider.accent, cornerRadius: 18)
                            }
                            if device.snapshots.isEmpty && (device.providerStatuses ?? []).isEmpty {
                                Text("No tools shared by this Mac. Enable tools in QuotaVadis Settings on your Mac.")
                                    .font(.callout).padding()
                            }
                            footer(device)
                        }
                        .padding(.horizontal)
                        .padding(.top, 4)
                        .padding(.bottom, 24)
                    }
                    .background(Color(.systemGroupedBackground))
                } else {
                    ScrollView { EmptyStateView(store: store).frame(maxWidth: .infinity, minHeight: 420) }
                        .background(Color(.systemGroupedBackground))
                }
            }
            .navigationTitle("QuotaVadis")
            .toolbar {
                if !store.devices.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) { devicePicker }
                }
            }
            .refreshable { await store.refresh() }
        }
    }

    private func footer(_ device: DevicePayload) -> some View {
        VStack(spacing: 4) {
            Label("\(device.deviceName) · transferred \(device.updatedAt, style: .relative) ago", systemImage: "desktopcomputer")
            if store.isRefreshing { ProgressView().controlSize(.small) }
            else if let error = store.lastError { Text(error).foregroundStyle(.orange).multilineTextAlignment(.center) }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.top, 8)
    }

    private var devicePicker: some View {
        Menu {
            Picker("Mac", selection: Binding(get: { store.selectedDevice?.deviceID ?? "" }, set: { store.selectedDeviceID = $0 })) {
                ForEach(store.devices) { d in Text(d.deviceName).tag(d.deviceID) }
            }
        } label: {
            Label(store.selectedDevice?.deviceName ?? "Mac", systemImage: "desktopcomputer")
        }
    }
}

struct EmptyStateView: View {
    let store: DeviceStore

    var body: some View {
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
            } else if let error = store.lastError {
                ContentUnavailableView("iCloud read failed", systemImage: "exclamationmark.icloud", description: Text(error))
            } else {
                ContentUnavailableView {
                    Label("No Mac publishing yet", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                } description: {
                    Text("Install QuotaVadis on a Mac signed in to the same iCloud account and keep “Sync to iCloud” on. Then pull to refresh here.")
                } actions: {
                    Link("Get the Mac app", destination: URL(string: "https://zmrhal.cz/quotavadis/")!)
                }
            }
        }
    }
}

struct IOSSettingsView: View {
    @Bindable var store: DeviceStore

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if store.devices.isEmpty {
                        Text("No Mac found yet.").foregroundStyle(.secondary)
                    } else {
                        Picker("Show", selection: Binding(get: { store.selectedDevice?.deviceID ?? "" }, set: { store.selectedDeviceID = $0 })) {
                            ForEach(store.devices) { d in Text(d.deviceName).tag(d.deviceID) }
                        }
                    }
                    LabeledContent("Last sync", value: store.lastRefresh.map { $0.formatted(.relative(presentation: .named)) } ?? "never")
                    if let device = store.selectedDevice {
                        LabeledContent("Mac published", value: device.updatedAt.formatted(.relative(presentation: .named)))
                    }
                    if let error = store.lastError { Text(error).font(.footnote).foregroundStyle(.orange) }
                    Button("Refresh now") { Task { await store.refresh() } }.disabled(store.isRefreshing)
                } header: { Text("Mac") } footer: {
                    Text("Numbers come from QuotaVadis on your Mac through your iCloud private database. This phone reads them; it never talks to the providers.")
                }

                Section {
                    Toggle("Notify me", isOn: $store.notificationsEnabled)
                    Picker("When a window reaches", selection: $store.warnAtPercent) {
                        Text("70%").tag(70); Text("80%").tag(80); Text("90%").tag(90)
                    }
                    .disabled(!store.notificationsEnabled)
                    Toggle("Also when a window resets", isOn: $store.notifyOnReset).disabled(!store.notificationsEnabled)
                    Toggle("Paid extra usage grows", isOn: $store.notifyExtraUsage).disabled(!store.notificationsEnabled)
                    Button("Send test notifications") { store.sendTestNotifications() }
                } header: { Text("Notifications") } footer: {
                    Text("Evaluated on this phone whenever new numbers arrive from the Mac, including in the background. Extra-usage alerts catch paying while limits remain (e.g. Fable on a Standard seat) and spending after a window hit 100%.")
                }

                Section("About") {
                    LabeledContent("Version", value: version)
                    Link(destination: URL(string: "https://zmrhal.cz/quotavadis/")!) { Label("QuotaVadis for Mac", systemImage: "arrow.down.circle") }
                    Link(destination: URL(string: "https://zmrhal.cz")!) { Label("Made by Václav Zmrhal", systemImage: "person") }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
