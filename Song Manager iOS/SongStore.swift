import Foundation
import Observation

@MainActor
@Observable
final class SongStore {
    var projects: [ProjectReference] = []
    var availableFolders: [FolderRef] = []
    var errorMessage: String?
    var isLoadingPicker = false

    private let source: DropboxProjectSource?

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
    }
}
