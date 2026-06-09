import AppKit
import CoreImage
import Foundation
import Observation
import SwiftUI
import SwiftyDropbox

@MainActor
@Observable
final class SongStore {
    var projects: [ProjectReference] = []
    var sortMode: LibrarySortMode = .recent
    var availableFolders: [FolderRef] = []
    var albumArt: [UUID: NSImage] = [:]
    /// Most recent .als/bounce modification date per project. Drives
    /// the "Recent" sort on the grid (same as iOS).
    var activityDates: [UUID: Date] = [:]
    var errorMessage: String?
    var isLoadingPicker = false

    // MARK: Audio + notes state (mirrors iOS)
    var notes: [UUID: [Note]] = [:]
    var starred: [UUID: Bool] = [:]
    /// Per-song "don't draw the title on the grid card" preference.
    /// Mac-local — iOS doesn't have an equivalent concept yet so we
    /// don't push this into NotesDocument.
    var hideTitle: [UUID: Bool] = [:]
    /// Per-song workflow status. Mirrors iOS — canonical store is the
    /// `LibraryEntry` on Dropbox. Missing keys resolve to `.inProgress`
    /// at read time so legacy songs land in the top group.
    var status: [UUID: SongStatus] = [:]
    var selectedAudioPath: [UUID: String] = [:]
    /// Newest-bounce modDate captured when each project's audio was
    /// pinned. A sticky pin auto-releases once a bounce newer than this
    /// appears. See `resolveAudio`.
    var pinWatermark: [UUID: Date] = [:]
    var audioFiles: [UUID: [AudioFileMeta]] = [:]
    var presentingFullPlayer: Bool = false
    let audio = AudioService()
    let waveform = WaveformService()

    private(set) var source: DropboxProjectSource?
    private let registryURL: URL
    private var artInFlight: Set<UUID> = []
    private var notesInFlight: Set<UUID> = []

    var isAuthorized: Bool { source != nil }

    init() {
        let url = Self.defaultRegistryURL()
        self.registryURL = url
        do {
            self.source = try DropboxProjectSource(storageURL: url)
        } catch {
            self.source = nil
        }
        loadFromDisk(at: url)
        activityDates = Self.loadActivityDatesFromDisk()
        starred = Self.loadStarredFromDisk()
        hideTitle = Self.loadHideTitleFromDisk()
        status = Self.loadStatusFromDisk()
        selectedAudioPath = Self.loadSelectedAudioFromDisk()
        pinWatermark = Self.loadPinWatermarkFromDisk()
        if source != nil {
            Task { [weak self] in await self?.pullLibraryFromDropbox() }
            Task { [weak self] in await self?.refreshActivityDates() }
        }
    }

    /// Rebuild the source after the OAuth manager's Keychain is populated
    /// (called when `.dropboxAuthDidChange` fires). Mirrors iOS.
    @discardableResult
    func rebuildSourceFromKeychain() -> Bool {
        do {
            self.source = try DropboxProjectSource(storageURL: registryURL)
        } catch {
            self.source = nil
            handleDropboxError(error)
            return false
        }
        Task { [weak self] in await self?.pullLibraryFromDropbox() }
        Task { [weak self] in await self?.refreshActivityDates() }
        return true
    }

    private func handleDropboxError(_ error: Error) {
        if let dbx = error as? DropboxProjectSource.DropboxSourceError, case .authExpired = dbx {
            self.source = nil
            errorMessage = dbx.localizedDescription
            return
        }
        errorMessage = error.localizedDescription
    }

    // MARK: - Local registry cache

    private static func defaultRegistryURL() -> URL {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appending(path: "Adenel Songs")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "projects.json")
    }

    private func loadFromDisk(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ProjectReference].self, from: data) else {
            return
        }
        // Only keep dropbox-backed entries — legacy local-bookmark projects
        // from the old Mac app aren't reachable in the new design and would
        // confuse the picker/sort. They'll come back from Dropbox if the
        // user re-adds them through the AddSong sheet.
        self.projects = decoded.filter { project in
            if case .dropboxPath = project.location { return true }
            return false
        }
    }

    private static func activityDatesURL() -> URL {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appending(path: "Adenel Songs")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "activityDates.json")
    }

    private static func loadActivityDatesFromDisk() -> [UUID: Date] {
        guard let data = try? Data(contentsOf: activityDatesURL()),
              let raw = try? JSONDecoder().decode([String: Date].self, from: data) else {
            return [:]
        }
        var result: [UUID: Date] = [:]
        for (key, date) in raw {
            if let id = UUID(uuidString: key) { result[id] = date }
        }
        return result
    }

    private func saveActivityDates() {
        let raw = Dictionary(
            uniqueKeysWithValues: activityDates.map { ($0.key.uuidString, $0.value) }
        )
        guard let data = try? JSONEncoder().encode(raw) else { return }
        try? data.write(to: Self.activityDatesURL(), options: .atomic)
    }

    // MARK: - Sorted view

    /// The home grid's display order — a starred-first "Starred" group
    /// floats above the three status groups (in-progress, released, idle).
    /// Within each section the current sortMode (Recent / A–Z) orders
    /// the cards. Sections with zero entries are omitted so empty
    /// headers never render.
    var projectSections: [ProjectSection] {
        let base: [ProjectReference]
        switch sortMode {
        case .recent:
            base = projects.sorted { a, b in
                let ad = activityDates[a.id] ?? .distantPast
                let bd = activityDates[b.id] ?? .distantPast
                return ad > bd
            }
        case .alphabetical:
            base = projects.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }

        // Starred floats above all status groups regardless of status.
        let starredItems = base.filter { starred[$0.id] == true }
        let rest = base.filter { starred[$0.id] != true }

        var sections: [ProjectSection] = []
        if !starredItems.isEmpty {
            sections.append(ProjectSection(kind: .starred, projects: starredItems))
        }
        for s in SongStatus.allCases {
            let items = rest.filter { (status[$0.id] ?? .inProgress) == s }
            if !items.isEmpty {
                sections.append(ProjectSection(kind: .status(s), projects: items))
            }
        }
        return sections
    }

    /// Flat display order, matching the visual order of `projectSections`.
    /// Used by player prev/next so navigation walks the grid as the user
    /// sees it.
    var sortedProjects: [ProjectReference] {
        projectSections.flatMap(\.projects)
    }

    // MARK: - Folder picker

    func loadAvailableFolders() async {
        guard let source else {
            errorMessage = "Dropbox not configured"
            return
        }
        isLoadingPicker = true
        errorMessage = nil
        do {
            let folders = try await source.listAvailableFolders()
            let existing = Set(projects.compactMap { project -> String? in
                if case .dropboxPath(let path) = project.location { return path.lowercased() }
                return nil
            })
            availableFolders = folders.filter { folder in
                if case .dropboxPath(let path) = folder.location {
                    return !existing.contains(path.lowercased())
                }
                return true
            }
        } catch {
            handleDropboxError(error)
        }
        isLoadingPicker = false
    }

    func addProject(folder: FolderRef) {
        let project = ProjectReference(displayName: folder.displayName, location: folder.location)
        projects.append(project)
        source?.saveRegistry(projects)
        Task { [weak self] in await self?.refreshActivityDate(for: project) }
        Task { [weak self] in await self?.pushLibraryToDropbox() }
        Task { [weak self] in await self?.loadAlbumArt(for: project) }
    }

    func removeProject(_ project: ProjectReference) {
        projects.removeAll { $0.id == project.id }
        source?.saveRegistry(projects)
        albumArt.removeValue(forKey: project.id)
        activityDates.removeValue(forKey: project.id)
        notes.removeValue(forKey: project.id)
        starred.removeValue(forKey: project.id)
        hideTitle.removeValue(forKey: project.id)
        status.removeValue(forKey: project.id)
        selectedAudioPath.removeValue(forKey: project.id)
        pinWatermark.removeValue(forKey: project.id)
        audioFiles.removeValue(forKey: project.id)
        saveActivityDates()
        saveStarredToDisk()
        saveHideTitleToDisk()
        saveStatusToDisk()
        saveSelectedAudioToDisk()
        savePinWatermarkToDisk()
        try? FileManager.default.removeItem(at: Self.albumArtCacheURL(for: project.id))
        waveform.invalidate(for: project.id)
        Task { [weak self] in await self?.pushLibraryToDropbox() }
    }

    // MARK: - Library sync (mirrors iOS)

    func pushLibraryToDropbox() async {
        guard let source else { return }
        let items = projects.map { project in
            LibraryEntry(
                displayName: project.displayName,
                addedAt: Date(),
                hideTitle: hideTitle[project.id] ?? false,
                status: status[project.id] ?? .inProgress
            )
        }
        let doc = LibraryDocument(modifiedAt: Date(), items: items)
        do {
            try await source.saveLibrary(doc)
        } catch {
            handleDropboxError(error)
        }
    }

    func pullLibraryFromDropbox() async {
        guard let source else { return }
        do {
            if let remote = try await source.loadLibrary() {
                reconcileLibrary(remote, source: source)
                source.saveRegistry(projects)
                // Prefetch any newly-discovered album art so the grid
                // doesn't flash placeholder gradients on first paint.
                let snapshot = projects
                for project in snapshot {
                    Task { [weak self] in await self?.loadAlbumArt(for: project) }
                }
            } else if !projects.isEmpty {
                await pushLibraryToDropbox()
            }
        } catch {
            if let dbx = error as? DropboxProjectSource.DropboxSourceError,
               case .authExpired = dbx {
                handleDropboxError(error)
            }
        }
    }

    private func reconcileLibrary(_ remote: LibraryDocument, source: DropboxProjectSource) {
        let byName = Dictionary(
            uniqueKeysWithValues: projects.map { ($0.displayName.lowercased(), $0) }
        )
        var rebuilt: [ProjectReference] = []
        var hideTitleDirty = false
        var statusDirty = false
        for entry in remote.items {
            let key = entry.displayName.lowercased()
            let project: ProjectReference
            if let existing = byName[key] {
                project = existing
            } else {
                let path = "\(source.rootPath)/\(entry.displayName)"
                project = ProjectReference(
                    displayName: entry.displayName,
                    location: .dropboxPath(path)
                )
            }
            rebuilt.append(project)
            // Pull grid display preferences off the library entry so the
            // first paint of the grid already reflects them.
            if (hideTitle[project.id] ?? false) != entry.hideTitle {
                hideTitle[project.id] = entry.hideTitle
                hideTitleDirty = true
            }
            if (status[project.id] ?? .inProgress) != entry.status {
                status[project.id] = entry.status
                statusDirty = true
            }
        }
        let keptIDs = Set(rebuilt.map(\.id))
        for project in projects where !keptIDs.contains(project.id) {
            albumArt.removeValue(forKey: project.id)
            activityDates.removeValue(forKey: project.id)
            hideTitle.removeValue(forKey: project.id)
            status.removeValue(forKey: project.id)
            try? FileManager.default.removeItem(at: Self.albumArtCacheURL(for: project.id))
            waveform.invalidate(for: project.id)
            hideTitleDirty = true
            statusDirty = true
        }
        if hideTitleDirty { saveHideTitleToDisk() }
        if statusDirty { saveStatusToDisk() }
        projects = rebuilt
    }

    // MARK: - Activity dates

    func refreshActivityDates() async {
        guard let source else { return }
        await withTaskGroup(of: (UUID, Date?).self) { group in
            for project in projects {
                guard case .dropboxPath(let path) = project.location else { continue }
                group.addTask {
                    let date = try? await source.fetchLatestActivityDate(forFolderPath: path)
                    return (project.id, date)
                }
            }
            for await (id, date) in group {
                if let date { activityDates[id] = date }
            }
        }
        saveActivityDates()
    }

    private func refreshActivityDate(for project: ProjectReference) async {
        guard let source,
              case .dropboxPath(let path) = project.location else { return }
        if let date = try? await source.fetchLatestActivityDate(forFolderPath: path) {
            activityDates[project.id] = date
            saveActivityDates()
        }
    }

    // MARK: - Album art

    private static func albumArtCacheDir() -> URL {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = cache.appending(path: "AlbumArt")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func albumArtCacheURL(for id: UUID) -> URL {
        albumArtCacheDir().appending(path: "\(id.uuidString).bin")
    }

    func loadAlbumArt(for project: ProjectReference) async {
        if albumArt[project.id] != nil { return }
        if artInFlight.contains(project.id) { return }

        let cacheURL = Self.albumArtCacheURL(for: project.id)
        if let data = try? Data(contentsOf: cacheURL),
           let image = NSImage(data: data) {
            albumArt[project.id] = image
            return
        }

        guard let source,
              case .dropboxPath(let folderPath) = project.location else { return }

        artInFlight.insert(project.id)
        defer { artInFlight.remove(project.id) }

        do {
            guard let fetched = try await source.fetchAlbumArt(forFolderPath: folderPath, songName: project.displayName),
                  let image = NSImage(data: fetched.data) else { return }
            try? fetched.data.write(to: cacheURL, options: .atomic)
            // Stamp the cache file's modification date with the Dropbox
            // file's clientModified — same trick iOS uses to detect
            // remote replacements without a sidecar file.
            try? FileManager.default.setAttributes(
                [.modificationDate: fetched.modified],
                ofItemAtPath: cacheURL.path
            )
            albumArt[project.id] = image
        } catch {
            if let dbx = error as? DropboxProjectSource.DropboxSourceError,
               case .authExpired = dbx {
                handleDropboxError(error)
            }
        }
    }

    func refreshAlbumArt(for project: ProjectReference) async {
        albumArt.removeValue(forKey: project.id)
        try? FileManager.default.removeItem(at: Self.albumArtCacheURL(for: project.id))
        await loadAlbumArt(for: project)
    }

    /// Drag-and-drop entry point on the song card. Reads the dropped
    /// image, uploads it to Dropbox at the canonical art path, then
    /// refreshes the local cache so the card repaints.
    func setAlbumArt(for project: ProjectReference, imageData data: Data, fileExtension ext: String) {
        guard let source else {
            errorMessage = "Dropbox not connected"
            return
        }
        guard case .dropboxPath(let folderPath) = project.location else { return }
        Task {
            do {
                try await source.uploadAlbumArt(
                    forFolderPath: folderPath,
                    songName: project.displayName,
                    imageData: data,
                    fileExtension: ext.isEmpty ? "png" : ext
                )
                await refreshAlbumArt(for: project)
            } catch {
                handleDropboxError(error)
            }
        }
    }

    /// On foreground, sweep every project's Dropbox `_ALBUM ART/` folder
    /// and refresh entries whose remote clientModified is newer than the
    /// local cache. Same algorithm as iOS.
    func refreshStaleAlbumArt() async {
        guard let source else { return }
        let fm = FileManager.default
        let snapshot = projects
        for project in snapshot {
            guard case .dropboxPath(let folderPath) = project.location else { continue }
            let cacheURL = Self.albumArtCacheURL(for: project.id)
            let cacheMtime = (try? fm.attributesOfItem(atPath: cacheURL.path)[.modificationDate]) as? Date

            let remoteMtime: Date?
            do {
                remoteMtime = try await source.fetchAlbumArtModified(
                    forFolderPath: folderPath,
                    songName: project.displayName
                )
            } catch {
                if let dbx = error as? DropboxProjectSource.DropboxSourceError,
                   case .authExpired = dbx {
                    handleDropboxError(error)
                    return
                }
                continue
            }

            guard let remoteMtime else { continue }
            let stale = (cacheMtime.map { remoteMtime > $0.addingTimeInterval(1) } ?? true)
            guard stale else { continue }
            await refreshAlbumArt(for: project)
        }
    }

    // MARK: - Starred / selected / pin watermark caches
    //
    // Canonical state for all three lives in the per-song NotesDocument
    // on Dropbox. These local mirrors let the home grid sort
    // starred-first and let play() resolve a pinned audio file
    // synchronously without waiting on the doc to load. Same pattern as
    // iOS (just different file names so the two apps don't fight over
    // the on-disk cache layout if they're ever on the same machine).

    private static func appSupportDir() -> URL {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appending(path: "Adenel Songs")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func starredCacheURL() -> URL {
        appSupportDir().appending(path: "macStarred.json")
    }
    private static func selectedAudioCacheURL() -> URL {
        appSupportDir().appending(path: "macSelectedAudio.json")
    }
    private static func pinWatermarkCacheURL() -> URL {
        appSupportDir().appending(path: "macPinWatermark.json")
    }
    private static func hideTitleCacheURL() -> URL {
        appSupportDir().appending(path: "macHideTitle.json")
    }
    private static func statusCacheURL() -> URL {
        appSupportDir().appending(path: "macStatus.json")
    }

    private static func loadStatusFromDisk() -> [UUID: SongStatus] {
        guard let data = try? Data(contentsOf: statusCacheURL()),
              let dict = try? JSONDecoder().decode([String: SongStatus].self, from: data) else { return [:] }
        var out: [UUID: SongStatus] = [:]
        for (key, value) in dict {
            if let id = UUID(uuidString: key) { out[id] = value }
        }
        return out
    }
    private func saveStatusToDisk() {
        let dict = Dictionary(uniqueKeysWithValues: status.map { ($0.key.uuidString, $0.value) })
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: Self.statusCacheURL(), options: .atomic)
    }

    /// Set the workflow status for a project. Updates the local mirror
    /// (instant grid regrouping) and pushes the LibraryDocument so iOS
    /// + future devices pick up the change.
    func setStatus(_ newStatus: SongStatus, for project: ProjectReference) {
        status[project.id] = newStatus
        saveStatusToDisk()
        Task { [weak self] in await self?.pushLibraryToDropbox() }
    }

    private static func loadHideTitleFromDisk() -> [UUID: Bool] {
        guard let data = try? Data(contentsOf: hideTitleCacheURL()),
              let dict = try? JSONDecoder().decode([String: Bool].self, from: data) else { return [:] }
        var out: [UUID: Bool] = [:]
        for (key, value) in dict {
            if let id = UUID(uuidString: key) { out[id] = value }
        }
        return out
    }
    private func saveHideTitleToDisk() {
        let dict = Dictionary(uniqueKeysWithValues: hideTitle.map { ($0.key.uuidString, $0.value) })
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: Self.hideTitleCacheURL(), options: .atomic)
    }

    /// Flip the per-song "draw title on the grid" preference. Local
    /// mirror for instant UI; canonical value lives in the
    /// `LibraryDocument` on Dropbox so iOS picks it up with the same
    /// pull that brings the song list.
    func toggleHideTitle(_ project: ProjectReference) {
        hideTitle[project.id] = !(hideTitle[project.id] ?? false)
        saveHideTitleToDisk()
        Task { [weak self] in await self?.pushLibraryToDropbox() }
    }

    private static func loadStarredFromDisk() -> [UUID: Bool] {
        guard let data = try? Data(contentsOf: starredCacheURL()),
              let dict = try? JSONDecoder().decode([String: Bool].self, from: data) else { return [:] }
        var out: [UUID: Bool] = [:]
        for (key, value) in dict {
            if let id = UUID(uuidString: key) { out[id] = value }
        }
        return out
    }
    private func saveStarredToDisk() {
        let dict = Dictionary(uniqueKeysWithValues: starred.map { ($0.key.uuidString, $0.value) })
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: Self.starredCacheURL(), options: .atomic)
    }

    private static func loadSelectedAudioFromDisk() -> [UUID: String] {
        guard let data = try? Data(contentsOf: selectedAudioCacheURL()),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        var out: [UUID: String] = [:]
        for (key, value) in dict {
            if let id = UUID(uuidString: key) { out[id] = value }
        }
        return out
    }
    private func saveSelectedAudioToDisk() {
        let dict = Dictionary(uniqueKeysWithValues: selectedAudioPath.map { ($0.key.uuidString, $0.value) })
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: Self.selectedAudioCacheURL(), options: .atomic)
    }

    private static func loadPinWatermarkFromDisk() -> [UUID: Date] {
        guard let data = try? Data(contentsOf: pinWatermarkCacheURL()),
              let dict = try? JSONDecoder().decode([String: Date].self, from: data) else { return [:] }
        var out: [UUID: Date] = [:]
        for (key, value) in dict {
            if let id = UUID(uuidString: key) { out[id] = value }
        }
        return out
    }
    private func savePinWatermarkToDisk() {
        let dict = Dictionary(uniqueKeysWithValues: pinWatermark.map { ($0.key.uuidString, $0.value) })
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: Self.pinWatermarkCacheURL(), options: .atomic)
    }

    // MARK: - Notes data layer (mirrors iOS)

    /// Pull a project's NotesDocument from Dropbox and hydrate the local
    /// mirrors. Phase 2 uses this only for the pin/selection data; the
    /// notes UI lands in Phase 3. Quietly swallows non-auth errors — a
    /// transient pull failure shouldn't surface as a toast since play()
    /// kicks this off in the background.
    func loadNotes(for project: ProjectReference) async {
        guard let source else { return }
        if notesInFlight.contains(project.id) { return }
        notesInFlight.insert(project.id)
        defer { notesInFlight.remove(project.id) }

        do {
            let doc = try await source.loadNotes(for: project)
            notes[project.id] = doc.notes
            if starred[project.id] != doc.starred {
                starred[project.id] = doc.starred
                saveStarredToDisk()
            }
            if selectedAudioPath[project.id] != doc.selectedAudioPath {
                selectedAudioPath[project.id] = doc.selectedAudioPath
                saveSelectedAudioToDisk()
            }
            if pinWatermark[project.id] != doc.pinWatermark {
                pinWatermark[project.id] = doc.pinWatermark
                savePinWatermarkToDisk()
            }
        } catch {
            notes[project.id] = []
        }
    }

    private func persistDoc(for project: ProjectReference, source: DropboxProjectSource) async {
        let doc = NotesDocument(
            notes: notes[project.id] ?? [],
            starred: starred[project.id] ?? false,
            selectedAudioPath: selectedAudioPath[project.id],
            pinWatermark: pinWatermark[project.id]
        )
        do {
            try await source.saveNotes(doc, for: project)
        } catch {
            handleDropboxError(error)
        }
    }

    // MARK: - Note CRUD (mirrors iOS)

    func addNote(_ note: Note, to project: ProjectReference) async {
        guard let source else { return }
        var stamped = note
        // Stamp the note with the version that's currently loaded so the
        // per-version filter on the timeline can hide it once the song
        // moves to a newer .als/bounce.
        if stamped.version == nil {
            stamped.version = audio.currentVersion
        }
        var current = notes[project.id] ?? []
        current.append(stamped)
        current.sort { $0.time < $1.time }
        notes[project.id] = current
        await persistDoc(for: project, source: source)
    }

    func removeNote(_ note: Note, from project: ProjectReference) async {
        guard let source else { return }
        var current = notes[project.id] ?? []
        current.removeAll { $0.id == note.id }
        notes[project.id] = current
        await persistDoc(for: project, source: source)
    }

    /// Replace by id, or append if not found — never silently drops an
    /// edit when the local mirror is stale.
    func updateNote(_ note: Note, in project: ProjectReference) async {
        guard let source else { return }
        var current = notes[project.id] ?? []
        if let idx = current.firstIndex(where: { $0.id == note.id }) {
            current[idx] = note
        } else {
            current.append(note)
        }
        current.sort { $0.time < $1.time }
        notes[project.id] = current
        await persistDoc(for: project, source: source)
    }

    func toggleStarred(_ project: ProjectReference) async {
        starred[project.id] = !(starred[project.id] ?? false)
        saveStarredToDisk()
        guard let source else { return }
        await persistDoc(for: project, source: source)
    }

    // MARK: - Audio file selection

    func loadAudioFiles(for project: ProjectReference) async {
        guard let source else { return }
        guard case .dropboxPath(let folderPath) = project.location else { return }
        do {
            let files = try await source.listAudioFiles(forFolderPath: folderPath)
            audioFiles[project.id] = files
        } catch {
            handleDropboxError(error)
        }
    }

    /// Pin a specific audio file and reload playback. The pin auto-releases
    /// once a bounce newer than the watermark appears — see resolveAudio.
    func selectAudioFile(_ file: AudioFileMeta, for project: ProjectReference) async {
        guard let source else { return }
        selectedAudioPath[project.id] = file.relativePath
        pinWatermark[project.id] = await newestBounceModDate(for: project, source: source) ?? .distantPast
        saveSelectedAudioToDisk()
        savePinWatermarkToDisk()
        await persistDoc(for: project, source: source)
        await loadAndPlay(project: project, autoStart: audio.isPlaying)
    }

    /// Clear an explicit pin and return to latest-bounce behavior.
    func clearAudioSelection(for project: ProjectReference) async {
        guard let source else { return }
        await releasePin(for: project, source: source)
        await loadAndPlay(project: project, autoStart: audio.isPlaying)
    }

    private func releasePin(for project: ProjectReference, source: DropboxProjectSource) async {
        selectedAudioPath[project.id] = nil
        pinWatermark[project.id] = nil
        saveSelectedAudioToDisk()
        savePinWatermarkToDisk()
        await persistDoc(for: project, source: source)
    }

    private func newestBounceModDate(for project: ProjectReference, source: DropboxProjectSource) async -> Date? {
        if let cached = audioFiles[project.id]?.filter({ !$0.isMaster }).map(\.modDate).max() {
            return cached
        }
        guard case .dropboxPath(let folderPath) = project.location else { return nil }
        return await source.latestBounce(forFolderPath: folderPath)?.modDate
    }

    // MARK: - Playback

    /// Main entry. Tapping a song on the grid lands here.
    func play(_ project: ProjectReference, autoStart: Bool = false, showPlayer: Bool = true) async {
        if audio.nowPlaying?.id == project.id {
            if autoStart && !audio.isPlaying { audio.resume() }
            if showPlayer { presentingFullPlayer = true }
            return
        }
        guard case .dropboxPath(let folderPath) = project.location else { return }

        audio.preparePlayback(for: project)
        if showPlayer { presentingFullPlayer = true }

        if let source {
            do {
                if let bounce = try await resolveAudio(source: source, project: project, folderPath: folderPath) {
                    guard audio.nowPlaying?.id == project.id else { return }
                    let playbackURL = cachedOrStream(bounce: bounce, project: project)
                    audio.load(url: playbackURL, project: project, filename: bounce.filename, artwork: albumArt[project.id], autoStart: autoStart)
                    Task { [weak self] in
                        guard let self else { return }
                        await self.waveform.loadWaveform(for: project, audioURL: playbackURL, audioKey: bounce.filename)
                    }
                    Task { [weak self] in
                        guard let self else { return }
                        await self.loadNotes(for: project)
                    }
                    Task { [weak self] in
                        guard let self else { return }
                        await self.loadAudioFiles(for: project)
                    }
                    return
                }
            } catch {
                // Fall through to offline cache.
            }
        }

        if let cached = cachedLocalAudio(for: project) {
            guard audio.nowPlaying?.id == project.id else { return }
            audio.load(url: cached.url, project: project, filename: cached.filename, artwork: albumArt[project.id], autoStart: autoStart)
            Task { [weak self] in
                guard let self else { return }
                await self.waveform.loadWaveform(for: project, audioURL: cached.url, audioKey: cached.filename)
            }
            return
        }

        errorMessage = source == nil
            ? "Dropbox not connected and no offline copy of \(project.displayName)"
            : "Can't reach Dropbox and no offline copy of \(project.displayName)"
        audio.stop()
        presentingFullPlayer = false
    }

    func playNext() async { await playRelative(by: 1) }
    func playPrevious() async { await playRelative(by: -1) }

    private func playRelative(by offset: Int) async {
        let list = sortedProjects
        guard !list.isEmpty,
              let currentID = audio.nowPlaying?.id,
              let idx = list.firstIndex(where: { $0.id == currentID }) else { return }
        let n = list.count
        let nextIdx = ((idx + offset) % n + n) % n
        let target = list[nextIdx]
        if target.id == currentID { return }
        await play(target, autoStart: audio.isPlaying, showPlayer: false)
    }

    /// On foreground, re-resolve the currently loaded song and reload it
    /// if a newer bounce appeared or the bytes were replaced. Quiet on
    /// failure — keep playing whatever's already loaded.
    func refreshCurrentAudio() async {
        guard let project = audio.nowPlaying,
              case .dropboxPath(let folderPath) = project.location,
              let source else { return }
        do {
            guard let resolved = try await resolveAudio(source: source, project: project, folderPath: folderPath) else { return }
            let filenameChanged = resolved.filename != audio.currentTrackFilename
            let cachedMod = AudioCache.shared.remoteModified(projectID: project.id, filename: resolved.filename)
            let contentChanged = cachedMod.map { resolved.modDate > $0.addingTimeInterval(1) } ?? true
            guard (filenameChanged || contentChanged),
                  audio.nowPlaying?.id == project.id else { return }
            let playbackURL = cachedOrStream(bounce: resolved, project: project)
            audio.load(url: playbackURL, project: project, filename: resolved.filename, artwork: albumArt[project.id], autoStart: audio.isPlaying)
            Task { [weak self] in
                guard let self else { return }
                await self.waveform.loadWaveform(for: project, audioURL: playbackURL, audioKey: resolved.filename)
            }
            Task { [weak self] in
                guard let self else { return }
                await self.loadAudioFiles(for: project)
            }
        } catch {
            // Swallow — keep playing whatever's loaded.
        }
    }

    /// Pinned file (if still valid + still newest enough) wins over the
    /// latest bounce. Watermark is the newest-bounce mod date at the time
    /// of pinning — a strictly-newer bounce releases the pin.
    private func resolveAudio(
        source: DropboxProjectSource,
        project: ProjectReference,
        folderPath: String
    ) async throws -> (url: URL, filename: String, relativePath: String, modDate: Date)? {
        if let selected = selectedAudioPath[project.id] {
            if let latest = await source.latestBounce(forFolderPath: folderPath) {
                if let watermark = pinWatermark[project.id] {
                    if latest.modDate > watermark.addingTimeInterval(1) {
                        await releasePin(for: project, source: source)
                        return try await source.fetchLatestBounceURL(forFolderPath: folderPath)
                    }
                } else {
                    // Legacy pin (no watermark): adopt current latest so it
                    // tracks newer bounces from here on, instead of staying
                    // pinned forever.
                    pinWatermark[project.id] = latest.modDate
                    savePinWatermarkToDisk()
                    await persistDoc(for: project, source: source)
                }
            }
            if let result = try await source.fetchAudioURL(forFolderPath: folderPath, relativePath: selected) {
                return (result.url, result.filename, selected, result.modDate)
            }
            // fetchAudioURL returns nil for both "file gone" and "network
            // down". Don't clobber the pin on transient failures.
        }
        return try await source.fetchLatestBounceURL(forFolderPath: folderPath)
    }

    /// Reloads audio for an already-presented player after selection change.
    private func loadAndPlay(project: ProjectReference, autoStart: Bool) async {
        guard case .dropboxPath(let folderPath) = project.location else { return }
        if let source {
            do {
                if let bounce = try await resolveAudio(source: source, project: project, folderPath: folderPath) {
                    guard audio.nowPlaying?.id == project.id else { return }
                    let playbackURL = cachedOrStream(bounce: bounce, project: project)
                    audio.load(url: playbackURL, project: project, filename: bounce.filename, artwork: albumArt[project.id], autoStart: autoStart)
                    Task { [weak self] in
                        guard let self else { return }
                        await self.waveform.loadWaveform(for: project, audioURL: playbackURL, audioKey: bounce.filename)
                    }
                    return
                }
            } catch {}
        }
        if let cached = cachedLocalAudio(for: project) {
            guard audio.nowPlaying?.id == project.id else { return }
            audio.load(url: cached.url, project: project, filename: cached.filename, artwork: albumArt[project.id], autoStart: autoStart)
            Task { [weak self] in
                guard let self else { return }
                await self.waveform.loadWaveform(for: project, audioURL: cached.url, audioKey: cached.filename)
            }
            return
        }
        errorMessage = "No offline copy of \(project.displayName)"
    }

    /// Cache hit returns the local URL; cache miss kicks off a background
    /// download and returns the streaming URL so playback can start
    /// immediately. Detects same-name remote replacements (rebouncing
    /// over an existing version) via the cached vs remote modDate.
    private func cachedOrStream(
        bounce: (url: URL, filename: String, relativePath: String, modDate: Date),
        project: ProjectReference
    ) -> URL {
        let cachedMod = AudioCache.shared.remoteModified(projectID: project.id, filename: bounce.filename)
        let isStale = cachedMod.map { bounce.modDate > $0.addingTimeInterval(1) } ?? true
        if isStale {
            AudioCache.shared.invalidate(projectID: project.id, filename: bounce.filename)
            waveform.invalidate(for: project.id, audioKey: bounce.filename)
        }
        if let local = AudioCache.shared.localURL(projectID: project.id, filename: bounce.filename) {
            return local
        }
        Task.detached { [filename = bounce.filename, remote = bounce.url, id = project.id, mod = bounce.modDate] in
            _ = try? await AudioCache.shared.download(from: remote, projectID: id, filename: filename, remoteModified: mod)
        }
        return bounce.url
    }

    /// Offline-only lookup, used when Dropbox is unreachable. Prefers the
    /// selected file if cached; falls back to whatever's most recently
    /// cached for this project.
    private func cachedLocalAudio(for project: ProjectReference) -> (url: URL, filename: String)? {
        if let relativePath = selectedAudioPath[project.id] {
            let filename = (relativePath as NSString).lastPathComponent
            if let url = AudioCache.shared.localURL(projectID: project.id, filename: filename) {
                return (url, filename)
            }
        }
        if let url = AudioCache.shared.latestCachedURL(projectID: project.id) {
            return (url, url.lastPathComponent)
        }
        return nil
    }

    // MARK: - Mac-only local actions

    /// Resolve the song folder to a local URL via `LocalDropboxFinder`,
    /// or nil if Dropbox isn't syncing this folder to disk. Static so
    /// views can also query it (to decide whether to grey out the
    /// Finder / Ableton / New Version menu items).
    static func localFolderURL(for project: ProjectReference) -> URL? {
        guard case .dropboxPath(let path) = project.location else { return nil }
        return LocalDropboxFinder.localURL(forDropboxPath: path)
    }

    /// Reveal the song folder in Finder. Surfaces a toast if Dropbox
    /// isn't syncing this song locally.
    func showInFinder(_ project: ProjectReference) {
        guard let url = Self.localFolderURL(for: project) else {
            errorMessage = notLocalErrorMessage(for: project)
            return
        }
        FileActions.showInFinder(url)
    }

    /// Open the latest `.als` in Ableton.
    func openLatestALS(for project: ProjectReference) {
        guard let url = Self.localFolderURL(for: project) else {
            errorMessage = notLocalErrorMessage(for: project)
            return
        }
        if !FileActions.openLatestALS(in: url) {
            errorMessage = "No .als files in \(project.displayName)."
        }
    }

    /// Suggested next version for the "Create New Version" field, derived
    /// from the most recently modified `.als` in the song folder. Empty
    /// string when the folder isn't synced locally or has no `.als`, so
    /// the field just starts blank in that case.
    func suggestedNextVersion(for project: ProjectReference) -> String {
        guard let url = Self.localFolderURL(for: project),
              let suggestion = FileActions.suggestedNextVersion(in: url) else {
            return ""
        }
        return suggestion
    }

    /// Duplicate the latest `.als` with a new version number. After the
    /// duplicate lands on disk, refresh this project's activity date so
    /// the Recent sort surfaces it. When `openAfter` is true, the new file
    /// is opened in Ableton once it's written.
    func duplicateLatestALS(for project: ProjectReference, version: String, openAfter: Bool = false) {
        guard let url = Self.localFolderURL(for: project) else {
            errorMessage = notLocalErrorMessage(for: project)
            return
        }
        let trimmed = version.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter a version number."
            return
        }
        do {
            guard let newURL = try FileActions.duplicateLatestALS(in: url, version: trimmed) else {
                errorMessage = "No .als files in \(project.displayName)."
                return
            }
            if openAfter {
                FileActions.open(newURL)
            }
            Task { [weak self] in await self?.refreshActivityDate(for: project) }
        } catch {
            errorMessage = "Couldn't create version: \(error.localizedDescription)"
        }
    }

    private func notLocalErrorMessage(for project: ProjectReference) -> String {
        if LocalDropboxFinder.detectRoot() == nil {
            return "Dropbox isn't synced to this Mac. Install Dropbox locally to enable Finder and Ableton actions."
        }
        return "\(project.displayName) isn't synced to this Mac yet."
    }
}

/// Same enum as iOS so Mac and iOS can share UI patterns. Lives in the
/// macOS target's SongStore file because Phase 1 doesn't move SongStore
/// itself to Shared/ (the iOS version still owns audio/notes/voice
/// fields that don't apply here).
enum LibrarySortMode: String, CaseIterable, Identifiable {
    case recent = "Recent"
    case alphabetical = "A–Z"
    var id: Self { self }
}
