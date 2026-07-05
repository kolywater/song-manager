import AppKit

/// Mac-only file actions on a locally-resolved song folder. Each operation
/// takes a `URL` for the song's root folder — that URL is expected to come
/// from `LocalDropboxFinder.localURL(forDropboxPath:)` so we know the path
/// is actually on disk. iOS never calls into here; it has no native
/// Ableton or Finder.
enum FileActions {
    /// A single `.als` file at the root of a song folder, paired with the
    /// display suffix that follows the song name ("[version] [notes]",
    /// e.g. "1.2 chris feedback") and its parsed version components.
    struct ALSVersion: Hashable {
        let url: URL
        let label: String
        let version: [Int]
    }

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

    /// Duplicate the latest `.als` with a new version number. Derives the
    /// base name by stripping the version token *and* anything after it
    /// from the source filename, so "Song 1.2.als" → "Song 1.3.als" and
    /// "Song 1.2 chris feedback.als" → "Song 1.3.als" (the new version
    /// starts from a clean name). Throws on filesystem errors; returns nil
    /// if no .als exists.
    @discardableResult
    static func duplicateLatestALS(in rootURL: URL, version: String) throws -> URL? {
        guard let latestALS = latestALS(in: rootURL) else { return nil }
        let stem = latestALS.deletingPathExtension().lastPathComponent
        let baseName = VersionService.splitVersion(fromStem: stem).base
        let newFilename = "\(baseName) \(version).als"
        let destinationURL = rootURL.appending(path: newFilename)
        try FileManager.default.copyItem(at: latestALS, to: destinationURL)
        return destinationURL
    }

    /// Filenames of the up-to-`limit` most recently modified `.als` files
    /// at the root of `rootURL`, ordered oldest → newest. Shown for
    /// reference in the "Create New Version" dialog so the user can see
    /// what's already there. Returns stems (no `.als` extension); empty if
    /// none.
    static func recentALSStems(in rootURL: URL, limit: Int = 5) -> [String] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return contents
            .filter { $0.pathExtension.lowercased() == "als" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
            .prefix(limit)             // the `limit` newest…
            .reversed()                // …shown oldest → newest
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    /// Every `.als` at the root of `rootURL`, sorted highest-version
    /// first. Versions are parsed by `VersionService`; each entry carries
    /// the stem suffix after the song name ("[version] [notes]") for
    /// display. This is the single source of truth for "latest" and
    /// "previous" — `latestALS` is just its first element.
    static func alsVersions(in rootURL: URL) -> [ALSVersion] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return contents
            .filter { $0.pathExtension.lowercased() == "als" }
            .map { url in
                let stem = url.deletingPathExtension().lastPathComponent
                return ALSVersion(
                    url: url,
                    label: VersionService.versionSuffix(fromStem: stem),
                    version: VersionService.parseVersion(fromStem: stem) ?? []
                )
            }
            .sorted { VersionService.compare($0.version, $1.version) == .orderedDescending }
    }

    /// Highest-versioned `.als` at the root of `rootURL`, or nil if none.
    private static func latestALS(in rootURL: URL) -> URL? {
        alsVersions(in: rootURL).first?.url
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
