import BackgroundTasks
import SwiftUI
import UIKit
import os
import QuotaCore

@main
struct QuotaVadisApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = DeviceStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .task {
                    // Also at launch: after an update or a force-quit iOS has no request pending, and the app may
                    // be killed before it ever reaches the background.
                    BackgroundRefresh.schedule()
                    await store.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await store.refreshIfNeeded() } }
                    if phase == .background { BackgroundRefresh.schedule() }
                }
        }
        // Widgets only know what this app last fetched; without this they age until the app is opened again.
        .backgroundTask(.appRefresh(BackgroundRefresh.id)) {
            BackgroundRefresh.schedule()
            await DeviceStore.shared.refresh()
        }
    }
}

enum BackgroundRefresh {
    static let id = WidgetContent.backgroundRefreshID
    /// iOS decides when it actually runs; this only asks for no sooner than every 30 minutes. A new request replaces
    /// the pending one.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: id)
        request.earliestBeginDate = .now.addingTimeInterval(WidgetContent.reloadInterval)
        do { try BGTaskScheduler.shared.submit(request) } catch {
            Logger(subsystem: "cz.zmrhal.QuotaVadis", category: "widgets").error("background refresh not scheduled: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Silent pushes from the CloudKit subscription land here and trigger a refresh.
@MainActor final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        switch await DeviceStore.shared.refresh() {
        case .newData: return .newData
        case .noData: return .noData
        case .failed: return .failed
        }
    }
}
