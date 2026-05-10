import AppKit
import Observation
import SwiftUI

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

    private let source: LocalProjectSource

    private static func defaultStorageURL() -> URL {
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
        self.source = LocalProjectSource(storageURL: Self.defaultStorageURL())
        load()
        if let raw = UserDefaults.standard.string(forKey: "sortMode"),
           let mode = SortMode(rawValue: raw) {
            sortMode = mode
        }
    }

    // MARK: - Persistence

    func load() {
        projects = (try? source.loadProjects()) ?? []
        for i in projects.indices {
            albumArtCache[projects[i].id] = source.loadAlbumArt(for: &projects[i])
        }
    }

    func save() {
        saveRegistry()
        for project in projects {
            guard let url = resolveBookmark(for: project) else { continue }
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }

            let meta = SongMetadata(selectedMasterFilename: project.selectedMasterFilename, gradientHue: project.gradientHue)
            source.saveSongMetadata(meta, to: url)
        }
    }

    private func saveRegistry() {
        source.saveRegistry(projects)
    }

    // MARK: - Add / Remove

    func addProject() {
        let folders = (try? source.listAvailableFolders()) ?? []
        guard let folder = folders.first else { return }

        var project = ProjectReference(displayName: folder.displayName, location: folder.location)
        source.scan(&project)

        if let url = source.resolveBookmark(for: &project) {
            if url.startAccessingSecurityScopedResource() {
                defer { url.stopAccessingSecurityScopedResource() }
                source.saveSongMetadata(SongMetadata(), to: url)
            }
            albumArtCache[project.id] = source.loadAlbumArt(for: &project)
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
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else {
            var copy = project
            return source.resolveBookmark(for: &copy)
        }
        let oldLocation = projects[idx].location
        let url = source.resolveBookmark(for: &projects[idx])
        if projects[idx].location != oldLocation {
            saveRegistry()
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
                source.saveSongMetadata(meta, to: url)
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
        let oldLocation = projects[index].location
        source.scan(&projects[index])
        albumArtCache[projects[index].id] = source.loadAlbumArt(for: &projects[index])
        if projects[index].location != oldLocation {
            saveRegistry()
        }
    }
}
