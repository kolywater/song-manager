import Foundation

struct ProjectReference: Identifiable, Codable {
    let id: UUID
    var displayName: String
    var rootBookmark: Data
    var latestVersionString: String?
    var latestBounceFilename: String?
    var albumArtFilename: String?
    var hasMastersFolder: Bool = false
    var masterFilenames: [String] = []
    var selectedMasterFilename: String?

    init(id: UUID = UUID(), displayName: String, rootBookmark: Data) {
        self.id = id
        self.displayName = displayName
        self.rootBookmark = rootBookmark
    }
}
