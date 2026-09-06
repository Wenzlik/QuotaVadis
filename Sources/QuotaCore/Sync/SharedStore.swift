import Foundation

/// App Group hand-off between the app and its widgets: the app writes the payload it is showing,
/// widgets read it. Same file on macOS (this Mac's own numbers) and iOS (the selected Mac's numbers).
public enum SharedStore {
    public static let appGroup = "group.cz.zmrhal.QuotaVadis"

    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appendingPathComponent("payload.json")
    }

    /// Last failure reason, for Settings and `defaults read`. nil after a successful write.
    public private(set) static var lastError: String? {
        get { UserDefaults.standard.string(forKey: "sharedStoreError") }
        set { UserDefaults.standard.set(newValue, forKey: "sharedStoreError") }
    }

    public static func write(_ payload: DevicePayload) {
        guard let url else { lastError = "No App Group container for \(appGroup) (missing entitlement or profile)"; return }
        do {
            try payload.encoded().write(to: url, options: .atomic)
            lastError = nil
        } catch {
            lastError = "\(url.path): \(error.localizedDescription)"
        }
    }

    public static func read() -> DevicePayload? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? DevicePayload.decode(data)
    }
}
