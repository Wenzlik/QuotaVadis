import Foundation
import Observation
import Sparkle

/// Sparkle wrapper: automatic daily checks, manual "Check for Updates…" from Settings and About.
/// One appcast; development builds carry `<sparkle:channel>development</sparkle:channel>`.
@MainActor
@Observable
final class Updater {
    enum Channel: String, Sendable { case stable, development }
    nonisolated static let channelKey = "qv.updateChannel"

    private let channelDelegate = ChannelDelegate()
    private let controller: SPUStandardUpdaterController
    var canCheck = false

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: channelDelegate, userDriverDelegate: nil)
        canCheck = controller.updater.canCheckForUpdates
        channel = Self.storedChannel
        // Mirror Sparkle's KVO flag so the button enables/disables correctly.
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            Task { @MainActor in self?.canCheck = change.newValue ?? false }
        }
    }

    private var observation: NSKeyValueObservation?

    func check() { controller.checkForUpdates(nil) }

    var automaticChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheck: Date? { controller.updater.lastUpdateCheckDate }

    /// Default is stable. Switching only changes what the next check offers, not the installed build.
    var channel: Channel = .stable {
        didSet {
            guard channel != oldValue else { return }
            UserDefaults.standard.set(channel.rawValue, forKey: Self.channelKey)
            controller.updater.resetUpdateCycleAfterShortDelay()
        }
    }

    nonisolated static var storedChannel: Channel {
        UserDefaults.standard.string(forKey: channelKey).flatMap(Channel.init) ?? .stable
    }

    /// Stable sees only untagged items; development also sees `development` (Sparkle always includes the default channel).
    nonisolated static func allowedChannels(for channel: Channel) -> Set<String> {
        channel == .development ? ["development"] : []
    }

    private final class ChannelDelegate: NSObject, SPUUpdaterDelegate {
        func allowedChannels(for updater: SPUUpdater) -> Set<String> {
            Updater.allowedChannels(for: Updater.storedChannel)
        }
    }
}
