import Foundation

struct Note: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var time: Double
    var text: String
    var tags: [String]
    /// Version of the song bounce this note was pinned to, e.g. [1, 3] for "V1.3".
    /// `nil` for notes captured without a parseable version (legacy or pre-load).
    var version: [Int]?
    var createdAt: Date

    init(id: UUID = UUID(), time: Double, text: String, tags: [String] = [], version: [Int]? = nil, createdAt: Date = Date()) {
        self.id = id
        self.time = time
        self.text = text
        self.tags = tags
        self.version = version
        self.createdAt = createdAt
    }
}

struct NotesDocument: Codable {
    var version: Int
    var notes: [Note]
    var starred: Bool
    /// Path of the user's chosen audio file relative to the song folder
    /// (e.g. "bounces/MySong 1.3.wav" or "_MASTERS/master.wav"). nil =
    /// fall back to the latest bounce.
    var selectedAudioPath: String?

    init(notes: [Note] = [], starred: Bool = false, selectedAudioPath: String? = nil) {
        self.version = 2
        self.notes = notes
        self.starred = starred
        self.selectedAudioPath = selectedAudioPath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decode(Int.self, forKey: .version)
        self.notes = try c.decodeIfPresent([Note].self, forKey: .notes) ?? []
        self.starred = try c.decodeIfPresent(Bool.self, forKey: .starred) ?? false
        self.selectedAudioPath = try c.decodeIfPresent(String.self, forKey: .selectedAudioPath)
    }

    private enum CodingKeys: String, CodingKey {
        case version, notes, starred, selectedAudioPath
    }
}
