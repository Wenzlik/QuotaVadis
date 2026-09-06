import SwiftUI

/// About window: name, version, author, links. Opened from the panel footer.
struct AboutView: View {
    var updater: Updater

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 10) {
            // Read straight from the asset catalog; NSApp.applicationIconImage can serve a stale cached icon.
            Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("QuotaVadis").font(.title2.weight(.semibold))
            Text(version).font(.caption).foregroundStyle(.secondary)
            Button("Check for Updates…") { updater.check() }.controlSize(.small).disabled(!updater.canCheck)
            Text("Your AI coding limits, at a glance.")
                .font(.callout)
                .multilineTextAlignment(.center)
            Divider().padding(.vertical, 4)
            VStack(spacing: 4) {
                Text("Made by Václav Zmrhal")
                Link("zmrhal.cz", destination: URL(string: "https://zmrhal.cz")!)
            }
            .font(.callout)
            Text("Not affiliated with Anthropic, OpenAI or Cursor. Reads the sessions those tools already keep on this Mac; nothing leaves your device except the usage requests they make themselves.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
        }
        .padding(24)
        .frame(width: 320)
    }
}
