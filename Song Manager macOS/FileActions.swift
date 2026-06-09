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

    /// Open an arbitrary file (e.g. a freshly-created version) in its
    /// default app. Returns false if the open failed.
    @discardableResult
    static func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    /// Suggested next version string for this song, based on the most
    /// recently *modified* `.als` at the root — that's the file the user
    /// was last working on, regardless of how its version number sorts.
    /// Bumps the final component at whatever decimal precision the latest
    /// file uses ("Song 1.1" → "1.2", "Song 1.1.1" → "1.1.2"). Returns
    /// nil if there are no `.als` files; "1.0" if the latest one has no
    /// parseable version suffix.
    static func suggestedNextVersion(in rootURL: URL) -> String? {
        guard let latest = latestModifiedALS(in: rootURL) else { return nil }
        let stem = latest.deletingPathExtension().lastPathComponent
        guard let version = VersionService.parseVersion(fromStem: stem) else { return "1.0" }
        return VersionService.suggestedBump(from: version)
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

    /// Most recently modified `.als` at the root of `rootURL`. Used to
    /// derive the suggested next version — the latest file you touched is
    /// a more reliable "current version" signal than version-number sort.
    private static func latestModifiedALS(in rootURL: URL) -> URL? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return contents
            .filter { $0.pathExtension.lowercased() == "als" }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
    }
}
