import AppKit
import Observation
import SwiftUI

private let songMetadataFilename = "SongManagerData.json"
private let notesFilename = "_NOTES.md"

enum SortMode: String, CaseIterable {
    case custom = "Custom"
    case alphabetical = "Alphabetical"
    case latestModified = "Last Modified"
}

@Observable
final class ProjectStore {
    var projects: [ProjectReference] = []
    var sortMode: SortMode = .custom
    var albumArtCache: [UUID: NSImage] = [:]
    var errorMessage: String?

    private var storageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appending(path: "Adenel Songs")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "projects.json")
    }

    var sortedProjects: [ProjectReference] {
        switch sortMode {
        case .custom:
            return projects
        case .alphabetical:
            return projects.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .latestModified:
            return projects.sorted { a, b in
                switch (a.latestALSModDate, b.latestALSModDate) {
                case let (dateA?, dateB?): return dateA > dateB
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return false
                }
            }
        }
    }

    init() {
        load()
        if let raw = UserDefaults.standard.string(forKey: "sortMode"),
           let mode = SortMode(rawValue: raw) {
            sortMode = mode
        }
    }

    // MARK: - Per-Song Metadata Helpers

    private func songMetadataURL(for rootURL: URL) -> URL {
        rootURL.appending(path: songMetadataFilename)
    }

    private func loadSongMetadata(from rootURL: URL) -> SongMetadata? {
        let url = songMetadataURL(for: rootURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SongMetadata.self, from: data)
    }

    private func saveSongMetadata(_ metadata: SongMetadata, to rootURL: URL) {
        let url = songMetadataURL(for: rootURL)
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

        if let art = ProjectScanner.loadAlbumArt(from: scanResult.albumArtURL) {
            albumArtCache[project.id] = art
        }
    }

    // MARK: - Persistence

    func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path(percentEncoded: false)),
              let data = try? Data(contentsOf: storageURL)
        else { return }

        if let registry = try? JSONDecoder().decode(ProjectRegistry.self, from: data) {
            projects = registry.entries.map { entry in
                ProjectReference(id: entry.id, displayName: "", location: entry.location)
            }
            for i in projects.indices {
                rescanProject(at: i)
            }
            return
        }

        if let legacy = try? JSONDecoder().decode([ProjectReference].self, from: data) {
            projects = legacy
            for i in projects.indices {
                migrateAndRescan(at: i)
            }
            saveRegistry()
        }
    }

    private func migrateAndRescan(at index: Int) {
        let project = projects[index]
        guard let url = resolveBookmark(for: project) else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        if project.selectedMasterFilename != nil {
            let meta = SongMetadata(selectedMasterFilename: project.selectedMasterFilename, gradientHue: project.gradientHue)
            saveSongMetadata(meta, to: url)
        }

        populateScannedFields(&projects[index], rootURL: url)
    }

    func save() {
        saveRegistry()
        for project in projects {
            guard let url = resolveBookmark(for: project) else { continue }
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }

            let meta = SongMetadata(selectedMasterFilename: project.selectedMasterFilename, gradientHue: project.gradientHue)
            saveSongMetadata(meta, to: url)
        }
    }

    private func saveRegistry() {
        let entries = projects.map { ProjectRegistry.Entry(id: $0.id, location: $0.location) }
        let registry = ProjectRegistry(entries: entries)
        guard let data = try? JSONEncoder().encode(registry) else { return }
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
        var project = ProjectReference(displayName: name, location: .localBookmark(bookmark))

        if url.startAccessingSecurityScopedResource() {
            defer { url.stopAccessingSecurityScopedResource() }
            populateScannedFields(&project, rootURL: url)
            saveSongMetadata(SongMetadata(), to: url)
        }

        projects.append(project)
        save()
    }

    func removeProject(_ project: ProjectReference) {
        projects.removeAll { $0.id == project.id }
        albumArtCache.removeValue(forKey: project.id)
        save()
    }

    func moveProject(from: IndexSet, to: Int) {
        projects.move(fromOffsets: from, toOffset: to)
    }

    // MARK: - Bookmark Resolution

    func resolveBookmark(for project: ProjectReference) -> URL? {
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
            if let idx = projects.firstIndex(where: { $0.id == project.id }) {
                projects[idx].location = .localBookmark(newBookmark)
                saveRegistry()
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

        if let url = resolveBookmark(for: project) {
            if url.startAccessingSecurityScopedResource() {
                defer { url.stopAccessingSecurityScopedResource() }
                let meta = SongMetadata(selectedMasterFilename: filename, gradientHue: projects[idx].gradientHue)
                saveSongMetadata(meta, to: url)
            }
        }
        saveRegistry()
    }

    func changeColor(for project: ProjectReference) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[idx].gradientHue = Double.random(in: 0..<1)
        save()
    }

    func loadNotes(for project: ProjectReference) -> String {
        guard let url = resolveBookmark(for: project) else { return "" }
        guard url.startAccessingSecurityScopedResource() else { return "" }
        defer { url.stopAccessingSecurityScopedResource() }
        let notesURL = url.appending(path: notesFilename)
        var content = ""
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: notesURL, options: [], error: &error) { u in
            content = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
        }
        return content
    }

    func saveNotes(for project: ProjectReference, text: String) {
        guard let url = resolveBookmark(for: project) else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        let notesURL = url.appending(path: notesFilename)
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: notesURL, options: .forReplacing, error: &error) { u in
            try? text.write(to: u, atomically: true, encoding: .utf8)
        }
    }

    func notesFileInfo(for project: ProjectReference) -> (rootURL: URL, notesURL: URL)? {
        guard let url = resolveBookmark(for: project) else { return nil }
        return (url, url.appending(path: notesFilename))
    }

    func setAlbumArt(for project: ProjectReference, imageURL: URL) {
        guard let url = resolveBookmark(for: project) else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        let artFolder = url.appending(path: "_ALBUM ART")
        try? FileManager.default.createDirectory(at: artFolder, withIntermediateDirectories: true)

        let dest = artFolder.appending(path: imageURL.lastPathComponent)
        try? FileManager.default.copyItem(at: imageURL, to: dest)

        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            rescanProject(at: idx)
        }
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
            projects[idx].latestALSModDate = Date()
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

        populateScannedFields(&projects[index], rootURL: url)
    }
}
