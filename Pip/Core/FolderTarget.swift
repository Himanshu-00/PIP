import AppKit

/// Which folder the user means.
///
/// The one Finder is showing. Making the user pick a folder they are already
/// looking at is exactly the kind of friction this whole app exists to
/// remove. (A folder picker fallback used to live here; nothing called it.)
@MainActor
enum FolderTarget {

    /// The Finder folder, but only when Finder is the app in front.
    ///
    /// Scoping to whatever window Finder happens to have open *somewhere* is
    /// the kind of cleverness that fails silently: you press ⌥F from a
    /// browser, the search quietly narrows to a folder you last looked at on
    /// Tuesday, and a file you know exists doesn't appear. Nothing about that
    /// announces itself.
    ///
    /// If you're *in* Finder looking at a folder, searching it is obviously
    /// what you meant. Anywhere else, you meant everywhere.
    static func currentIfObvious() -> URL? {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
        else { return nil }
        return finderFolder()
    }

    /// Reuses the AppleEvents permission the app already asks for. Through
    /// `osascript`, like every other script here: in-process `NSAppleScript`
    /// is blocked by the hardened runtime without an Apple Events
    /// entitlement, so the search silently never scoped to Finder's folder.
    private static func finderFolder() -> URL? {
        guard NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.finder")
            .isEmpty == false else { return nil }

        let source = """
        tell application "Finder"
            if (count of windows) is 0 then return ""
            try
                return POSIX path of (target of front window as alias)
            on error
                return ""
            end try
        end tell
        """
        let path = ScriptBridge.osascript(source)
        guard !path.isEmpty else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
