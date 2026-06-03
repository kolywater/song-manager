import Foundation

/// The library file synced to Dropbox at
/// `/music/aidenel songs/song notes/_library.json`. Each entry names a
/// song folder under the rootPath plus the lightweight grid-display
/// preferences that should be available before any per-song
/// NotesDocument loads. Both Mac and iOS pull this on launch + after
/// foreground, and push it on add/remove or grid-preference change.
///
/// Conflict policy: **last-writer-wins** on `modifiedAt`. Two devices
/// adding/removing within the same syncing window is rare in practice;
/// we accept the small chance of one device's edit being overwritten.
/// The local cache (`iosProjects.json` on iOS, `~/Application Support/...`
/// on Mac) is the offline fallback so the app never goes blank.
struct LibraryDocument: Codable {
    var schemaVersion: Int
    var modifiedAt: Date
    var items: [LibraryEntry]

    init(schemaVersion: Int = 1, modifiedAt: Date = Date(), items: [LibraryEntry] = []) {
        self.schemaVersion = schemaVersion
        self.modifiedAt = modifiedAt
        self.items = items
    }
}

struct LibraryEntry: Codable, Equatable, Identifiable {
    /// Folder name under `/music/aidenel songs/`. This is the identity
    /// key across devices.
    var displayName: String
    var addedAt: Date
    /// Grid display preference: when true, the song card on the home
    /// grid skips drawing the title text overlay. Lives here (not in
    /// NotesDocument) so the grid knows immediately on first paint —
    /// fetching the per-song NotesDocument is async and would flash
    /// the title visible before hiding it.
    var hideTitle: Bool

    var id: String { displayName.lowercased() }

    init(displayName: String, addedAt: Date, hideTitle: Bool = false) {
        self.displayName = displayName
        self.addedAt = addedAt
        self.hideTitle = hideTitle
    }

    private enum CodingKeys: String, CodingKey {
        case displayName, addedAt, hideTitle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.addedAt = try c.decode(Date.self, forKey: .addedAt)
        self.hideTitle = try c.decodeIfPresent(Bool.self, forKey: .hideTitle) ?? false
    }
}
