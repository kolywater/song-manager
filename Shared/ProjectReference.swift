import Foundation

enum SourceLocator: Codable, Equatable, Hashable {
    case localBookmark(Data)
    case dropboxPath(String)
}

struct ProjectReference: Identifiable, Codable, Equatable {
    let id: UUID
    var displayName: String
    var location: SourceLocator
    var latestVersionString: String?
    var latestBounceFilename: String?
    var albumArtFilename: String?
    var hasMastersFolder: Bool = false
    var masterFilenames: [String] = []
    var selectedMasterFilename: String?
    var gradientHue: Double?
    var latestALSModDate: Date?

    init(id: UUID = UUID(), displayName: String, location: SourceLocator) {
        self.id = id
        self.displayName = displayName
        self.location = location
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, location, rootBookmark
        case latestVersionString, latestBounceFilename, albumArtFilename
        case hasMastersFolder, masterFilenames, selectedMasterFilename
        case gradientHue, latestALSModDate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        if let loc = try c.decodeIfPresent(SourceLocator.self, forKey: .location) {
            self.location = loc
        } else if let bookmark = try c.decodeIfPresent(Data.self, forKey: .rootBookmark) {
            self.location = .localBookmark(bookmark)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .location, in: c, debugDescription: "Missing location and rootBookmark")
        }
        self.latestVersionString = try c.decodeIfPresent(String.self, forKey: .latestVersionString)
        self.latestBounceFilename = try c.decodeIfPresent(String.self, forKey: .latestBounceFilename)
        self.albumArtFilename = try c.decodeIfPresent(String.self, forKey: .albumArtFilename)
        self.hasMastersFolder = try c.decodeIfPresent(Bool.self, forKey: .hasMastersFolder) ?? false
        self.masterFilenames = try c.decodeIfPresent([String].self, forKey: .masterFilenames) ?? []
        self.selectedMasterFilename = try c.decodeIfPresent(String.self, forKey: .selectedMasterFilename)
        self.gradientHue = try c.decodeIfPresent(Double.self, forKey: .gradientHue)
        self.latestALSModDate = try c.decodeIfPresent(Date.self, forKey: .latestALSModDate)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(location, forKey: .location)
        try c.encodeIfPresent(latestVersionString, forKey: .latestVersionString)
        try c.encodeIfPresent(latestBounceFilename, forKey: .latestBounceFilename)
        try c.encodeIfPresent(albumArtFilename, forKey: .albumArtFilename)
        try c.encode(hasMastersFolder, forKey: .hasMastersFolder)
        try c.encode(masterFilenames, forKey: .masterFilenames)
        try c.encodeIfPresent(selectedMasterFilename, forKey: .selectedMasterFilename)
        try c.encodeIfPresent(gradientHue, forKey: .gradientHue)
        try c.encodeIfPresent(latestALSModDate, forKey: .latestALSModDate)
    }
}
