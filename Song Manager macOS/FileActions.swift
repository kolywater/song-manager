import AppKit

/// Mac-only file actions on a locally-resolved song folder. Each operation
/// takes a `URL` for the song's root folder — that URL is expected to come
/// from `LocalDropboxFinder.localURL(forDropboxPath:)` so we know the path
/// is actually on disk. iOS never calls into here; it has no native
/// Ableton or Finder.
enum FileActions {
    /// Reveal the song folder in Finder.
    static func showInFinder(_ rootURL: URL) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: rootURL.path(percentEncoded: false))
    }

    /// Open the highest-numbered `.als` in Ableton (or whatever app the
    /// user has set as the default for the .als extension). Returns false
    /// if no .als files were found in the folder.
    @discardableResult
    static func openLatestALS(in rootURL: URL) -> Bool {
        guard let latestALS = latestALS(in: rootURL) else { return false }
        return NSWorkspace.shared.open(latestALS)
    }

    /// Duplicate the latest `.als` with a new version number. Strips any
    /// trailing version-like suffix from the source filename before
    /// appending the new version, so "Song 1.2.als" → "Song 1.3.als"
    /// rather than "Song 1.2 1.3.als". Throws on filesystem errors;
    /// returns nil if no .als exists.
    @discardableResult
    static func duplicateLatestALS(in rootURL: URL, version: String) throws -> URL? {
        guard let latestALS = latestALS(in: rootURL) else { return nil }
        let stem = latestALS.deletingPathExtension().lastPathComponent
        let baseName = String(stem).replacing(VersionService.versionPattern, with: "")
            .trimmingCharacters(in: .whitespaces)
        let newFilename = "\(baseName) \(version).als"
        let destinationURL = rootURL.appending(path: newFilename)
        try FileManager.default.copyItem(at: latestALS, to: destinationURL)
        return destinationURL
    }

    /// Highest-versioned `.als` at the root of `rootURL`. Versions are
    /// parsed by `VersionService`; ties (or unparseable stems) fall back
    /// to lexicographic order.
    private static func latestALS(in rootURL: URL) -> URL? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return contents
            .filter { $0.pathExtension.lowercased() == "als" }
            .max { a, b in
                let stemA = a.deletingPathExtension().lastPathComponent
                let stemB = b.deletingPathExtension().lastPathComponent
                let vA = VersionService.parseVersion(fromStem: stemA) ?? []
                let vB = VersionService.parseVersion(fromStem: stemB) ?? []
                return VersionService.compare(vA, vB) == .orderedAscending
            }
    }
}
