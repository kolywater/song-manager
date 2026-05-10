import Foundation

struct FolderRef: Identifiable, Hashable, Codable {
    let id: String
    let displayName: String
    let location: SourceLocator
}

protocol ProjectSource {
    func loadProjects() async throws -> [ProjectReference]
    func listAvailableFolders() async throws -> [FolderRef]
}
