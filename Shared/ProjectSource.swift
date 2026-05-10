import Foundation

struct FolderRef: Identifiable, Hashable, Codable {
    let id: String
    let displayName: String
}

protocol ProjectSource {
    func loadProjects() async throws -> [ProjectReference]
    func listAvailableFolders() async throws -> [FolderRef]
}
