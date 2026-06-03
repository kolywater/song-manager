import Foundation

/// Probes the macOS filesystem for a synced Dropbox folder. When a song
/// folder is present locally we can do native-feeling Mac actions on it
/// (Reveal in Finder, open the latest .als in Ableton, duplicate it with
/// a bumped version) without going through the Dropbox API. When nothing
/// is found, the calling UI hides those actions and falls back to SDK-only.
///
/// iOS never calls this — it has no real filesystem access to Dropbox and
/// always uses the SDK path. The file lives in `Shared/` only because the
/// helpers are pure Foundation and there's no harm in cross-compiling.
enum LocalDropboxFinder {

    /// Probable locations of the Dropbox sync root on Mac. Order matters —
    /// the modern `~/Library/CloudStorage/` paths win over the legacy
    /// `~/Dropbox` symlink because the legacy path often points at the new
    /// location on freshly upgraded systems anyway.
    private static let candidateRoots: [String] = [
        "~/Library/CloudStorage/Dropbox",
        "~/Library/CloudStorage/Dropbox-Personal",
        "~/Dropbox",
    ]

    /// First candidate root that exists, or nil. Results are not cached —
    /// the call is cheap (a few `stat`s) and we want to pick up the folder
    /// the moment the user signs into Dropbox.app.
    static func detectRoot() -> URL? {
        let fm = FileManager.default
        for candidate in candidateRoots {
            let path = (candidate as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return nil
    }

    /// Resolve a Dropbox-relative path (e.g. `/music/aidenel songs/Song X`)
    /// to a local URL if and only if the folder/file exists on disk. Returns
    /// nil when there's no local Dropbox at all OR when the specific path
    /// isn't synced yet (Smart Sync, selective sync, deselected).
    static func localURL(forDropboxPath path: String) -> URL? {
        guard let root = detectRoot() else { return nil }
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = root.appending(path: trimmed, directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
