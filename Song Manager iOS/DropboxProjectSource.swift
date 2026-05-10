import Foundation
import SwiftyDropbox

@MainActor
final class DropboxProjectSource: ProjectSource {
    let rootPath = "/music/aidenel songs"
    let writableSubfolder = "song notes"
    let storageURL: URL

    private let client: DropboxClient

    enum DropboxSourceError: Error, LocalizedError {
        case noToken
        case api(String)

        var errorDescription: String? {
            switch self {
            case .noToken: return "Dropbox access token is empty. Set DropboxConfig.accessToken."
            case .api(let message): return "Dropbox API error: \(message)"
            }
        }
    }

    init(accessToken: String, storageURL: URL) throws {
        guard !accessToken.isEmpty else { throw DropboxSourceError.noToken }
        self.client = DropboxClient(accessToken: accessToken)
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

    func fetchAlbumArt(forFolderPath folderPath: String, songName: String) async throws -> Data? {
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
        let officialStem = "\(songName) album art".lowercased()
        let official = images.first { file in
            let stem = (file.name as NSString).deletingPathExtension.lowercased()
            return stem == officialStem
        }
        let chosen = official ?? images.sorted { $0.clientModified > $1.clientModified }.first
        guard let chosen else { return nil }

        let downloadPath = chosen.pathLower ?? (artFolderPath + "/" + chosen.name)
        return try await downloadFile(path: downloadPath)
    }

    func fetchLatestBounceURL(forFolderPath folderPath: String) async throws -> URL? {
        let bouncesPath = folderPath + "/bounces"
        let entries: [Files.Metadata]
        do {
            entries = try await listFolder(path: bouncesPath)
        } catch {
            return nil
        }

        let audioExts: Set<String> = ["wav", "mp3", "aif", "aiff", "flac", "m4a"]
        let bounces = entries.compactMap { entry -> Files.FileMetadata? in
            guard let file = entry as? Files.FileMetadata else { return nil }
            let ext = (file.name as NSString).pathExtension.lowercased()
            return audioExts.contains(ext) ? file : nil
        }
        .sorted { $0.clientModified > $1.clientModified }

        guard let latest = bounces.first else { return nil }
        let path = latest.pathLower ?? (bouncesPath + "/" + latest.name)
        return try await getTemporaryLink(path: path)
    }

    private func getTemporaryLink(path: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            client.files.getTemporaryLink(path: path).response { response, error in
                if let error = error {
                    continuation.resume(throwing: DropboxSourceError.api(String(describing: error)))
                    return
                }
                guard let response, let url = URL(string: response.link) else {
                    continuation.resume(throwing: DropboxSourceError.api("No temporary link"))
                    return
                }
                continuation.resume(returning: url)
            }
        }
    }

    private func listFolder(path: String) async throws -> [Files.Metadata] {
        try await withCheckedThrowingContinuation { continuation in
            client.files.listFolder(path: path).response { response, error in
                if let error = error {
                    continuation.resume(throwing: DropboxSourceError.api(String(describing: error)))
                    return
                }
                continuation.resume(returning: response?.entries ?? [])
            }
        }
    }

    private func downloadFile(path: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            client.files.download(path: path).response { response, error in
                if let error = error {
                    continuation.resume(throwing: DropboxSourceError.api(String(describing: error)))
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
                    continuation.resume(throwing: DropboxSourceError.api(String(describing: error)))
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
