import SwiftUI
import QuotaCore
import QuotaUI

/// Connect / reconnect QuotaVadis's own Claude login. The same view, bound to the same coordinator, sits in
/// the welcome window and in Settings ▸ Accounts, so an attempt started in one continues in the other.
///
/// Anthropic has no redirect registered for this app, so the browser shows a code that the user pastes back
/// here; the copy says so plainly instead of pretending the return is automatic.
struct ClaudeConnectionView: View {
    @Bindable var model: AppModel
    /// Settings shows Sign out next to Reconnect; the welcome window has nothing to sign out of yet.
    var allowsSignOut = true
    @FocusState private var codeFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var flow: ClaudeSignInCoordinator { model.claudeSignIn }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch flow.phase {
            case .idle: idle
            case .waitingForCode, .exchanging: pasteStep
            case .connected: justConnected
            }
            if let problem = flow.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: flow.phase)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ProviderMark(provider: .claude, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text("Your login is stored securely in this Mac’s Keychain.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(connection: model.claudeConnection)
        }
    }

    private var title: String {
        switch model.claudeConnection {
        case .notConnected: "Connect your Claude subscription"
        case .connected: "Claude is connected"
        case .reconnectRequired: "Reconnect Claude"
        }
    }

    @ViewBuilder private var idle: some View {
        if model.claudeConnection == .reconnectRequired {
            Text("Claude stopped accepting this login. Sign in again; the current one stays until the new one is saved.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 8) {
            if model.claudeConnection == .notConnected {
                Button { flow.start() } label: { Label("Continue in browser", systemImage: "safari") }
                    .buttonStyle(.borderedProminent).tint(ProviderID.claude.accent)
            } else {
                Button { flow.start() } label: { Label("Reconnect…", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.borderedProminent)
                    .tint(model.claudeConnection == .reconnectRequired ? .orange : ProviderID.claude.accent)
                if allowsSignOut {
                    Button("Sign out", role: .destructive) { model.signOutClaudeOwnLogin() }
                }
            }
            Spacer()
        }
        DisclosureGroup("How it works") {
            Text("QuotaVadis signs in to Claude with its own login, the same way the Claude Code CLI does, and keeps it in a Keychain item only this app owns. It never reads another app’s login for this, which is why macOS stops asking for Keychain permission. The sign-in page shows a one-time code instead of returning here automatically, so you paste that code back. Nothing is sent anywhere except to Claude.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .font(.callout)
    }

    private var pasteStep: some View {
        let exchanging = flow.phase == .exchanging
        // A step is ticked once there is evidence for it: a pasted code means the browser part happened.
        let hasCode = !flow.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            StepLine(number: 1, text: "Approve QuotaVadis in the browser tab that just opened.", done: hasCode)
            StepLine(number: 2, text: "Copy the code Claude shows and paste it below.", done: exchanging)
            VStack(alignment: .leading, spacing: 4) {
                Text("Authorization code").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                TextField("Paste the code from Claude", text: Binding(get: { flow.code }, set: { flow.code = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .focused($codeFocused)
                    .disabled(exchanging)
                    .onSubmit { Task { await flow.submit() } }
                    .accessibilityLabel("Authorization code")
            }
            HStack(spacing: 8) {
                Button {
                    Task { await flow.submit() }
                } label: {
                    if exchanging {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Connecting…") }
                    } else {
                        Text("Connect")
                    }
                }
                .buttonStyle(.borderedProminent).tint(ProviderID.claude.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(!flow.canSubmit)
                Button("Open browser again") { flow.reopenBrowser() }
                    .disabled(exchanging)
                    .help("Opens the same sign-in page again; a code from either tab works.")
                Spacer()
                Menu {
                    Button("Start over") { flow.startOver() }
                    Button("Cancel") { flow.cancel() }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(exchanging)
                    .accessibilityLabel("More sign-in options")
            }
        }
        // Focus goes to the field only once the browser has had its turn, not the moment the step appears.
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { codeFocused = true } }
    }

    private var justConnected: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            Text("Connected. Limits come from your QuotaVadis login from now on.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Done") { flow.acknowledge() }
        }
    }
}

private struct StepLine: View {
    let number: Int
    let text: String
    let done: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if done { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
                else { Text("\(number)").font(.caption.weight(.bold)) }
            }
            .frame(width: 18, height: 18)
            .background((done ? Color.green : ProviderID.claude.accent).opacity(0.18), in: Circle())
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Small coloured capsule: Connected / Reconnect / Not connected, with text so colour is never the only cue.
struct StatusBadge: View {
    let connection: AppModel.ClaudeConnection

    var body: some View {
        let (text, color, symbol): (String, Color, String) = switch connection {
        case .connected: ("Connected", .green, "checkmark.circle.fill")
        case .reconnectRequired: ("Reconnect", .orange, "exclamationmark.circle.fill")
        case .notConnected: ("Not connected", .secondary, "circle.dashed")
        }
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}
