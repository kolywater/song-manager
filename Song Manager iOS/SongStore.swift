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
    /// Per-song grid preference. Mirrors Mac's hideTitle so the user can
    /// hide a song's title from either device and it sticks everywhere.
    var hideTitle: [UUID: Bool] = [:]
    /// Per-song workflow status. Canonical store is the LibraryEntry on
    /// Dropbox (same as hideTitle); this local mirror lets the grid group
    /// instantly on first paint. Missing keys resolve to `.inProgress`
    /// at read time so legacy songs land in the top group.
    var status: [UUID: SongStatus] = [:]
    var selectedAudioPath: [UUID: String] = [:]
    /// Newest-bounce modDate captured when each project's audio was
    /// pinned. A sticky pin auto-releases once a bounce newer than this
    /// appears. See `resolveAudio`.
    var pinWatermark: [UUID: Date] = [:]
    var audioFiles: [UUID: [AudioFileMeta]] = [:]
    let audio = AudioService()
    let waveform = WaveformService()

    private(set) var source: DropboxProjectSource?
    private let registryURL: URL
    private var artInFlight: Set<UUID> = []
    private var notesInFlight: Set<UUID> = []
    /// Dropbox `rev` of each song's notes file as last seen. `nil` (or
    /// absent) means "not loaded / doesn't exist" → a write starts as
    /// `.add` and self-corrects to `.update` via the conflict path.
    private var notesRev: [UUID: String?] = [:]
    /// Count of in-flight guarded Dropbox writes. `flushPendingWrites()`
    /// drains this on backgrounding so an edit can't be stranded mid-upload.
    private var pendingWrites = 0

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
        hideTitle = Self.loadHideTitleFromDisk()
        status = Self.loadStatusFromDisk()
        selectedAudioPath = Self.loadSelectedAudioFromDisk()
        pinWatermark = Self.loadPinWatermarkFromDisk()
        if source != nil {
            Task { [weak self] in
                await self?.pullLibraryFromDropbox()
            }
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
        Task { [weak self] in await self?.pullLibraryFromDropbox() }
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

    private static func pinWatermarkCacheURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appending(path: "iosPinWatermark.json")
    }

    private static func hideTitleCacheURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appending(path: "iosHideTitle.json")
    }

    private static func statusCacheURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appending(path: "iosStatus.json")
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
    /// (instant grid regrouping) and pushes the LibraryDocument so Mac
    /// + future devices pick up the change.
    func setStatus(_ newStatus: SongStatus, for project: ProjectReference) async {
        status[project.id] = newStatus
        saveStatusToDisk()
        await guardedLibraryWrite { doc in
            SyncMerge.updateEntry(project.displayName, in: &doc) { $0.status = newStatus }
        }
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

    func toggleHideTitle(_ project: ProjectReference) async {
        let newValue = !(hideTitle[project.id] ?? false)
        hideTitle[project.id] = newValue
        saveHideTitleToDisk()
        await guardedLibraryWrite { doc in
            SyncMerge.updateEntry(project.displayName, in: &doc) { $0.hideTitle = newValue }
        }
    }

    /// Local mirror of NotesDocument.pinWatermark so the sticky-pin
    /// release check has a baseline available before the Dropbox doc
    /// loads. Canonical store is the per-song NotesDocument.
    private static func loadPinWatermarkFromDisk() -> [UUID: Date] {
        guard let data = try? Data(contentsOf: pinWatermarkCacheURL()),
              let dict = try? JSONDecoder().decode([String: Date].self, from: data)
        else { return [:] }
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
        Task { [weak self] in
            guard let self else { return }
            await self.guardedLibraryWrite { doc in
                self.upsertEntry(for: project, in: &doc) { _ in }
            }
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
        hideTitle.removeValue(forKey: project.id)
        status.removeValue(forKey: project.id)
        starred.removeValue(forKey: project.id)
        selectedAudioPath.removeValue(forKey: project.id)
        pinWatermark.removeValue(forKey: project.id)
        saveActivityDates()
        saveHideTitleToDisk()
        saveStatusToDisk()
        saveStarredToDisk()
        saveSelectedAudioToDisk()
        savePinWatermarkToDisk()
        try? FileManager.default.removeItem(at: Self.albumArtCacheURL(for: project.id))
        waveform.invalidate(for: project.id)
        Task { [weak self] in
            guard let self else { return }
            await self.guardedLibraryWrite { doc in
                let key = project.displayName.lowercased()
                doc.items.removeAll { $0.id == key }
            }
        }
    }

    // MARK: - Library sync (Dropbox-backed registry)

    /// Push the current `projects` up to Dropbox as a `LibraryDocument`.
    /// Best-effort: failures surface as a toast but don't undo local
    /// state — `saveRegistry()` has already persisted the local cache.
    /// Seed/ensure every local project has a library entry, without
    /// clobbering remote field values: existing entries are left untouched,
    /// missing ones are created from in-memory state. Per-field changes go
    /// through their own guarded ops, not this.
    func pushLibraryToDropbox() async {
        let snapshot = projects
        await guardedLibraryWrite { doc in
            for project in snapshot {
                self.upsertEntry(for: project, in: &doc) { _ in }
            }
        }
    }

    /// Pull the Dropbox library and reconcile with `projects`. On first
    /// run (no `_library.json` yet) we seed it from the local registry so
    /// the cross-device handshake starts off populated.
    func pullLibraryFromDropbox() async {
        guard let source else { return }
        do {
            if let remote = try await source.loadLibraryRevisioned() {
                // One-time lift of per-song metadata into the library, then
                // reconcile against the (possibly-migrated) doc so the lifted
                // fields hydrate into memory on this same launch.
                let doc = await migrateLibraryIfNeeded(remote, source: source)
                reconcileLibrary(doc, source: source)
                source.saveRegistry(projects)
            } else if !projects.isEmpty {
                await pushLibraryToDropbox()
            }
        } catch {
            // Pull failure → keep using local cache. Only surface auth
            // errors so the Connect sheet re-presents.
            if let dbx = error as? DropboxProjectSource.DropboxSourceError,
               case .authExpired = dbx {
                handleDropboxError(error)
            }
        }
    }

    /// One-time schema v1 → v2 migration: lift each song's per-song metadata
    /// (starred / selectedAudioPath / pinWatermark) out of its legacy combined
    /// notes file into the matching `LibraryEntry`, strip the notes file to
    /// notes-only, then bump the library schema and push it. Idempotent and
    /// fully rev-guarded — a conflict or transient failure simply leaves the
    /// schema below current so the next pull retries. Returns the doc to
    /// reconcile (migrated when it ran, otherwise the pulled doc unchanged).
    private func migrateLibraryIfNeeded(
        _ remote: DropboxProjectSource.Revisioned<LibraryDocument>,
        source: DropboxProjectSource
    ) async -> LibraryDocument {
        guard remote.doc.schemaVersion < LibraryDocument.currentSchemaVersion else {
            return remote.doc
        }
        var doc = remote.doc
        for i in doc.items.indices {
            let project = ProjectReference(
                displayName: doc.items[i].displayName,
                location: .dropboxPath("\(source.rootPath)/\(doc.items[i].displayName)")
            )
            guard let legacy = try? await source.loadLegacyNotesMetadata(for: project) else { continue }
            doc.items[i].starred = legacy.starred ?? false
            doc.items[i].selectedAudioPath = legacy.selectedAudioPath
            doc.items[i].pinWatermark = legacy.pinWatermark
            // Strip the per-song file to notes-only. rev-guarded, best-effort:
            // if it conflicts/fails the vestigial fields are simply ignored.
            if let notesDoc = try? await source.loadNotesRevisioned(for: project) {
                _ = try? await source.saveNotesRevisioned(
                    NotesDocument(notes: notesDoc.doc.notes), for: project, baseRev: notesDoc.rev)
            }
        }
        doc.schemaVersion = LibraryDocument.currentSchemaVersion
        doc.modifiedAt = Date()
        _ = try? await source.saveLibraryRevisioned(doc, baseRev: remote.rev)
        return doc
    }

    /// Apply the remote library to `projects`, keyed on lowercased
    /// `displayName` (the cross-device identity). Existing projects keep
    /// their UUIDs (album-art and waveform caches stay valid). New remote
    /// entries get fresh UUIDs and a synthesized `.dropboxPath`. Local
    /// entries missing from the remote are dropped along with their
    /// caches — last-writer-wins.
    private func reconcileLibrary(_ remote: LibraryDocument, source: DropboxProjectSource) {
        let byName = Dictionary(
            uniqueKeysWithValues: projects.map { ($0.displayName.lowercased(), $0) }
        )
        var rebuilt: [ProjectReference] = []
        var hideTitleDirty = false
        var statusDirty = false
        var starredDirty = false
        var selectedDirty = false
        var pinDirty = false
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
            if (hideTitle[project.id] ?? false) != entry.hideTitle {
                hideTitle[project.id] = entry.hideTitle
                hideTitleDirty = true
            }
            if (status[project.id] ?? .inProgress) != entry.status {
                status[project.id] = entry.status
                statusDirty = true
            }
            // Per-song metadata that now lives on the entry (schema v2).
            if (starred[project.id] ?? false) != entry.starred {
                starred[project.id] = entry.starred
                starredDirty = true
            }
            if selectedAudioPath[project.id] != entry.selectedAudioPath {
                selectedAudioPath[project.id] = entry.selectedAudioPath
                selectedDirty = true
            }
            if pinWatermark[project.id] != entry.pinWatermark {
                pinWatermark[project.id] = entry.pinWatermark
                pinDirty = true
            }
        }
        let keptIDs = Set(rebuilt.map(\.id))
        for project in projects where !keptIDs.contains(project.id) {
            albumArt.removeValue(forKey: project.id)
            artTintColor.removeValue(forKey: project.id)
            activityDates.removeValue(forKey: project.id)
            hideTitle.removeValue(forKey: project.id)
            status.removeValue(forKey: project.id)
            starred.removeValue(forKey: project.id)
            selectedAudioPath.removeValue(forKey: project.id)
            pinWatermark.removeValue(forKey: project.id)
            try? FileManager.default.removeItem(at: Self.albumArtCacheURL(for: project.id))
            waveform.invalidate(for: project.id)
            hideTitleDirty = true
            statusDirty = true
            starredDirty = true
            selectedDirty = true
            pinDirty = true
        }
        if hideTitleDirty { saveHideTitleToDisk() }
        if statusDirty { saveStatusToDisk() }
        if starredDirty { saveStarredToDisk() }
        if selectedDirty { saveSelectedAudioToDisk() }
        if pinDirty { savePinWatermarkToDisk() }
        projects = rebuilt
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
                // Swallow; try the offline cache fallback before surfacing.
            }
        }

        // Offline fallback: play whatever we have cached for this song.
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

    // MARK: - Sort + navigation

    /// The home grid's display order — a starred-first "Starred" group
    /// floats above the three status groups (in-progress, released, idle).
    /// Within each section the current sortMode (Recent / A–Z) orders
    /// the cards. Sections with zero entries are omitted so empty
    /// headers never render.
    var projectSections: [ProjectSection] {
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
            let result = try await source.loadNotesRevisioned(for: project)
            notes[project.id] = result.doc.notes
            notesRev[project.id] = result.rev
        } catch {
            // Leave any existing in-memory notes intact — never zero them.
            // A transient pull failure must not be able to feed an empty
            // list into the next write. starred / selectedAudioPath /
            // pinWatermark now live on the LibraryEntry (hydrated by the
            // library pull), so they're no longer touched here.
        }
    }

    func addNote(_ note: Note, to project: ProjectReference) async {
        var stamped = note
        if stamped.version == nil {
            stamped.version = audio.currentVersion
        }
        await guardedNotesWrite(for: project, op: .upsert(stamped))
    }

    func removeNote(_ note: Note, from project: ProjectReference) async {
        await guardedNotesWrite(for: project, op: .remove(note.id))
    }

    /// Edit an existing note. Replace-by-id, but **skip if the note is gone**
    /// (deleted on another device) — an edit must never resurrect it.
    func updateNote(_ note: Note, in project: ProjectReference) async {
        await guardedNotesWrite(for: project, op: .replaceIfPresent(note))
    }

    func toggleStarred(_ project: ProjectReference) async {
        let newValue = !(starred[project.id] ?? false)
        starred[project.id] = newValue
        saveStarredToDisk()
        await guardedLibraryWrite { doc in
            SyncMerge.updateEntry(project.displayName, in: &doc) { $0.starred = newValue }
        }
    }

    /// Liveness check for the open player: fetch just the notes file's `rev`
    /// and reload the notes only if it changed since we last loaded them.
    /// Skips the download (and the resulting re-render) when nothing changed.
    func refreshNotesIfChanged(for project: ProjectReference) async {
        guard let source else { return }
        // Don't reload over an in-flight local write — let it land first.
        guard pendingWrites == 0 else { return }
        guard let latest = await source.latestNotesRev(for: project) else { return }
        // A write may have started during the metadata fetch above.
        guard pendingWrites == 0 else { return }
        if latest != (notesRev[project.id] ?? nil) {
            await loadNotes(for: project)
        }
    }

    /// Conflict-safe write of a single note operation. Applies the op to the
    /// in-memory list optimistically (instant UI), then does a conditional
    /// upload. On a server-side conflict it re-pulls the current notes, adopts
    /// them as the base, and re-applies the op — so a note deleted on another
    /// device is never resurrected and no edit is lost. Retries up to 5 times.
    private func guardedNotesWrite(for project: ProjectReference, op: SyncMerge.NoteOp) async {
        guard let source else { return }
        pendingWrites += 1
        defer { pendingWrites -= 1 }
        for _ in 0..<5 {
            var working = notes[project.id] ?? []
            SyncMerge.apply(op, to: &working)
            notes[project.id] = working
            do {
                let newRev = try await source.saveNotesRevisioned(
                    NotesDocument(notes: working), for: project,
                    baseRev: notesRev[project.id] ?? nil)
                notesRev[project.id] = newRev
                return
            } catch DropboxProjectSource.DropboxSourceError.conflict {
                if let fresh = try? await source.loadNotesRevisioned(for: project) {
                    notes[project.id] = fresh.doc.notes
                    notesRev[project.id] = fresh.rev
                }
                // loop: re-apply op to the freshly-pulled base
            } catch {
                handleDropboxError(error)
                return
            }
        }
        errorMessage = "Couldn't save note — Dropbox kept changing. Try again."
    }

    /// Conflict-safe write of a single library change. Re-pulls the current
    /// library fresh on each attempt and uses *that* file's `rev` as the
    /// write base, so two devices editing different songs (or different
    /// fields of the same song) converge instead of clobbering: whoever
    /// commits second gets a `rev` conflict and re-pulls the first's result.
    private func guardedLibraryWrite(_ mutate: (inout LibraryDocument) -> Void) async {
        guard let source else { return }
        pendingWrites += 1
        defer { pendingWrites -= 1 }
        for _ in 0..<5 {
            var base: LibraryDocument
            var baseRev: String?
            if let pulled = try? await source.loadLibraryRevisioned() {
                base = pulled.doc
                baseRev = pulled.rev
            } else {
                base = LibraryDocument(items: [])
                baseRev = nil
            }
            mutate(&base)
            base.modifiedAt = Date()
            base.schemaVersion = LibraryDocument.currentSchemaVersion
            do {
                _ = try await source.saveLibraryRevisioned(base, baseRev: baseRev)
                source.saveRegistry(projects)
                return
            } catch DropboxProjectSource.DropboxSourceError.conflict {
                continue
            } catch {
                handleDropboxError(error)
                return
            }
        }
        errorMessage = "Couldn't sync library — Dropbox kept changing. Try again."
    }

    /// Wait (up to ~12s) for any in-flight guarded Dropbox writes to drain.
    /// Called when the app enters the background — wrapped by the caller in a
    /// UIKit background-task assertion — so a note or metadata edit can't be
    /// stranded on the device with its upload only half-sent. No read-side
    /// guard can recover an edit that never reached Dropbox's servers; this
    /// is what makes sure it gets there.
    func flushPendingWrites() async {
        var ticks = 0
        while pendingWrites > 0 && ticks < 120 {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            ticks += 1
        }
    }

    /// Snapshot the current in-memory per-song metadata into a fresh
    /// `LibraryEntry`. Used only when *creating* an entry that doesn't yet
    /// exist in the freshly-pulled library.
    private func makeEntry(for project: ProjectReference) -> LibraryEntry {
        LibraryEntry(
            displayName: project.displayName,
            addedAt: Date(),
            hideTitle: hideTitle[project.id] ?? false,
            status: status[project.id] ?? .inProgress,
            starred: starred[project.id] ?? false,
            selectedAudioPath: selectedAudioPath[project.id],
            pinWatermark: pinWatermark[project.id]
        )
    }

    /// Create-or-update an entry by display name in a freshly-pulled library
    /// doc. Use for `addProject`/seeding where the song *should* exist. For
    /// field-change ops use `SyncMerge.updateEntry` instead (update-only, so a
    /// song removed on another device isn't resurrected by a stray toggle).
    private func upsertEntry(for project: ProjectReference, in doc: inout LibraryDocument, _ mutate: (inout LibraryEntry) -> Void) {
        let key = project.displayName.lowercased()
        if let idx = doc.items.firstIndex(where: { $0.id == key }) {
            mutate(&doc.items[idx])
        } else {
            var entry = makeEntry(for: project)
            mutate(&entry)
            doc.items.append(entry)
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

    /// Pin the user's audio choice for a project and reload playback from
    /// the new file. The pin is sticky: we stamp it with the newest
    /// bounce's modDate so it auto-releases once a *newer* bounce lands
    /// (see `resolveAudio`). `.distantPast` when there are no bounces yet,
    /// so the first bounce to appear releases the pin.
    func selectAudioFile(_ file: AudioFileMeta, for project: ProjectReference) async {
        guard let source else { return }
        let watermark = await newestBounceModDate(for: project, source: source) ?? .distantPast
        selectedAudioPath[project.id] = file.relativePath
        pinWatermark[project.id] = watermark
        saveSelectedAudioToDisk()
        savePinWatermarkToDisk()
        await guardedLibraryWrite { doc in
            SyncMerge.updateEntry(project.displayName, in: &doc) {
                $0.selectedAudioPath = file.relativePath
                $0.pinWatermark = watermark
            }
        }
        await loadAndPlay(project: project, autoStart: audio.isPlaying)
    }

    /// Clear an explicit pin and return the project to the default
    /// "latest bounce" behavior, reloading playback.
    func clearAudioSelection(for project: ProjectReference) async {
        guard let source else { return }
        await releasePin(for: project, source: source)
        await loadAndPlay(project: project, autoStart: audio.isPlaying)
    }

    /// Drop the pin + watermark for a project and persist. Used both by
    /// the explicit "Latest (auto)" action and the automatic release in
    /// `resolveAudio` when a newer bounce appears.
    private func releasePin(for project: ProjectReference, source: DropboxProjectSource) async {
        selectedAudioPath[project.id] = nil
        pinWatermark[project.id] = nil
        saveSelectedAudioToDisk()
        savePinWatermarkToDisk()
        await guardedLibraryWrite { doc in
            SyncMerge.updateEntry(project.displayName, in: &doc) {
                $0.selectedAudioPath = nil
                $0.pinWatermark = nil
            }
        }
    }

    /// modDate of the newest bounce, preferring the already-loaded list to
    /// avoid a round trip. Falls back to a fresh Dropbox lookup.
    private func newestBounceModDate(for project: ProjectReference, source: DropboxProjectSource) async -> Date? {
        if let cached = audioFiles[project.id]?.filter({ !$0.isMaster }).map(\.modDate).max() {
            return cached
        }
        guard case .dropboxPath(let folderPath) = project.location else { return nil }
        return await source.latestBounce(forFolderPath: folderPath)?.modDate
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
                        await self.waveform.loadWaveform(for: project, audioURL: playbackURL, audioKey: bounce.filename)
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
                await self.waveform.loadWaveform(for: project, audioURL: cached.url, audioKey: cached.filename)
            }
            return
        }

        errorMessage = "No offline copy of \(project.displayName)"
    }

    /// On foreground, re-resolve the audio for whatever's loaded in the
    /// player and reload it if a newer bounce has appeared on Dropbox.
    /// `resolveAudio` handles both the default "latest bounce" case and a
    /// sticky pin that has gone stale — so a version uploaded while the
    /// app was backgrounded (e.g. 8.9.2 → 8.9.3) gets picked up either
    /// way. We also reload when the *filename* is unchanged but the
    /// remote bytes have been replaced (rebounced over the same name);
    /// detected via the cached-vs-remote modDate comparison.
    /// Quiet on failure: a foreground refresh shouldn't surface
    /// transient network errors.
    func refreshCurrentAudio() async {
        guard let project = audio.nowPlaying,
              case .dropboxPath(let folderPath) = project.location,
              let source else { return }
        do {
            guard let resolved = try await resolveAudio(source: source, project: project, folderPath: folderPath) else { return }
            let filenameChanged = resolved.filename != audio.currentTrackFilename
            let cachedMod = AudioCache.shared.remoteModified(projectID: project.id, filename: resolved.filename)
            // nil cachedMod = legacy cache from before xattr stamping, or
            // no cache yet — treat as stale so the user gets the current
            // bytes one time, after which subsequent foregrounds compare
            // precisely.
            let contentChanged = cachedMod.map { resolved.modDate > $0.addingTimeInterval(1) } ?? true
            guard (filenameChanged || contentChanged),
                  audio.nowPlaying?.id == project.id else { return }
            // cachedOrStream takes care of dropping the stale audio +
            // waveform caches before returning a URL.
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

    /// Resolve which audio to play for a given project. If the user has
    /// pinned a file (and it still exists), use that — unless the pin has
    /// gone stale, i.e. a bounce newer than the pin watermark has landed,
    /// in which case the pin auto-releases to the latest bounce. With no
    /// pin we fall back to the latest bounce — the same default the Mac
    /// uses when no master is selected.
    private func resolveAudio(
        source: DropboxProjectSource,
        project: ProjectReference,
        folderPath: String
    ) async throws -> (url: URL, filename: String, relativePath: String, modDate: Date)? {
        if let selected = selectedAudioPath[project.id] {
            // `latestBounce` returns nil when offline; in that case we
            // skip the staleness check entirely and just honor the pin.
            if let latest = await source.latestBounce(forFolderPath: folderPath) {
                if let watermark = pinWatermark[project.id] {
                    // 1s slop: filesystem mtimes round, Dropbox dates don't.
                    if latest.modDate > watermark.addingTimeInterval(1) {
                        await releasePin(for: project, source: source)
                        return try await source.fetchLatestBounceURL(forFolderPath: folderPath)
                    }
                } else {
                    // Legacy pin from before watermarks existed: adopt the
                    // current latest as the baseline so it starts tracking
                    // newer bounces from here on (instead of staying pinned
                    // forever).
                    pinWatermark[project.id] = latest.modDate
                    savePinWatermarkToDisk()
                    await guardedLibraryWrite { doc in
                        SyncMerge.updateEntry(project.displayName, in: &doc) { $0.pinWatermark = latest.modDate }
                    }
                }
            }
            if let result = try await source.fetchAudioURL(forFolderPath: folderPath, relativePath: selected) {
                return (result.url, result.filename, selected, result.modDate)
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
    /// download and returns the streaming URL. Detects same-name remote
    /// replacements (rebouncing over an existing version) by comparing
    /// the cached file's recorded clientModified against the resolved
    /// remote modDate. A stale cache (or a legacy cache from before this
    /// stamp existed) is dropped along with its waveform so the stream
    /// URL wins and the background download repopulates with fresh bytes.
    private func cachedOrStream(
        bounce: (url: URL, filename: String, relativePath: String, modDate: Date),
        project: ProjectReference
    ) -> URL {
        let cachedMod = AudioCache.shared.remoteModified(projectID: project.id, filename: bounce.filename)
        // 1s slop matches the album-art and pin-watermark comparisons.
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
