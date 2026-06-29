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

/// The per-song notes file (`song notes/<song>.json`). As of schema v3 this
/// holds **only** the notes: the per-song metadata that used to live here
/// (starred / selectedAudioPath / pinWatermark) moved to the song's
/// `LibraryEntry` so a metadata change never rewrites — and so can never
/// clobber — the irreplaceable notes. Legacy v1/v2 files still decode: the
/// old metadata keys are simply ignored (the one-time library migration
/// lifts their values via `DropboxProjectSource.LegacyNotesMetadata`).
struct NotesDocument: Codable {
    var version: Int
    var notes: [Note]

    init(notes: [Note] = []) {
        self.version = 3
        self.notes = notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 3
        self.notes = try c.decodeIfPresent([Note].self, forKey: .notes) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case version, notes
    }
}
