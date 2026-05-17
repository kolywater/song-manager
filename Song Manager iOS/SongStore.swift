import CoreImage
import Foundation
import Observation
import SwiftUI
import SwiftyDropbox
import UIKit

enum LibrarySortMode: String, CaseIterable, Identifiable {
    case recent = "Recent"
    case alphabetical = "A–Z"
    var id: Self { self }
}

@MainActor
@Observable
final class SongStore {
    var projects: [ProjectReference] = []
    var sortMode: LibrarySortMode = .recent
    var availableFolders: [FolderRef] = []
    var albumArt: [UUID: UIImage] = [:]
    // Luminance is computed alongside the tint color in summarize() but
    // nothing reads it right now (pill text is uniformly white).
    // var artLuminance: [UUID: Double] = [:]
    /// Average color of the album art. Used to tint the pill's glass
    /// material so it picks up the dominant hue of the artwork.
    var artTintColor: [UUID: Color] = [:]
    /// Most recent .als/bounce modification date per project. Drives
    /// the "Recent" sort on the grid.
    var activityDates: [UUID: Date] = [:]
    var errorMessage: String?
    var isLoadingPicker = false
    var presentingFullPlayer: Bool = false
    var notes: [UUID: [Note]] = [:]
    var starred: [UUID: Bool] = [:]
    var selectedAudioPath: [UUID: String] = [:]
    var audioFiles: [UUID: [AudioFileMeta]] = [:]
    let audio = AudioService()
    let waveform = WaveformService()

    private(set) var source: DropboxProjectSource?
    private let registryURL: URL
    private var artInFlight: Set<UUID> = []
    private var notesInFlight: Set<UUID> = []

    var isAuthorized: Bool { source != nil }

    /// Centralizes Dropbox error handling. On auth expiry we drop the
    /// source so `isAuthorized` flips false and `ContentView` re-presents
    /// the Connect sheet. Any error message is surfaced via the toast.
    private func handleDropboxError(_ error: Error) {
        if let dbx = error as? DropboxProjectSource.DropboxSourceError, case .authExpired = dbx {
            self.source = nil
            errorMessage = dbx.localizedDescription
            return
        }
        errorMessage = error.localizedDescription
    }

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
        selectedAudioPath = Self.loadSelectedAudioFromDisk()
        if source != nil {
            Task { [weak self] in
                await self?.refreshActivityDates()
            }
            Task { [weak self] in
                await self?.prefetchProjectStates()
            }
        }
    }

    /// One-shot fan-out fetch of every project's NotesDocument. Hydrates
    /// `starred` and `selectedAudioPath` from Dropbox so a fresh device
    /// (or freshly-wiped app) sees its cross-device state without having
    /// to open each player. Local mirrors persist; subsequent launches
    /// read those instantly and this just reconciles.
    func prefetchProjectStates() async {
        await withTaskGroup(of: Void.self) { group in
            for project in projects {
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.loadNotes(for: project)
                }
            }
        }
    }

    /// Rebuilds the project source after the OAuth manager's Keychain is
    /// populated (called on .dropboxAuthDidChange). Returns whether a
    /// source could be built.
    @discardableResult
    func rebuildSourceFromKeychain() -> Bool {
        do {
            self.source = try DropboxProjectSource(storageURL: registryURL)
        } catch {
            self.source = nil
            handleDropboxError(error)
            return false
        }
        Task { [weak self] in await self?.refreshActivityDates() }
        Task { [weak self] in await self?.prefetchProjectStates() }
        return true
    }

    private static func defaultRegistryURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appending(path: "iosProjects.json")
    }

    private static func starredCacheURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appending(path: "iosStarred.json")
    }

    private static func selectedAudioCacheURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appending(path: "iosSelectedAudio.json")
    }

    /// Local mirror of NotesDocument.selectedAudioPath, keyed by project
    /// UUID. Lets play() resolve the chosen file synchronously without
    /// waiting on Dropbox.
    private static func loadSelectedAudioFromDisk() -> [UUID: String] {
        guard let data = try? Data(contentsOf: selectedAudioCacheURL()),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
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

    /// Local-only cache of starred state, keyed by project UUID. The
    /// canonical store is the per-song NotesDocument on Dropbox; this
    /// mirror keeps the home grid able to sort starred-first without
    /// fetching every song's doc on launch.
    private static func loadStarredFromDisk() -> [UUID: Bool] {
        guard let data = try? Data(contentsOf: starredCacheURL()),
              let dict = try? JSONDecoder().decode([String: Bool].self, from: data)
        else { return [:] }
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

    private static func albumArtCacheDir() -> URL {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = cache.appending(path: "AlbumArt")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func albumArtCacheURL(for id: UUID) -> URL {
        albumArtCacheDir().appending(path: "\(id.uuidString).bin")
    }

    private func applyArtSummary(_ image: UIImage, projectID: UUID) {
        guard let summary = Self.summarize(image) else { return }
        // artLuminance[projectID] = summary.luminance
        artTintColor[projectID] = summary.color
    }

    /// Average color + luminance of the entire image, derived from a
    /// single CIAreaAverage pass.
    private static func summarize(_ image: UIImage) -> (color: Color, luminance: Double)? {
        guard let cgImage = image.cgImage else { return nil }
        let ciImage = CIImage(cgImage: cgImage)
        let extent = ciImage.extent
        let inputExtent = CIVector(x: extent.origin.x, y: extent.origin.y, z: extent.size.width, w: extent.size.height)
        guard let filter = CIFilter(
            name: "CIAreaAverage",
            parameters: [kCIInputImageKey: ciImage, kCIInputExtentKey: inputExtent]
        ), let output = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(
            output,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        let r = Double(bitmap[0]) / 255.0
        let g = Double(bitmap[1]) / 255.0
        let b = Double(bitmap[2]) / 255.0
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        let color = Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
        return (color, luminance)
    }

    private func loadFromDisk(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ProjectReference].self, from: data) else {
            return
        }
        self.projects = decoded
    }

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
        Task { [weak self] in
            await self?.refreshActivityDate(for: project)
        }
    }

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

    private static func activityDatesURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appending(path: "activityDates.json")
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

    func removeProject(_ project: ProjectReference) {
        projects.removeAll { $0.id == project.id }
        source?.saveRegistry(projects)
        albumArt.removeValue(forKey: project.id)
        // artLuminance.removeValue(forKey: project.id)
        artTintColor.removeValue(forKey: project.id)
        activityDates.removeValue(forKey: project.id)
        saveActivityDates()
        try? FileManager.default.removeItem(at: Self.albumArtCacheURL(for: project.id))
        waveform.invalidate(for: project.id)
    }

    func refreshAlbumArt(for project: ProjectReference) async {
        albumArt.removeValue(forKey: project.id)
        try? FileManager.default.removeItem(at: Self.albumArtCacheURL(for: project.id))
        await loadAlbumArt(for: project)
    }

    func play(_ project: ProjectReference, autoStart: Bool = false, showPlayer: Bool = true) async {
        // If this is the same song already loaded, just resume / open as
        // requested.
        if audio.nowPlaying?.id == project.id {
            if autoStart && !audio.isPlaying { audio.resume() }
            if showPlayer { presentingFullPlayer = true }
            return
        }
        guard case .dropboxPath(let folderPath) = project.location else { return }

        // Present the player immediately with project info; audio prepares
        // in the background.
        audio.preparePlayback(for: project)
        if showPlayer { presentingFullPlayer = true }

        // Online path: resolve via Dropbox, then play (cache-first via
        // cachedOrStream). On failure (offline / auth gone) we fall
        // through to the local-cache fallback below.
        if let source {
            do {
                if let bounce = try await resolveAudio(source: source, project: project, folderPath: folderPath) {
                    guard audio.nowPlaying?.id == project.id else { return }
                    let playbackURL = cachedOrStream(bounce: bounce, project: project)
                    audio.load(url: playbackURL, project: project, filename: bounce.filename, artwork: albumArt[project.id], autoStart: autoStart)
                    Task { [weak self] in
                        guard let self else { return }
                        await self.waveform.loadWaveform(for: project, audioURL: playbackURL)
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
                // Swallow; try the offline cache fallback before surfacing.
            }
        }

        // Offline fallback: play whatever we have cached for this song.
        if let cached = cachedLocalAudio(for: project) {
            guard audio.nowPlaying?.id == project.id else { return }
            audio.load(url: cached.url, project: project, filename: cached.filename, artwork: albumArt[project.id], autoStart: autoStart)
            Task { [weak self] in
                guard let self else { return }
                await self.waveform.loadWaveform(for: project, audioURL: cached.url)
            }
            return
        }

        errorMessage = source == nil
            ? "Dropbox not connected and no offline copy of \(project.displayName)"
            : "Can't reach Dropbox and no offline copy of \(project.displayName)"
        audio.stop()
        presentingFullPlayer = false
    }

    // MARK: - Sort + navigation

    /// The home grid's display order, also used by player prev/next.
    /// Starred items partition to the top under either sort mode.
    var sortedProjects: [ProjectReference] {
        let base: [ProjectReference]
        switch sortMode {
        case .recent:
            base = projects.sorted {
                let a = activityDates[$0.id] ?? .distantPast
                let b = activityDates[$1.id] ?? .distantPast
                return a > b
            }
        case .alphabetical:
            base = projects.sorted {
                $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
            }
        }
        let starredFirst = base.filter { starred[$0.id] == true }
        let rest = base.filter { starred[$0.id] != true }
        return starredFirst + rest
    }

    func playNext() async {
        await playRelative(by: 1)
    }

    func playPrevious() async {
        await playRelative(by: -1)
    }

    private func playRelative(by offset: Int) async {
        let list = sortedProjects
        guard !list.isEmpty,
              let currentID = audio.nowPlaying?.id,
              let idx = list.firstIndex(where: { $0.id == currentID })
        else { return }
        let n = list.count
        let nextIdx = ((idx + offset) % n + n) % n
        let target = list[nextIdx]
        if target.id == currentID { return }
        await play(target, autoStart: audio.isPlaying, showPlayer: false)
    }

    // MARK: - Notes

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
        } catch {
            notes[project.id] = []
        }
    }

    func addNote(_ note: Note, to project: ProjectReference) async {
        guard let source else { return }
        var stamped = note
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

    /// Replace an existing note in place (matched by id). Falls back to
    /// append if the note isn't found, so a stale edit session doesn't
    /// silently lose changes.
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

    private func persistDoc(for project: ProjectReference, source: DropboxProjectSource) async {
        let doc = NotesDocument(
            notes: notes[project.id] ?? [],
            starred: starred[project.id] ?? false,
            selectedAudioPath: selectedAudioPath[project.id]
        )
        do {
            try await source.saveNotes(doc, for: project)
        } catch {
            handleDropboxError(error)
        }
    }

    // MARK: - Audio file selection

    /// List all bounces + masters for a project. Cached after the first
    /// fetch; call again to refresh.
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

    /// Persist the user's audio choice for a project and reload playback
    /// from the new file.
    func selectAudioFile(_ file: AudioFileMeta, for project: ProjectReference) async {
        guard let source else { return }
        selectedAudioPath[project.id] = file.relativePath
        saveSelectedAudioToDisk()
        await persistDoc(for: project, source: source)
        await loadAndPlay(project: project, autoStart: audio.isPlaying)
    }

    /// Reloads audio for an already-presented player, honoring the
    /// current `selectedAudioPath`.
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
                        await self.waveform.loadWaveform(for: project, audioURL: playbackURL)
                    }
                    return
                }
            } catch {
                // Fall through to offline cache fallback.
            }
        }

        if let cached = cachedLocalAudio(for: project) {
            guard audio.nowPlaying?.id == project.id else { return }
            audio.load(url: cached.url, project: project, filename: cached.filename, artwork: albumArt[project.id], autoStart: autoStart)
            Task { [weak self] in
                guard let self else { return }
                await self.waveform.loadWaveform(for: project, audioURL: cached.url)
            }
            return
        }

        errorMessage = "No offline copy of \(project.displayName)"
    }

    /// Resolve which audio to play for a given project. If the user has
    /// picked a file (and it still exists), use that; otherwise fall back
    /// to the latest bounce — same default the Mac uses when no master is
    /// selected.
    private func resolveAudio(
        source: DropboxProjectSource,
        project: ProjectReference,
        folderPath: String
    ) async throws -> (url: URL, filename: String, relativePath: String)? {
        if let selected = selectedAudioPath[project.id] {
            if let result = try await source.fetchAudioURL(forFolderPath: folderPath, relativePath: selected) {
                return (result.url, result.filename, selected)
            }
            // fetchAudioURL swallows errors and returns nil for both "file
            // is gone" and "network is down". Don't clobber the selection
            // on transient failures — the user can clear it manually via
            // the file picker if it's truly missing.
        }
        return try await source.fetchLatestBounceURL(forFolderPath: folderPath)
    }

    /// Offline-only lookup: prefers the explicit selection if cached,
    /// else falls back to whatever's most recently cached for this song.
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

    /// Cache hit returns the local URL; cache miss kicks off a background
    /// download and returns the streaming URL.
    private func cachedOrStream(
        bounce: (url: URL, filename: String, relativePath: String),
        project: ProjectReference
    ) -> URL {
        if let local = AudioCache.shared.localURL(projectID: project.id, filename: bounce.filename) {
            return local
        }
        Task.detached { [filename = bounce.filename, remote = bounce.url, id = project.id] in
            _ = try? await AudioCache.shared.download(from: remote, projectID: id, filename: filename)
        }
        return bounce.url
    }

    // MARK: - Album art

    func loadAlbumArt(for project: ProjectReference) async {
        if albumArt[project.id] != nil { return }
        if artInFlight.contains(project.id) { return }

        // Try disk cache first.
        let cacheURL = Self.albumArtCacheURL(for: project.id)
        if let data = try? Data(contentsOf: cacheURL),
           let image = UIImage(data: data) {
            albumArt[project.id] = image
            // Skip applyArtSummary — the only consumer (pillOverlay) is hidden.
            return
        }

        guard let source,
              case .dropboxPath(let folderPath) = project.location else { return }

        artInFlight.insert(project.id)
        defer { artInFlight.remove(project.id) }

        do {
            guard let fetched = try await source.fetchAlbumArt(forFolderPath: folderPath, songName: project.displayName),
                  let image = UIImage(data: fetched.data) else { return }
            try? fetched.data.write(to: cacheURL, options: .atomic)
            // Stamp the cache file's modification date with the
            // Dropbox file's clientModified so we can later compare
            // against the remote without storing a sidecar.
            try? FileManager.default.setAttributes(
                [.modificationDate: fetched.modified],
                ofItemAtPath: cacheURL.path
            )
            albumArt[project.id] = image
            // Note: skipping applyArtSummary — the only consumer (pillOverlay) is hidden.
        } catch {
            // Non-auth errors here are silent — placeholder remains
            // visible. Auth expiry, however, needs to surface so the
            // user can reconnect.
            if let dbx = error as? DropboxProjectSource.DropboxSourceError,
               case .authExpired = dbx {
                handleDropboxError(error)
            }
        }
    }

    /// For every project, list its `_ALBUM ART/` folder and check
    /// whether the chosen file's `clientModified` is newer than the
    /// local cache file's mtime. If so, drop the cache + redownload.
    /// Quiet on errors — this runs in the background and the user
    /// shouldn't see anything fail just because they opened the app
    /// without Dropbox connectivity.
    func refreshStaleAlbumArt() async {
        guard let source else { return }
        let fm = FileManager.default
        // Snapshot the project list before suspending; the array may
        // change while we're iterating.
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
                    await MainActor.run { handleDropboxError(error) }
                    return
                }
                continue
            }

            guard let remoteMtime else { continue }
            // Refresh when there's no cache OR remote is newer than
            // what we last downloaded. Allow a 1-second slop because
            // filesystem mtimes round and Dropbox dates don't.
            let stale = (cacheMtime.map { remoteMtime > $0.addingTimeInterval(1) } ?? true)
            guard stale else { continue }
            await refreshAlbumArt(for: project)
        }
    }
}
