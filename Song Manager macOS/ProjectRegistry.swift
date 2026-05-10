import Foundation

struct ProjectRegistry: Codable {
    var entries: [Entry]

    struct Entry: Codable {
        let id: UUID
        var location: SourceLocator

        init(id: UUID, location: SourceLocator) {
            self.id = id
            self.location = location
        }

        private enum CodingKeys: String, CodingKey {
            case id, location, rootBookmark
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(UUID.self, forKey: .id)
            if let loc = try c.decodeIfPresent(SourceLocator.self, forKey: .location) {
                self.location = loc
            } else if let bookmark = try c.decodeIfPresent(Data.self, forKey: .rootBookmark) {
                self.location = .localBookmark(bookmark)
            } else {
                throw DecodingError.dataCorruptedError(forKey: .location, in: c, debugDescription: "Missing location and rootBookmark")
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(location, forKey: .location)
        }
    }
}
