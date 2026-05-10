import CoreImage
import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class SongStore {
    var projects: [ProjectReference] = []
    var availableFolders: [FolderRef] = []
    var albumArt: [UUID: UIImage] = [:]
    /// Luminance of the bottom strip of the album art (0 = black, 1 = white).
    /// Used by SongCard to flip the pill's foreground between black/white.
    var artBottomLuminance: [UUID: Double] = [:]
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

    /// Average luminance (0–1) of the bottom 25% of an image. Used to
    /// pick a contrasting foreground color for the pill overlay.
    private static func bottomLuminance(of image: UIImage) -> Double {
        guard let cgImage = image.cgImage else { return 0 }
        let height = CGFloat(cgImage.height)
        let bottom = CGRect(
            x: 0,
            y: height * 0.75,
            width: CGFloat(cgImage.width),
            height: height * 0.25
        )
        guard let cropped = cgImage.cropping(to: bottom) else { return 0 }
        let ciImage = CIImage(cgImage: cropped)
        let extent = ciImage.extent
        let inputExtent = CIVector(x: extent.origin.x, y: extent.origin.y, z: extent.size.width, w: extent.size.height)
        guard let filter = CIFilter(
            name: "CIAreaAverage",
            parameters: [kCIInputImageKey: ciImage, kCIInputExtentKey: inputExtent]
        ), let output = filter.outputImage else { return 0 }

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
        return 0.299 * r + 0.587 * g + 0.114 * b
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
        artBottomLuminance.removeValue(forKey: project.id)
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
            artBottomLuminance[project.id] = Self.bottomLuminance(of: image)
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
            artBottomLuminance[project.id] = Self.bottomLuminance(of: image)
        } catch {
            // Silent — placeholder remains visible.
        }
    }
}
