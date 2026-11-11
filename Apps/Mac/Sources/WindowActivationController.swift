import AppKit

/// LSUIElement keeps QuotaVadis out of the Dock and ⌘-Tab, which strands its standalone windows (Settings,
/// Usage details, Welcome, About) once another app covers them. While any of them is open (or minimized),
/// run as a regular app; when the last one closes, drop back to accessory. The menu bar panel never counts.
@MainActor
final class WindowActivationController {
    static let shared = WindowActivationController()

    private init() {
        let names = [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.willCloseNotification]
        for name in names {
            _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                // Next runloop turn: during willClose the closing window is still visible and in NSApp.windows.
                Task { @MainActor in WindowActivationController.shared.update() }
            }
        }
    }

    /// Dock / ⌘-Tab icon for the running app (GoodLimits.ai theme); nil = the bundle's AppIcon. Runtime only: the
    /// Finder icon of the signed bundle never changes. Re-applied after going regular, so the Dock tile that appears
    /// when a window opens shows it too.
    var iconOverride: NSImage? {
        didSet { NSApp.applicationIconImage = iconOverride }
    }

    /// Re-derive the activation policy from the windows currently open.
    func update() {
        // Hiding (⌘H) orders every window out; the app must stay in ⌘-Tab to be unhidden.
        guard !NSApp.isHidden else { return }
        let windows = NSApp.windows.filter(Self.isStandalone)
        for window in windows where !window.styleMask.isSuperset(of: [.closable, .miniaturizable]) {
            window.styleMask.formUnion([.closable, .miniaturizable])
        }
        setRegular(!windows.isEmpty)
    }

    /// Only touches the policy when it changes, so repeated calls don't flicker the Dock.
    /// Never activates: notification-driven updates must not steal focus. Explicit opens activate in bringToFront.
    func setRegular(_ regular: Bool) {
        let policy: NSApplication.ActivationPolicy = regular ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if regular, let iconOverride { NSApp.applicationIconImage = iconOverride }
    }

    /// A real app window: titled, not a panel/popover/alert/sheet, not the status item or MenuBarExtra panel.
    static func isStandalone(_ window: NSWindow) -> Bool {
        (window.isVisible || window.isMiniaturized)
            && window.styleMask.contains(.titled)
            && !(window is NSPanel)
            && window.sheetParent == nil
            && !window.className.contains("StatusBar")
            && !window.className.contains("MenuBarExtra")
    }
}
