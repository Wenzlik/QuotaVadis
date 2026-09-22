import Foundation

/// App Group hand-off between the app and its widgets: the app writes the payload it is showing,
/// widgets read it. Same file on macOS (this Mac's own numbers) and iOS (the selected Mac's numbers).
public enum SharedStore {
    public static let appGroup = "group.cz.zmrhal.QuotaVadis"

    /// Why a read came back without a payload. Widgets turn this into a sentence instead of a blank tile.
    public enum ReadFailure: Error, Equatable, Sendable {
        /// No App Group container at all — missing entitlement, or a profile that does not carry the group.
        case noContainer
        /// The container is there but the app has not written a payload yet.
        case neverWritten
        /// The file is there but could not be read or decoded (permissions, truncated write, older shape).
        case unreadable(String)

        public var headline: String {
            switch self {
            case .noContainer: "Widgets not linked"
            case .neverWritten: "No data yet"
            case .unreadable: "Data unreadable"
            }
        }

        public var detail: String {
            switch self {
            case .noContainer: "QuotaVadis and its widgets don't share an App Group container."
            case .neverWritten: "Open QuotaVadis and let it refresh once."
            case .unreadable(let why): why
            }
        }
    }

    /// Defaults shared by the app and the widget extension, so the widget can report what the app's write
    /// failed on. Falls back to the process's own defaults when the suite is unavailable (no entitlement).
    static var sharedDefaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    static let errorKey = "sharedStoreError"
    static let writtenAtKey = "sharedStoreWrittenAt"

    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appendingPathComponent("payload.json")
    }

    /// Last failure reason, for Settings and `defaults read`. nil after a successful write. Kept in the shared
    /// suite so the widget sees it too, and mirrored into the process's own defaults so
    /// `defaults read cz.zmrhal.QuotaVadis sharedStoreError` keeps working as a diagnostic.
    public private(set) static var lastError: String? {
        get { sharedDefaults.string(forKey: errorKey) ?? UserDefaults.standard.string(forKey: errorKey) }
        set {
            sharedDefaults.set(newValue, forKey: errorKey)
            UserDefaults.standard.set(newValue, forKey: errorKey)
        }
    }

    /// When the app last wrote a payload successfully; nil when it never has.
    public private(set) static var lastWriteAt: Date? {
        get { sharedDefaults.object(forKey: writtenAtKey) as? Date ?? UserDefaults.standard.object(forKey: writtenAtKey) as? Date }
        set {
            sharedDefaults.set(newValue, forKey: writtenAtKey)
            UserDefaults.standard.set(newValue, forKey: writtenAtKey)
        }
    }

    /// Writing into the App Group container is an ordinary file write, but it goes through containermanagerd
    /// and can block in `open`/`rename` when that path is wedged — reproduced on macOS 26. `updateWidgets()`
    /// runs on the main actor, so a blocking write freezes the app *and* leaves the widgets with nothing.
    /// Do the file I/O off the main thread and record a timeout instead of hanging forever.
    public static let writeTimeout: TimeInterval = 5

    public static func write(_ payload: DevicePayload) {
        guard let url else {
            lastError = "No App Group container for \(appGroup) (missing entitlement or profile)"
            return
        }
        let data: Data
        do { data = try payload.encoded() }
        catch { lastError = "Could not encode the widget payload: \(error.localizedDescription)"; return }
        write(data, to: url)
    }

    /// Split out so tests can drive the timeout/error handling against a real path.
    static func write(_ data: Data, to url: URL) {
        let done = DispatchSemaphore(value: 0)
        let outcome = WriteOutcome()
        DispatchQueue.global(qos: .utility).async {
            do { try data.write(to: url, options: .atomic) }
            catch { outcome.finish("\(url.path): \(error.localizedDescription)") }
            done.signal()
        }
        if done.wait(timeout: .now() + writeTimeout) == .timedOut {
            lastError = "Writing \(url.lastPathComponent) into the App Group container timed out after \(Int(writeTimeout))s."
            return
        }
        if let failure = outcome.value { lastError = failure }
        else { lastError = nil; lastWriteAt = .now }
    }

    /// Result box for the background write; the semaphore above orders the accesses, the lock keeps it Sendable.
    private final class WriteOutcome: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        func finish(_ value: String?) { lock.lock(); stored = value; lock.unlock() }
        var value: String? { lock.lock(); defer { lock.unlock() }; return stored }
    }

    public static func clear() {
        guard let url else { lastError = "No App Group container for \(appGroup)"; return }
        do { try clear(at: url); lastError = nil; lastWriteAt = nil }
        catch { lastError = error.localizedDescription }
    }

    static func clear(at url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch CocoaError.fileNoSuchFile {} // Already empty is a successful clear.
    }

    public static func read() -> DevicePayload? { try? readResult().get() }

    /// Reading with the reason attached, so a widget can say why it has nothing instead of drawing a blank tile.
    public static func readResult() -> Result<DevicePayload, ReadFailure> {
        guard let url else { return .failure(.noContainer) }
        return readResult(at: url)
    }

    static func readResult(at url: URL) -> Result<DevicePayload, ReadFailure> {
        let data: Data
        do { data = try Data(contentsOf: url) }
        // `Data(contentsOf:)` reports a missing file as .fileReadNoSuchFile, not .fileNoSuchFile; treating only
        // the latter as "not written yet" would have shown "Data unreadable" for the ordinary first-run case.
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return .failure(.neverWritten)
        }
        catch { return .failure(.unreadable(error.localizedDescription)) }
        do { return .success(try DevicePayload.decode(data)) }
        catch { return .failure(.unreadable("The payload couldn't be decoded (\(error.localizedDescription)).")) }
    }
}
