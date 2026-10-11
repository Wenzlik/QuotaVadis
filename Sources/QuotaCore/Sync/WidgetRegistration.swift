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
        let folder = bundle.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath().path
        return folder == "/Applications" || folder == home.appendingPathComponent("Applications").resolvingSymlinksInPath().path
    }

    /// Paths LaunchServices has registered for `bundleID`, read from `lsregister -dump Bundle` filtered to its
    /// `path:` and `identifier:` lines. Unlike `NSWorkspace.urlsForApplications` this includes copies whose files are
    /// gone (a deleted archive, an ejected DMG, Sparkle's unpacked update) — the ones that keep breaking chronod.
    public static func registeredPaths(bundleID: String, dump: String) -> [String] {
        var path: String?
        var found: [String] = []
        for line in dump.split(separator: "\n") {
            if line.hasPrefix("path:") {
                // "path:                       /Applications/QuotaVadis.app (0x663c)"
                var value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if let suffix = value.range(of: #" \(0x[0-9a-fA-F]+\)$"#, options: .regularExpression) { value.removeSubrange(suffix) }
                path = value
            } else if line.hasPrefix("identifier:") {
                if line.dropFirst(11).trimmingCharacters(in: .whitespaces) == bundleID, let path, !found.contains(path) {
                    found.append(path)
                }
                path = nil
            }
        }
        return found
    }

    /// Registrations the running installed copy drops: every build product, archive, DMG and ghost. Another installed
    /// copy that still exists is left alone — the running one wins by registering itself last, and two installs
    /// don't unregister each other back and forth on every launch.
    ///
    /// The dump's identifier is only trusted for ghosts. A path that exists is checked as it is now — LaunchServices
    /// may remember a path whose files have since been replaced by another app — and through its symlinks, so an
    /// alias of the running app or of the other install is protected like the app itself.
    public static func copiesToUnregister(running bundle: URL, bundleID: String, registered: [String],
                                          exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                                          identifier: (String) -> String? = currentIdentifier,
                                          home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let me = bundle.standardizedFileURL.resolvingSymlinksInPath().path
        return registered.filter { path in
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            guard exists(url.path) else { return true }
            return url.path != me && !isInstalled(url, home: home) && identifier(url.path) == bundleID
        }
    }

    /// `CFBundleIdentifier` of the bundle at `path` as it is on disk now; nil when it cannot be read.
    public static func currentIdentifier(_ path: String) -> String? {
        NSDictionary(contentsOfFile: path + "/Contents/Info.plist")?["CFBundleIdentifier"] as? String
    }
}
#endif
