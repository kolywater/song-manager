import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class SongStore {
    var projects: [ProjectReference] = []
    var availableFolders: [FolderRef] = []
    var albumArt: [UUID: UIImage] = [:]
    var errorMessage: String?
    var isLoadingPicker = false
    var presentingFullPlayer: Bool = false
    var notes: [UUID: [Note]] = [:]
    let audio = AudioService()
    let waveform = WaveformService()

    private let source: DropboxProjectSource?
    private var artInFlight: Set<UUID> = []
    private var notesInFlight: Set<UUID> = []

    init() {
        let url = Self.defaultRegistryURL()
        do {
            self.source = try DropboxProjectSource(accessToken: DropboxConfig.accessToken, storageURL: url)
        } catch {
            self.source = nil
            self.errorMessage = error.localizedDescription
        }
        loadFromDisk(at: url)
    }

    private static func defaultRegistryURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appending(path: "iosProjects.json")
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
            errorMessage = error.localizedDescription
        }
        isLoadingPicker = false
    }

    func addProject(folder: FolderRef) {
        let project = ProjectReference(displayName: folder.displayName, location: folder.location)
        projects.append(project)
        source?.saveRegistry(projects)
    }

    func removeProject(_ project: ProjectReference) {
        projects.removeAll { $0.id == project.id }
        source?.saveRegistry(projects)
        albumArt.removeValue(forKey: project.id)
        try? FileManager.default.removeItem(at: Self.albumArtCacheURL(for: project.id))
        waveform.invalidate(for: project.id)
    }

    func refreshAlbumArt(for project: ProjectReference) async {
        albumArt.removeValue(forKey: project.id)
        try? FileManager.default.removeItem(at: Self.albumArtCacheURL(for: project.id))
        await loadAlbumArt(for: project)
    }

    func play(_ project: ProjectReference, autoStart: Bool = false) async {
        // If this is the same song already loaded, just open the full player.
        if audio.nowPlaying?.id == project.id {
            if autoStart && !audio.isPlaying { audio.resume() }
            presentingFullPlayer = true
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
        presentingFullPlayer = true

        do {
            guard let url = try await source.fetchLatestBounceURL(forFolderPath: folderPath) else {
                errorMessage = "No bounces found in \(project.displayName)"
                audio.stop()
                return
            }
            // Bail if the user already moved on to a different project.
            guard audio.nowPlaying?.id == project.id else { return }
            audio.load(url: url, project: project, artwork: albumArt[project.id], autoStart: autoStart)
            Task { [weak self] in
                guard let self else { return }
                await self.waveform.loadWaveform(for: project, audioURL: url)
            }
            Task { [weak self] in
                guard let self else { return }
                await self.loadNotes(for: project)
            }
        } catch {
            errorMessage = error.localizedDescription
            audio.stop()
        }
    }

    // MARK: - Notes

    func loadNotes(for project: ProjectReference) async {
        guard let source else { return }
        if notesInFlight.contains(project.id) { return }
        notesInFlight.insert(project.id)
        defer { notesInFlight.remove(project.id) }

        do {
            let loaded = try await source.loadNotes(for: project)
            notes[project.id] = loaded
        } catch {
            notes[project.id] = []
        }
    }

    func addNote(_ note: Note, to project: ProjectReference) async {
        guard let source else { return }
        var current = notes[project.id] ?? []
        current.append(note)
        current.sort { $0.time < $1.time }
        notes[project.id] = current
        do {
            try await source.saveNotes(current, for: project)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeNote(_ note: Note, from project: ProjectReference) async {
        guard let source else { return }
        var current = notes[project.id] ?? []
        current.removeAll { $0.id == note.id }
        notes[project.id] = current
        do {
            try await source.saveNotes(current, for: project)
        } catch {
            errorMessage = error.localizedDescription
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
        } catch {
            // Silent — placeholder remains visible.
        }
    }
}
