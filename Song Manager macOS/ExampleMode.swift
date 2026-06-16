import AppKit

/// Local "example project" launch mode for the Mac app. Activated by the
/// `SM_EXAMPLE_PATH` environment variable (set by `just example`), which
/// points at a *copy* of the repo's `example project/` folder. It lets the
/// app be driven against a real Ableton project with no Dropbox — and,
/// because `just example` points it at a throwaway copy, creating new
/// versions in the UI never mutates the committed fixture.
///
/// When active, `SongStore` skips Dropbox entirely and shows this single
/// project; album art and audio are read straight off disk.
enum ExampleMode {
    /// The example song folder, or nil when not in example mode. Resolved
    /// once from the environment; nil unless the path exists and is a
    /// directory.
    static let folderURL: URL? = {
        guard let path = ProcessInfo.processInfo.environment["SM_EXAMPLE_PATH"],
              !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return url
    }()

    static var isActive: Bool { folderURL != nil }

    /// The single project shown in example mode. Stable UUID so cached
    /// state (album art, etc.) keys stay consistent across launches. The
    /// `.dropboxPath` location is never resolved through Dropbox —
    /// `SongStore.localFolderURL` short-circuits to `folderURL` whenever
    /// example mode is active.
    static func project() -> ProjectReference? {
        guard let url = folderURL else { return nil }
        return ProjectReference(
            id: UUID(uuidString: "E8A11D1E-0000-0000-0000-000000000001")!,
            displayName: url.lastPathComponent,
            location: .dropboxPath(url.lastPathComponent)
        )
    }

    /// First image inside the folder's `_ALBUM ART` subfolder, if any.
    static func albumArtURL() -> URL? {
        contents(of: "_ALBUM ART", extensions: ["jpg", "jpeg", "png", "heic", "gif", "tiff"])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    /// Highest-versioned bounce in the `bounces` subfolder, for playback.
    static func latestBounceURL() -> URL? {
        contents(of: "bounces", extensions: ["wav", "aif", "aiff", "mp3", "m4a", "flac"])
            .max { a, b in
                let va = VersionService.parseVersion(fromStem: a.deletingPathExtension().lastPathComponent) ?? []
                let vb = VersionService.parseVersion(fromStem: b.deletingPathExtension().lastPathComponent) ?? []
                return VersionService.compare(va, vb) == .orderedAscending
            }
    }

    /// Files with one of `extensions` directly inside `subfolder`.
    private static func contents(of subfolder: String, extensions: Set<String>) -> [URL] {
        guard let folder = folderURL else { return [] }
        let dir = folder.appending(path: subfolder)
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return items.filter { extensions.contains($0.pathExtension.lowercased()) }
    }
}
