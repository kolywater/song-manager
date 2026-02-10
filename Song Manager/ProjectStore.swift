import AppKit
import Observation

@Observable
final class ProjectStore {
    var projects: [ProjectReference] = []
    var albumArtCache: [UUID: NSImage] = [:]
    var errorMessage: String?

    private var storageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appending(path: "Adenel Songs")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "projects.json")
    }

    init() {
        load()
    }

    // MARK: - Persistence

    func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path(percentEncoded: false)),
              let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([ProjectReference].self, from: data)
        else { return }
        projects = decoded
        for i in projects.indices {
            rescanProject(at: i)
        }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }

    // MARK: - Add / Remove

    func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select an Ableton Live project folder"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            errorMessage = "Failed to create bookmark for folder"
            return
        }

        let name = url.lastPathComponent
        var project = ProjectReference(displayName: name, rootBookmark: bookmark)

        // Scan immediately
        if url.startAccessingSecurityScopedResource() {
            defer { url.stopAccessingSecurityScopedResource() }
            let scanResult = ProjectScanner.scan(rootURL: url)
            if let latestALS = scanResult.alsFiles.last {
                let stem = latestALS.deletingPathExtension().lastPathComponent
                if let version = VersionService.parseVersion(fromStem: stem) {
                    project.latestVersionString = version.map(String.init).joined(separator: ".")
                }
            }
            project.latestBounceFilename = scanResult.bounceFiles.last?.lastPathComponent
            project.albumArtFilename = scanResult.albumArtURL?.lastPathComponent
            project.hasMastersFolder = scanResult.hasMastersFolder
            project.masterFilenames = scanResult.masterFiles.map(\.lastPathComponent)
            if let art = ProjectScanner.loadAlbumArt(from: scanResult.albumArtURL) {
                albumArtCache[project.id] = art
            }
        }

        projects.append(project)
        save()
    }

    func removeProject(_ project: ProjectReference) {
        projects.removeAll { $0.id == project.id }
        albumArtCache.removeValue(forKey: project.id)
        save()
    }

    // MARK: - Bookmark Resolution

    func resolveBookmark(for project: ProjectReference) -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: project.rootBookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        if isStale, let newBookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            if let idx = projects.firstIndex(where: { $0.id == project.id }) {
                projects[idx].rootBookmark = newBookmark
                save()
            }
        }
        return url
    }

    // MARK: - Actions

    func showInFinder(for project: ProjectReference) {
        guard let url = resolveBookmark(for: project) else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        FileActions.showInFinder(url)
    }

    func openProject(for project: ProjectReference) {
        guard let url = resolveBookmark(for: project) else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        FileActions.openLatestALS(in: url)
    }

    func latestBounceURL(for project: ProjectReference) -> (rootURL: URL, bounceURL: URL)? {
        guard let url = resolveBookmark(for: project) else {
            errorMessage = "Cannot access \(project.displayName) — bookmark expired"
            return nil
        }
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = "Cannot access \(project.displayName) — permission denied"
            return nil
        }
        defer { url.stopAccessingSecurityScopedResource() }
        let scanResult = ProjectScanner.scan(rootURL: url)
        guard let bounce = scanResult.bounceFiles.last else {
            errorMessage = "No audio files found in bounces/"
            return nil
        }
        return (url, bounce)
    }

    func selectedMasterURL(for project: ProjectReference) -> (rootURL: URL, masterURL: URL)? {
        guard let filename = project.selectedMasterFilename else { return nil }
        guard let url = resolveBookmark(for: project) else {
            errorMessage = "Cannot access \(project.displayName) — bookmark expired"
            return nil
        }
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = "Cannot access \(project.displayName) — permission denied"
            return nil
        }
        defer { url.stopAccessingSecurityScopedResource() }
        let masterURL = url.appending(path: "_MASTERS").appending(path: filename)
        guard FileManager.default.fileExists(atPath: masterURL.path(percentEncoded: false)) else {
            errorMessage = "Master file \"\(filename)\" no longer exists"
            return nil
        }
        return (url, masterURL)
    }

    func setSelectedMaster(for project: ProjectReference, filename: String) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[idx].selectedMasterFilename = filename
        save()
    }

    func suggestedVersion(for project: ProjectReference) -> String {
        guard let version = project.latestVersionString,
              let parts = VersionService.parseVersion(fromStem: "x \(version)") else {
            return "1"
        }
        return VersionService.suggestedBump(from: parts)
    }

    func duplicateLatestALS(for project: ProjectReference, version: String) {
        guard let url = resolveBookmark(for: project) else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        _ = try? FileActions.duplicateLatestALS(in: url, version: version)

        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            rescanProject(at: idx)
            save()
        }
    }

    // MARK: - Scanning

    func refresh() {
        for i in projects.indices {
            rescanProject(at: i)
        }
        save()
    }

    private func rescanProject(at index: Int) {
        let project = projects[index]
        guard let url = resolveBookmark(for: project) else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        projects[index].displayName = url.lastPathComponent

        let scanResult = ProjectScanner.scan(rootURL: url)

        if let latestALS = scanResult.alsFiles.last {
            let stem = latestALS.deletingPathExtension().lastPathComponent
            if let version = VersionService.parseVersion(fromStem: stem) {
                projects[index].latestVersionString = version.map(String.init).joined(separator: ".")
            }
        }
        projects[index].latestBounceFilename = scanResult.bounceFiles.last?.lastPathComponent
        projects[index].albumArtFilename = scanResult.albumArtURL?.lastPathComponent
        projects[index].hasMastersFolder = scanResult.hasMastersFolder
        projects[index].masterFilenames = scanResult.masterFiles.map(\.lastPathComponent)

        if let art = ProjectScanner.loadAlbumArt(from: scanResult.albumArtURL) {
            albumArtCache[project.id] = art
        }
    }
}
