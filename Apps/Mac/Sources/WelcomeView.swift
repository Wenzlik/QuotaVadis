import SwiftUI
import QuotaCore
import QuotaUI

/// First launch: choose what to track, connect Claude with QuotaVadis's own login, review and finish.
/// Nothing is read from any provider until "Open QuotaVadis" (see `AppModel.refresh`); choices stay a draft
/// until then. Closing the window keeps setup unfinished and the panel offers "Continue setup".
struct WelcomeView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private enum Step: Int, CaseIterable { case choose, connect, review }
    private enum ClaudeChoice { case ownLogin, claudeCode, skipped }

    @State private var step: Step = .choose
    @State private var draftProviders: Set<ProviderID> = []
    @State private var claudeChoice: ClaudeChoice = .ownLogin
    @State private var draftSync = true
    @State private var loaded = false

    private var steps: [Step] { draftProviders.contains(.claude) ? Step.allCases : [.choose, .review] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                Group {
                    switch step {
                    case .choose: chooseStep
                    case .connect: connectStep
                    case .review: reviewStep
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 320, maxHeight: 520)
            Divider()
            footer
        }
        .frame(width: 600)
        .onChange(of: model.claudeConnection) { _, connection in
            if connection != .notConnected { claudeChoice = .ownLogin }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draftProviders = model.enabledProviders
            draftSync = model.syncEnabled
        }
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome to QuotaVadis").font(.title2.weight(.semibold))
                Text("Your AI subscription limits, in the menu bar.").foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, s in
                    Capsule()
                        .fill(s.rawValue <= step.rawValue ? ProviderID.claude.accent : Color.secondary.opacity(0.25))
                        .frame(width: s == step ? 22 : 8, height: 8)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \((steps.firstIndex(of: step) ?? 0) + 1) of \(steps.count)")
        }
        .padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 16)
    }

    private var footer: some View {
        HStack {
            if step != .choose {
                Button("Back") { go(-1) }
            }
            Spacer()
            switch step {
            case .choose:
                Button("Continue") { go(1) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draftProviders.isEmpty)
            case .connect:
                if model.claudeConnection == .notConnected && claudeChoice == .ownLogin {
                    Button("Set up later") {
                        model.claudeSignIn.cancel()
                        claudeChoice = .skipped
                        go(1)
                    }
                    .help("Claude stays paused until you connect it in Settings ▸ Accounts.")
                }
                Button("Continue") { go(1) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.claudeConnection == .notConnected && claudeChoice == .ownLogin)
            case .review:
                Button("Open QuotaVadis") { finish() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    private func go(_ delta: Int) {
        let list = steps
        guard let index = list.firstIndex(of: step) else { step = .choose; return }
        let next = min(max(0, index + delta), list.count - 1)
        // Coming back to the Claude step undoes "Set up later": the user is looking at Connect again.
        if list[next] == .connect, claudeChoice == .skipped { claudeChoice = .ownLogin }
        withAnimation(.snappy(duration: 0.2)) { step = list[next] }
    }

    // MARK: - Steps

    private var chooseStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What should QuotaVadis track?").font(.title3.weight(.semibold))
            VStack(spacing: 8) {
                ForEach(ProviderID.allCases) { provider in
                    Toggle(isOn: Binding(get: { draftProviders.contains(provider) },
                                         set: { on in if on { draftProviders.insert(provider) } else { draftProviders.remove(provider) } })) {
                        HStack(spacing: 10) {
                            ProviderMark(provider: provider, size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(provider.shortName).font(.headline)
                                Text(howItConnects(provider)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    .padding(10)
                    .background(provider.accent.opacity(draftProviders.contains(provider) ? 0.08 : 0.02),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            Label("Your logins and numbers stay on this Mac. QuotaVadis never asks for passwords or API keys.",
                  systemImage: "lock.shield")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func howItConnects(_ provider: ProviderID) -> String {
        switch provider {
        case .claude: "Connect your subscription with QuotaVadis’s own login — next step."
        case .codex: "Uses the Codex CLI login already on this Mac."
        case .cursor: "Uses the Cursor app’s session on this Mac."
        case .gemini: "Reads Antigravity’s local server while the app runs."
        }
    }

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            ClaudeConnectionView(model: model, allowsSignOut: false)
                .padding(16)
                .accentCard(ProviderID.claude.accent)
            if claudeChoice == .claudeCode {
                Label("QuotaVadis will read Claude Code’s login instead. macOS asks for Keychain access, and may ask again after Claude Code refreshes its token.",
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Use QuotaVadis’s own login instead") { claudeChoice = .ownLogin }
                    .buttonStyle(.link)
            } else if model.claudeConnection == .notConnected {
                DisclosureGroup("Other ways to read Claude") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("If Claude Code is logged in on this Mac, QuotaVadis can read its login from the Keychain instead. macOS will ask for permission, and may keep asking whenever Claude Code rotates its token.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Use Claude Code’s login") {
                            model.claudeSignIn.cancel()
                            claudeChoice = .claudeCode
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.callout)
            }
        }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ready to go").font(.title3.weight(.semibold))
            VStack(spacing: 6) {
                ForEach(ProviderID.allCases.filter { finalProviders.contains($0) }) { provider in
                    HStack(spacing: 10) {
                        ProviderMark(provider: provider, size: 24)
                        Text(provider.shortName).font(.headline)
                        Spacer()
                        Text(reviewStatus(provider)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if claudeChoice == .skipped && draftProviders.contains(.claude) {
                    HStack(spacing: 10) {
                        ProviderMark(provider: .claude, size: 24).opacity(0.4)
                        Text("Claude").font(.headline).foregroundStyle(.secondary)
                        Spacer()
                        Text("Paused — connect later in Settings ▸ Accounts").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Toggle(isOn: $draftSync) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync to iCloud").font(.headline)
                    Text(SyncPrivacy.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
        }
    }

    private func reviewStatus(_ provider: ProviderID) -> String {
        switch provider {
        case .claude:
            switch claudeChoice {
            case .ownLogin: model.claudeConnection == .notConnected ? "Not connected" : "Connected"
            case .claudeCode: "Uses Claude Code’s login"
            case .skipped: ""
            }
        default: "Uses the login on this Mac"
        }
    }

    /// A skipped Claude is left off rather than silently falling back to another app's login.
    private var finalProviders: Set<ProviderID> {
        claudeChoice == .skipped ? draftProviders.subtracting([.claude]) : draftProviders
    }

    private func finish() {
        let source: UsageService.ClaudeSource = claudeChoice == .claudeCode ? .claudeCode : (model.claudeSource == .claudeCode ? .automatic : model.claudeSource)
        model.completeOnboarding(providers: finalProviders, claudeSource: source, sync: draftSync)
        dismiss()
    }
}
