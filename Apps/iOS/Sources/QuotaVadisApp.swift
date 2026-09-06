import SwiftUI
import UIKit
import QuotaCore

@main
struct QuotaVadisApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = DeviceStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .task { await store.start() }
                .onReceive(NotificationCenter.default.publisher(for: .cloudRecordsChanged)) { _ in
                    Task { await store.refresh() }
                }
        }
    }
}

extension Notification.Name {
    static let cloudRecordsChanged = Notification.Name("cz.zmrhal.QuotaVadis.cloudRecordsChanged")
}

/// Silent pushes from the CloudKit subscription land here and trigger a refresh.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        NotificationCenter.default.post(name: .cloudRecordsChanged, object: nil)
        return .newData
    }
}
