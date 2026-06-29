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
        /// The conditional write (`mode: .update(rev)`) was rejected because
        /// the file changed on the server since we loaded it. Drives the
        /// re-pull-and-replay retry loop in the stores; not user-facing.
        case conflict

        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "Dropbox not connected. Tap Connect to paste a refresh token."
            case .authExpired: return "Dropbox session expired — please reconnect."
            case .api(let message): return "Dropbox API error: \(message)"
            case .conflict: return "Dropbox write conflict — the file changed on the server."
            }
        }
    }

    /// A decoded document paired with the Dropbox `rev` it was loaded at.
    /// `rev == nil` means the file did not exist on the server, so a write
    /// must create it with `mode: .add` rather than `.update(rev)`.
    struct Revisioned<T> {
        var doc: T
        var rev: String?
    }

    /// Just the per-song metadata that lived in the legacy combined notes
    /// file (schema v1). Decoded for the one-time lift into `LibraryEntry`;
    /// every field is optional so a notes-only (already-migrated) file
    /// decodes to all-nil. Kept separate from `NotesDocument` so that struct
    /// can drop these fields without breaking migration.
    struct LegacyNotesMetadata: Decodable {
        var starred: Bool?
        var selectedAudioPath: String?
        var pinWatermark: Date?
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

    /// Revisioned load: returns the decoded `NotesDocument` plus its `rev`.
    /// A missing file is not an error — it yields an empty doc with `rev ==
    /// nil` (write-as-`.add`). Real download/decode failures **propagate**
    /// instead of being masked as an empty doc, so a transient failure can
    /// never feed an empty list into a write.
    func loadNotesRevisioned(for project: ProjectReference) async throws -> Revisioned<NotesDocument> {
        let path = Self.notesPath(for: project)
        do {
            let (data, rev) = try await downloadFileRevisioned(path: path)
            let doc = try JSONDecoder().decode(NotesDocument.self, from: data)
            return Revisioned(doc: doc, rev: rev)
        } catch let err as DropboxSourceError where Self.isNotFound(err) {
            return Revisioned(doc: NotesDocument(), rev: nil)
        }
    }

    /// One-time migration support: decode just the per-song metadata fields
    /// (starred / selectedAudioPath / pinWatermark) out of a legacy combined
    /// notes file, independent of `NotesDocument`'s current shape (which is
    /// notes-only from schema v2 on). Returns `nil` if the file is absent.
    func loadLegacyNotesMetadata(for project: ProjectReference) async throws -> LegacyNotesMetadata? {
        let path = Self.notesPath(for: project)
        do {
            let data = try await downloadFile(path: path)
            let raw = try JSONDecoder().decode(LegacyNotesMetadata.self, from: data)
            return raw
        } catch let err as DropboxSourceError where Self.isNotFound(err) {
            return nil
        }
    }

    /// Current `rev` of a song's notes file, or `nil` if it doesn't exist or
    /// the lookup fails. A cheap metadata-only call (no download) used to poll
    /// for changes while the player is open — compare against the last-loaded
    /// `rev` and only re-download when it differs.
    func latestNotesRev(for project: ProjectReference) async -> String? {
        let path = Self.notesPath(for: project)
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            client.files.getMetadata(path: path).response { response, _ in
                continuation.resume(returning: (response as? Files.FileMetadata)?.rev)
            }
        }
    }

    /// Revisioned conditional save. Returns the new `rev`; throws
    /// `DropboxSourceError.conflict` if the server copy moved since `baseRev`.
    func saveNotesRevisioned(_ doc: NotesDocument, for project: ProjectReference, baseRev: String?) async throws -> String {
        let path = Self.notesPath(for: project)
        guard path.lowercased().hasPrefix(Self.notesRootPath.lowercased() + "/") else {
            throw DropboxSourceError.api("Refused write outside song notes/: \(path)")
        }
        let data = try JSONEncoder().encode(doc)
        return try await uploadFileRevisioned(path: path, data: data, baseRev: baseRev)
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
    /// (see `writableSubfolder` and the `saveNotesRevisioned` guard above). The leading
    /// underscore keeps it out of folder pickers that would treat it as a song.
    private static let libraryPath = "\(notesRootPath)/_library.json"

    /// Revisioned library load. Returns `nil` when the file doesn't exist
    /// (first run), else the decoded doc plus its `rev`. Real errors propagate.
    func loadLibraryRevisioned() async throws -> Revisioned<LibraryDocument>? {
        do {
            let (data, rev) = try await downloadFileRevisioned(path: Self.libraryPath)
            let doc = try JSONDecoder().decode(LibraryDocument.self, from: data)
            return Revisioned(doc: doc, rev: rev)
        } catch let err as DropboxSourceError where Self.isNotFound(err) {
            return nil
        }
    }

    /// Revisioned conditional library save. Returns the new `rev`; throws
    /// `DropboxSourceError.conflict` if the server copy moved since `baseRev`.
    /// Caller stamps `modifiedAt`/`schemaVersion` before calling.
    func saveLibraryRevisioned(_ doc: LibraryDocument, baseRev: String?) async throws -> String {
        guard Self.libraryPath.lowercased().hasPrefix(Self.notesRootPath.lowercased() + "/") else {
            throw DropboxSourceError.api("Refused write outside song notes/: \(Self.libraryPath)")
        }
        let data = try JSONEncoder().encode(doc)
        return try await uploadFileRevisioned(path: Self.libraryPath, data: data, baseRev: baseRev)
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

    /// Conditional upload: create with `.add` when `baseRev == nil`, else
    /// `.update(baseRev)` which Dropbox rejects (with a write-conflict) if the
    /// file's current `rev` no longer matches. Returns the new `rev` on
    /// success. Throws `DropboxSourceError.conflict` on a detected conflict so
    /// the caller can re-pull and replay its operation.
    private func uploadFileRevisioned(path: String, data: Data, baseRev: String?) async throws -> String {
        let mode: Files.WriteMode = baseRev.map { .update($0) } ?? .add
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            client.files.upload(path: path, mode: mode, input: data).response { response, error in
                if let error = error {
                    continuation.resume(throwing: Self.mapUploadError(error))
                    return
                }
                guard let metadata = response else {
                    continuation.resume(throwing: DropboxSourceError.api("Empty upload response"))
                    return
                }
                continuation.resume(returning: metadata.rev)
            }
        }
    }

    /// Upload errors are statically typed as `CallError<Files.UploadError>`, so
    /// we pattern-match the real enum to spot the "file changed since you
    /// loaded it" conflict that drives the retry loop — more robust than
    /// string-sniffing for this one critical case. Anything else falls back to
    /// the shared string-based `mapError`. A misclassification here is
    /// fail-safe: the conditional write already prevented any clobber, so the
    /// worst case is a missed retry surfacing as a toast.
    private static func mapUploadError(_ error: CallError<Files.UploadError>) -> DropboxSourceError {
        if case .routeError(let boxed, _, _, _) = error,
           case .path(let writeFailed) = boxed.unboxed,
           case .conflict = writeFailed.reason {
            return .conflict
        }
        return mapError(error)
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

    /// Like `downloadFile`, but also returns the file's current `rev` so a
    /// later conditional write can detect server-side changes.
    private func downloadFileRevisioned(path: String) async throws -> (data: Data, rev: String) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(data: Data, rev: String), Error>) in
            client.files.download(path: path).response { response, error in
                if let error = error {
                    continuation.resume(throwing: Self.mapError(error))
                    return
                }
                guard let response else {
                    continuation.resume(throwing: DropboxSourceError.api("Empty download response"))
                    return
                }
                continuation.resume(returning: (response.1, response.0.rev))
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
