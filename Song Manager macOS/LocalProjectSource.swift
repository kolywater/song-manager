import AppKit

private let songMetadataFilename = "SongManagerData.json"

@MainActor
final class LocalProjectSource: ProjectSource {
    let storageURL: URL

    init(storageURL: URL) {
        self.storageURL = storageURL
    }

    func loadProjects() throws -> [ProjectReference] {
        guard FileManager.default.fileExists(atPath: storageURL.path(percentEncoded: false)),
              let data = try? Data(contentsOf: storageURL)
        else { return [] }

        var projects: [ProjectReference] = []
        if let registry = try? JSONDecoder().decode(ProjectRegistry.self, from: data) {
            projects = registry.entries.map { entry in
                ProjectReference(id: entry.id, displayName: "", location: entry.location)
            }
        } else if let legacy = try? JSONDecoder().decode([ProjectReference].self, from: data) {
            projects = legacy
        }

        for i in projects.indices {
            scan(&projects[i])
        }
        return projects
    }

    func listAvailableFolders() throws -> [FolderRef] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select an Ableton Live project folder"

        guard panel.runModal() == .OK, let url = panel.url else { return [] }
        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return [] }

        return [FolderRef(
            id: url.path(percentEncoded: false),
            displayName: url.lastPathComponent,
            location: .localBookmark(bookmark)
        )]
    }

    func saveRegistry(_ projects: [ProjectReference]) {
        let entries = projects.map { ProjectRegistry.Entry(id: $0.id, location: $0.location) }
        let registry = ProjectRegistry(entries: entries)
        guard let data = try? JSONEncoder().encode(registry) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }

    func scan(_ project: inout ProjectReference) {
        guard let url = resolveBookmark(for: &project) else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        populateScannedFields(&project, rootURL: url)
    }

    func resolveBookmark(for project: inout ProjectReference) -> URL? {
        guard case .localBookmark(let bookmark) = project.location else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        if isStale, let newBookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            project.location = .localBookmark(newBookmark)
        }
        return url
    }

    func loadAlbumArt(for project: inout ProjectReference) -> NSImage? {
        guard let url = resolveBookmark(for: &project) else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        let scanResult = ProjectScanner.scan(rootURL: url)
        return ProjectScanner.loadAlbumArt(from: scanResult.albumArtURL)
    }

    func loadSongMetadata(from rootURL: URL) -> SongMetadata? {
        let url = rootURL.appending(path: songMetadataFilename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SongMetadata.self, from: data)
    }

    func saveSongMetadata(_ metadata: SongMetadata, to rootURL: URL) {
        let url = rootURL.appending(path: songMetadataFilename)
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func populateScannedFields(_ project: inout ProjectReference, rootURL: URL) {
        project.displayName = rootURL.lastPathComponent

        let scanResult = ProjectScanner.scan(rootURL: rootURL)

        if let latestALS = scanResult.alsFiles.last {
            let stem = latestALS.deletingPathExtension().lastPathComponent
            if let version = VersionService.parseVersion(fromStem: stem) {
                project.latestVersionString = version.map(String.init).joined(separator: ".")
            }
            project.latestALSModDate = (try? latestALS.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        project.latestBounceFilename = scanResult.bounceFiles.last?.lastPathComponent
        project.albumArtFilename = scanResult.albumArtURL?.lastPathComponent
        project.hasMastersFolder = scanResult.hasMastersFolder
        project.masterFilenames = scanResult.masterFiles.map(\.lastPathComponent)

        if let meta = loadSongMetadata(from: rootURL) {
            project.selectedMasterFilename = meta.selectedMasterFilename
            project.gradientHue = meta.gradientHue
        }
    }
}
