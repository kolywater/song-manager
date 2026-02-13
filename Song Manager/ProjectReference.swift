import Foundation

struct ProjectReference: Identifiable, Codable, Equatable {
    let id: UUID
    var displayName: String
    var rootBookmark: Data
    var latestVersionString: String?
    var latestBounceFilename: String?
    var albumArtFilename: String?
    var hasMastersFolder: Bool = false
    var masterFilenames: [String] = []
    var selectedMasterFilename: String?
    var gradientHue: Double?
    var latestALSModDate: Date?

    init(id: UUID = UUID(), displayName: String, rootBookmark: Data) {
        self.id = id
        self.displayName = displayName
        self.rootBookmark = rootBookmark
    }
}
