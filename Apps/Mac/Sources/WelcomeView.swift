import SwiftUI
import QuotaCore

/// Shown once before the first refresh so the Keychain prompt does not come out of nowhere.
struct WelcomeView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading) {
                    Text("Welcome to QuotaVadis").font(.title2.weight(.semibold))
                    Text("Your Claude Code, Codex and Cursor limits in the menu bar.").foregroundStyle(.secondary)
                }
            }
            point("key.fill", "Nothing to log into",
                  "QuotaVadis reuses existing tool logins. Codex refreshes its own login through its CLI; additional Claude profiles use a QuotaVadis-managed credential copy.")
            point("lock.shield", "One Keychain question",
                  "Claude Code stores its login in the Keychain. macOS will ask whether QuotaVadis may read it. Choose “Always Allow”, otherwise the question comes back on every refresh.")
            point("icloud", "Choose whether to sync",
                  SyncPrivacy.summary)
            HStack {
                Spacer()
                Button("Continue") {
                    model.completeOnboarding()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func point(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).frame(width: 24).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
