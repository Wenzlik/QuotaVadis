import Foundation

/// App Group hand-off between the app and its widgets: the app writes the payload it is showing,
/// widgets read it. Same file on macOS (this Mac's own numbers) and iOS (the selected Mac's numbers).
public enum SharedStore {
    public static let appGroup = "group.cz.zmrhal.QuotaVadis"

    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appendingPathComponent("payload.json")
    }

    public static func write(_ payload: DevicePayload) {
        guard let url, let data = try? payload.encoded() else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func read() -> DevicePayload? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? DevicePayload.decode(data)
    }
}
