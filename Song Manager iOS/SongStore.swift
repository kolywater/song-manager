import CoreImage
import Foundation
import Observation
import SwiftUI
import SwiftyDropbox
import UIKit

@MainActor
@Observable
final class SongStore {
    var projects: [ProjectReference] = []
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
        if source != nil {
            Task { [weak self] in
                await self?.refreshActivityDates()
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
        guard let source else {
            errorMessage = "Dropbox not configured"
            return
        }
        guard case .dropboxPath(let folderPath) = project.location else { return }

        // Present the player immediately with project info; audio prepares
        // in the background.
        audio.preparePlayback(for: project)
        if showPlayer { presentingFullPlayer = true }

        do {
            guard let bounce = try await source.fetchLatestBounceURL(forFolderPath: folderPath) else {
                errorMessage = "No bounces found in \(project.displayName)"
                audio.stop()
                presentingFullPlayer = false
                return
            }
            // Bail if the user already moved on to a different project.
            guard audio.nowPlaying?.id == project.id else { return }
            audio.load(url: bounce.url, project: project, filename: bounce.filename, artwork: albumArt[project.id], autoStart: autoStart)
            Task { [weak self] in
                guard let self else { return }
                await self.waveform.loadWaveform(for: project, audioURL: bounce.url)
            }
            Task { [weak self] in
                guard let self else { return }
                await self.loadNotes(for: project)
            }
        } catch {
            handleDropboxError(error)
            audio.stop()
            presentingFullPlayer = false
        }
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

    func toggleStarred(_ project: ProjectReference) async {
        starred[project.id] = !(starred[project.id] ?? false)
        saveStarredToDisk()
        guard let source else { return }
        await persistDoc(for: project, source: source)
    }

    private func persistDoc(for project: ProjectReference, source: DropboxProjectSource) async {
        let doc = NotesDocument(
            notes: notes[project.id] ?? [],
            starred: starred[project.id] ?? false
        )
        do {
            try await source.saveNotes(doc, for: project)
        } catch {
            handleDropboxError(error)
        }
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
            guard let data = try await source.fetchAlbumArt(forFolderPath: folderPath, songName: project.displayName),
                  let image = UIImage(data: data) else { return }
            try? data.write(to: cacheURL, options: .atomic)
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
}
