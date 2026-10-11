import Foundation

#if os(macOS)
/// Which LaunchServices registrations of the Mac app get in the way of its widget extension.
///
/// WidgetKit (chronod) finds the widget extension through LaunchServices. Every other registered copy of the app's
/// bundle id — a release archive or export in `dist/`, a DerivedData build, a mounted DMG — is another "new
/// extension" to chronod; when it cannot tie one to its containing app it drops the installed extension "as a
/// safeguard", and a Sparkle update swaps the bundle before LaunchServices knows the new one. The desktop widgets
/// then stop updating, or the gallery only offers the iPhone's copies. The installed app repairs this on launch.
public enum WidgetRegistration {
    /// Only a copy installed in /Applications or ~/Applications may repair registrations: a build-folder run must not
    /// unregister the copy the user actually uses.
    public static func isInstalled(_ bundle: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let folder = bundle.standardizedFileURL.deletingLastPathComponent().path
        return folder == "/Applications" || folder == home.appendingPathComponent("Applications").standardizedFileURL.path
    }

    /// Registered copies of the app other than `bundle` itself.
    public static func otherCopies(of bundle: URL, registered: [URL]) -> [URL] {
        let me = bundle.standardizedFileURL.resolvingSymlinksInPath().path
        return registered.filter { $0.standardizedFileURL.resolvingSymlinksInPath().path != me }
    }
}
#endif
