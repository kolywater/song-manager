import Foundation

struct ProjectRegistry: Codable {
    var entries: [Entry]

    struct Entry: Codable {
        let id: UUID
        var rootBookmark: Data
    }
}
