import Foundation
import SwiftyDropbox

@MainActor
final class DropboxProjectSource: ProjectSource {
    let rootPath = "/music/aidenel songs"
    let writableSubfolder = "song notes"
    let storageURL: URL

    private let client: DropboxClient

    enum DropboxSourceError: Error, LocalizedError {
        case notAuthorized
        case authExpired
        case api(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "Dropbox not connected. Tap Connect to paste a refresh token."
            case .authExpired: return "Dropbox session expired — please reconnect."
            case .api(let message): return "Dropbox API error: \(message)"
            }
        }
    }

    /// SwiftyDropbox surfaces auth failures as `CallError.authError(...)`.
    /// We can't pattern-match the generic without knowing the route's
    /// error type, so we stringify and look for known auth markers.
    private static func mapError(_ error: Any) -> DropboxSourceError {
        let description = String(describing: error)
        let lower = description.lowercased()
        if lower.contains("autherror")
            || lower.contains("expired_access_token")
            || lower.contains("invalid_access_token")
            || lower.contains("missing_scope")
            || lower.contains("user_suspended") {
            return .authExpired
        }
        return .api(description)
    }

    /// Heuristic for the "path not found" branch of the download/get_metadata
    /// route errors. Used to distinguish "file doesn't exist yet" from
    /// real failures so callers can do first-run migration cleanly.
    private static func isNotFound(_ error: DropboxSourceError) -> Bool {
        guard case .api(let description) = error else { return false }
        let lower = description.lowercased()
        return lower.contains("path/not_found")
            || lower.contains("not_found")
    }

    init(storageURL: URL) throws {
        guard let oauth = DropboxOAuthManager.sharedOAuthManager,
              let token = oauth.getFirstAccessToken() else {
            throw DropboxSourceError.notAuthorized
        }
        self.client = DropboxClient(accessToken: token, dropboxOauthManager: oauth)
        self.storageURL = storageURL
    }

    func loadProjects() async throws -> [ProjectReference] {
        guard FileManager.default.fileExists(atPath: storageURL.path(percentEncoded: false)),
              let data = try? Data(contentsOf: storageURL) else {
            return []
        }
        return (try? JSONDecoder().decode([ProjectReference].self, from: data)) ?? []
    }

    func saveRegistry(_ projects: [ProjectReference]) {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }

    func fetchAlbumArt(forFolderPath folderPath: String, songName: String) async throws -> (data: Data, modified: Date)? {
        guard let chosen = try await findAlbumArtFile(folderPath: folderPath, songName: songName) else {
            return nil
        }
        let downloadPath = chosen.pathLower ?? (folderPath + "/_ALBUM ART/" + chosen.name)
        let data = try await downloadFile(path: downloadPath)
        return (data, chosen.clientModified)
    }

    /// Light-weight: lists `_ALBUM ART/`, picks the same file
    /// `fetchAlbumArt` would, but skips the download. Used to decide
    /// whether the cached art is stale before paying the bandwidth cost
    /// of refetching.
    func fetchAlbumArtModified(forFolderPath folderPath: String, songName: String) async throws -> Date? {
        try await findAlbumArtFile(folderPath: folderPath, songName: songName)?.clientModified
    }

    private func findAlbumArtFile(folderPath: String, songName: String) async throws -> Files.FileMetadata? {
        let artFolderPath = folderPath + "/_ALBUM ART"
        let entries: [Files.Metadata]
        do {
            entries = try await listFolder(path: artFolderPath)
        } catch {
            // Missing _ALBUM ART folder is fine — no art.
            return nil
        }

        let imageExts: Set<String> = ["png", "jpg", "jpeg", "tiff", "webp"]
        let images = entries.compactMap { entry -> Files.FileMetadata? in
            guard let file = entry as? Files.FileMetadata else { return nil }
            let ext = (file.name as NSString).pathExtension.lowercased()
            return imageExts.contains(ext) ? file : nil
        }

        // Prefer the official "<song name> album art.<ext>" if it exists.
        // Among multiple matches (e.g. someone bounced both a .jpg and
        // a .png), pick the most recently modified — folder-listing
        // order isn't sorted by modDate, so without this an older .jpg
        // can beat a freshly-uploaded .png purely by appearing first.
        let officialStem = "\(songName) album art".lowercased()
        let officialMatches = images.filter { file in
            let stem = (file.name as NSString).deletingPathExtension.lowercased()
            return stem == officialStem
        }
        let official = officialMatches.sorted { $0.clientModified > $1.clientModified }.first
        return official ?? images.sorted { $0.clientModified > $1.clientModified }.first
    }

    /// Returns the most recent clientModified date across the project's
    /// .als files at the root and audio files in bounces/. Used to drive
    /// the "Recent" sort on the grid.
    func fetchLatestActivityDate(forFolderPath folderPath: String) async throws -> Date? {
        var latest: Date?

        if let rootEntries = try? await listFolder(path: folderPath) {
            for entry in rootEntries {
                guard let file = entry as? Files.FileMetadata else { continue }
                let ext = (file.name as NSString).pathExtension.lowercased()
                if ext == "als" {
                    if latest == nil || file.clientModified > latest! {
                        latest = file.clientModified
                    }
                }
            }
        }

        if let bounceEntries = try? await listFolder(path: folderPath + "/bounces") {
            let audioExts: Set<String> = ["wav", "mp3", "aif", "aiff", "flac", "m4a"]
            for entry in bounceEntries {
                guard let file = entry as? Files.FileMetadata else { continue }
                let ext = (file.name as NSString).pathExtension.lowercased()
                if audioExts.contains(ext) {
                    if latest == nil || file.clientModified > latest! {
                        latest = file.clientModified
                    }
                }
            }
        }

        return latest
    }

    private static let audioExts: Set<String> = ["wav", "mp3", "aif", "aiff", "flac", "m4a"]

    /// All playable audio files under the song folder, grouped by
    /// `bounces/` (flat) and `_MASTERS/` (recursive — masters folders
    /// often contain per-mix subfolders). Each entry's `relativePath` is
    /// the canonical key used by the picker, NotesDocument, and
    /// `fetchAudioURL(...)`.
    func listAudioFiles(forFolderPath folderPath: String) async throws -> [AudioFileMeta] {
        async let bounces = listAudioFiles(at: folderPath + "/bounces", folderPath: folderPath, isMaster: false, recursive: false)
        async let masters = listAudioFiles(at: folderPath + "/_MASTERS", folderPath: folderPath, isMaster: true, recursive: true)
        let (b, m) = try await (bounces, masters)
        return b + m
    }

    private func listAudioFiles(at path: String, folderPath: String, isMaster: Bool, recursive: Bool) async -> [AudioFileMeta] {
        let entries: [Files.Metadata]
        do {
            entries = try await listFolder(path: path, recursive: recursive)
        } catch {
            return []
        }
        let fileEntries = entries.compactMap { $0 as? Files.FileMetadata }
        let prefix = folderPath + "/"
        return fileEntries.compactMap { file -> AudioFileMeta? in
            let ext = (file.name as NSString).pathExtension.lowercased()
            guard Self.audioExts.contains(ext) else { return nil }
            let fullPath = file.pathDisplay ?? file.pathLower ?? (path + "/" + file.name)
            let relative = fullPath.hasPrefix(prefix)
                ? String(fullPath.dropFirst(prefix.count))
                : file.name
            return AudioFileMeta(
                filename: file.name,
                relativePath: relative,
                modDate: file.clientModified,
                isMaster: isMaster
            )
        }
        .sorted { $0.modDate > $1.modDate }
    }

    /// Resolve a specific relative path (`bounces/...` or `_MASTERS/...`)
    /// to a Dropbox temporary URL. Returns nil if the file no longer
    /// exists. `modDate` is the file's clientModified, used to detect
    /// same-name remote replacements that would otherwise be served
    /// indefinitely from a stale cache.
    func fetchAudioURL(forFolderPath folderPath: String, relativePath: String) async throws -> (url: URL, filename: String, modDate: Date)? {
        let path = folderPath + "/" + relativePath
        do {
            let link = try await getTemporaryLink(path: path)
            let filename = (relativePath as NSString).lastPathComponent
            return (link.url, filename, link.modified)
        } catch {
            return nil
        }
    }

    /// The newest bounce's metadata (including its modDate), or nil if
    /// there are no bounces / the listing failed. Used to decide whether a
    /// sticky pin should auto-release. Cheap: lists `bounces/` without
    /// resolving a temporary link.
    func latestBounce(forFolderPath folderPath: String) async -> AudioFileMeta? {
        let files = await listAudioFiles(at: folderPath + "/bounces", folderPath: folderPath, isMaster: false, recursive: false)
        return files.first
    }

    /// Convenience: pick the latest bounce when no explicit selection
    /// has been made. Mirrors the Mac default.
    func fetchLatestBounceURL(forFolderPath folderPath: String) async throws -> (url: URL, filename: String, relativePath: String, modDate: Date)? {
        guard let latest = await latestBounce(forFolderPath: folderPath) else { return nil }
        let link = try await getTemporaryLink(path: folderPath + "/" + latest.relativePath)
        return (link.url, latest.filename, latest.relativePath, latest.modDate)
    }

    private func getTemporaryLink(path: String) async throws -> (url: URL, modified: Date) {
        try await withCheckedThrowingContinuation { continuation in
            client.files.getTemporaryLink(path: path).response { response, error in
                if let error = error {
                    continuation.resume(throwing: Self.mapError(error))
                    return
                }
                guard let response, let url = URL(string: response.link) else {
                    continuation.resume(throwing: DropboxSourceError.api("No temporary link"))
                    return
                }
                continuation.resume(returning: (url, response.metadata.clientModified))
            }
        }
    }

    // MARK: - Notes

    private static let notesRootPath = "/music/aidenel songs/song notes"

    func loadNotes(for project: ProjectReference) async throws -> NotesDocument {
        let path = Self.notesPath(for: project)
        do {
            let data = try await downloadFile(path: path)
            return try JSONDecoder().decode(NotesDocument.self, from: data)
        } catch {
            return NotesDocument()
        }
    }

    func saveNotes(_ doc: NotesDocument, for project: ProjectReference) async throws {
        let path = Self.notesPath(for: project)
        // App-level write scoping — refuse to write outside song notes/.
        guard path.lowercased().hasPrefix(Self.notesRootPath.lowercased() + "/") else {
            throw DropboxSourceError.api("Refused write outside song notes/: \(path)")
        }
        let data = try JSONEncoder().encode(doc)
        try await uploadFile(path: path, data: data)
    }

    private static func notesPath(for project: ProjectReference) -> String {
        "\(notesRootPath)/\(project.displayName).json"
    }

    // MARK: - Album art upload (Mac drag-and-drop, optional anywhere)

    /// Uploads (or replaces) a song's album art at the canonical path
    /// `<folderPath>/_ALBUM ART/<songName> album art.<ext>`. Callers
    /// should `refreshAlbumArt(for:)` after this returns so the local
    /// cache picks up the new image.
    func uploadAlbumArt(
        forFolderPath folderPath: String,
        songName: String,
        imageData: Data,
        fileExtension: String
    ) async throws {
        let ext = fileExtension.lowercased()
        let path = "\(folderPath)/_ALBUM ART/\(songName) album art.\(ext)"
        try await uploadFile(path: path, data: imageData)
    }

    // MARK: - Library (cross-device registry)

    /// Path used for the Dropbox-backed library file. Lives under
    /// `song notes/` because that's the only subfolder this app writes to
    /// (see `writableSubfolder` and the `saveNotes` guard above). The leading
    /// underscore keeps it out of folder pickers that would treat it as a song.
    private static let libraryPath = "\(notesRootPath)/_library.json"

    /// Pulls the library file from Dropbox. Returns `nil` when the file
    /// doesn't exist yet (first run on a fresh account). Throws on auth
    /// or unexpected API errors so the caller can fall back to the local
    /// cache. The local cache, not this method, is the offline path.
    func loadLibrary() async throws -> LibraryDocument? {
        do {
            let data = try await downloadFile(path: Self.libraryPath)
            return try JSONDecoder().decode(LibraryDocument.self, from: data)
        } catch let err as DropboxSourceError {
            if Self.isNotFound(err) { return nil }
            throw err
        }
    }

    /// Uploads the library file to Dropbox, overwriting. The caller is
    /// responsible for stamping `modifiedAt = Date()` immediately before
    /// calling — we don't mutate the caller's value here so a retry
    /// uploads the same bytes.
    func saveLibrary(_ doc: LibraryDocument) async throws {
        // App-level write scoping — refuse to write outside song notes/.
        guard Self.libraryPath.lowercased().hasPrefix(Self.notesRootPath.lowercased() + "/") else {
            throw DropboxSourceError.api("Refused write outside song notes/: \(Self.libraryPath)")
        }
        let data = try JSONEncoder().encode(doc)
        try await uploadFile(path: Self.libraryPath, data: data)
    }

    private func uploadFile(path: String, data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client.files.upload(path: path, mode: .overwrite, input: data).response { response, error in
                if let error = error {
                    continuation.resume(throwing: Self.mapError(error))
                    return
                }
                _ = response
                continuation.resume(returning: ())
            }
        }
    }

    private func listFolder(path: String, recursive: Bool = false) async throws -> [Files.Metadata] {
        var entries: [Files.Metadata] = []
        var page = try await listFolderPage(path: path, recursive: recursive)
        entries.append(contentsOf: page.entries)
        while page.hasMore, let cursor = page.cursor {
            page = try await listFolderContinue(cursor: cursor)
            entries.append(contentsOf: page.entries)
        }
        return entries
    }

    private struct ListFolderPage {
        let entries: [Files.Metadata]
        let hasMore: Bool
        let cursor: String?
    }

    private func listFolderPage(path: String, recursive: Bool) async throws -> ListFolderPage {
        try await withCheckedThrowingContinuation { continuation in
            client.files.listFolder(path: path, recursive: recursive).response { response, error in
                if let error = error {
                    continuation.resume(throwing: Self.mapError(error))
                    return
                }
                let result = ListFolderPage(
                    entries: response?.entries ?? [],
                    hasMore: response?.hasMore ?? false,
                    cursor: response?.cursor
                )
                continuation.resume(returning: result)
            }
        }
    }

    private func listFolderContinue(cursor: String) async throws -> ListFolderPage {
        try await withCheckedThrowingContinuation { continuation in
            client.files.listFolderContinue(cursor: cursor).response { response, error in
                if let error = error {
                    continuation.resume(throwing: Self.mapError(error))
                    return
                }
                let result = ListFolderPage(
                    entries: response?.entries ?? [],
                    hasMore: response?.hasMore ?? false,
                    cursor: response?.cursor
                )
                continuation.resume(returning: result)
            }
        }
    }

    private func downloadFile(path: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            client.files.download(path: path).response { response, error in
                if let error = error {
                    continuation.resume(throwing: Self.mapError(error))
                    return
                }
                guard let response else {
                    continuation.resume(throwing: DropboxSourceError.api("Empty download response"))
                    return
                }
                continuation.resume(returning: response.1)
            }
        }
    }

    func listAvailableFolders() async throws -> [FolderRef] {
        try await withCheckedThrowingContinuation { continuation in
            client.files.listFolder(path: rootPath).response { response, error in
                if let error = error {
                    continuation.resume(throwing: Self.mapError(error))
                    return
                }
                guard let result = response else {
                    continuation.resume(returning: [])
                    return
                }
                let folders: [FolderRef] = result.entries.compactMap { entry in
                    guard let folder = entry as? Files.FolderMetadata else { return nil }
                    guard folder.name.lowercased() != self.writableSubfolder else { return nil }
                    return FolderRef(
                        id: folder.pathLower ?? folder.name,
                        displayName: folder.name,
                        location: .dropboxPath(folder.pathDisplay ?? folder.name)
                    )
                }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                continuation.resume(returning: folders)
            }
        }
    }
}
