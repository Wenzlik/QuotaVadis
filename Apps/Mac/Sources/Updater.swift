import Foundation
import Observation
import Sparkle

/// Sparkle wrapper: automatic daily checks, manual "Check for Updates…" from Settings and About.
@MainActor
@Observable
final class Updater {
    private let controller: SPUStandardUpdaterController
    var canCheck = false

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        canCheck = controller.updater.canCheckForUpdates
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
}
