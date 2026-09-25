import SwiftUI
import QuotaCore
import QuotaUI

extension UsageSnapshot {
    var displayTitle: String {
        instanceID == provider.rawValue ? provider.displayName : "\(provider.displayName) · \(organization ?? instanceID)"
    }
}
