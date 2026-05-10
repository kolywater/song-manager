import Foundation

struct Note: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var time: Double
    var text: String
    var tags: [String]
    var createdAt: Date

    init(id: UUID = UUID(), time: Double, text: String, tags: [String] = [], createdAt: Date = Date()) {
        self.id = id
        self.time = time
        self.text = text
        self.tags = tags
        self.createdAt = createdAt
    }
}

struct NotesDocument: Codable {
    var version: Int
    var notes: [Note]

    init(notes: [Note] = []) {
        self.version = 1
        self.notes = notes
    }
}
