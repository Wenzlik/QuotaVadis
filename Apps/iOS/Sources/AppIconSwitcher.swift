import UIKit
import os

private let iconLog = Logger(subsystem: "cz.zmrhal.QuotaVadis", category: "app-icon")

/// Home Screen icon for the GoodLimits.ai theme. iOS shows a system alert on every change, so this only asks when
/// the wanted icon differs from the current one; callers feed it a value that changes only when the answer does.
@MainActor
enum AppIconSwitcher {
    /// Alternate icon set in Assets.xcassets, listed in ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES.
    static let goodLimitsIcon = "GoodLimitsIcon"

    /// - Parameter wanted: nil = no evidence yet, keep the icon as it is.
    static func apply(goodLimits wanted: Bool?) {
        let app = UIApplication.shared
        guard let wanted, app.supportsAlternateIcons else { return }
        let target = wanted ? goodLimitsIcon : nil
        guard app.alternateIconName != target else { return }
        Task { @MainActor in
            do { try await app.setAlternateIconName(target) }
            catch { iconLog.error("Could not set app icon \(target ?? "default", privacy: .public): \(error.localizedDescription, privacy: .public)") }
        }
    }
}
