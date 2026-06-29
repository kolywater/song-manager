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
    /// Current on-disk schema. v1 → v2 added the per-song metadata that
    /// used to live in each `NotesDocument` (starred / selectedAudioPath /
    /// pinWatermark). A pulled doc with `schemaVersion < currentSchemaVersion`
    /// triggers the one-time lift migration (see the stores). Kept as a
    /// literal `2` in the `init` default below — keep the two in sync.
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var modifiedAt: Date
    var items: [LibraryEntry]

    init(schemaVersion: Int = 2, modifiedAt: Date = Date(), items: [LibraryEntry] = []) {
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
    /// Workflow status (in-progress / released / idle). Lives on the
    /// LibraryEntry — not the per-song NotesDocument — for the same
    /// reason as `hideTitle`: the home grid uses it as the top-level
    /// grouping key and must know on first paint, before any per-song
    /// doc has loaded. Missing on decode → `.inProgress` so existing
    /// libraries silently land every song in the top group.
    var status: SongStatus
    /// Whether the song is starred (the grid sorts starred-first).
    /// Relocated here from the per-song `NotesDocument` in schema v2 so a
    /// star toggle writes only the recoverable library file and can never
    /// clobber the precious notes. Missing on decode -> `false`.
    var starred: Bool
    /// Pinned playback file, relative to the song folder (e.g.
    /// "bounces/MySong 1.3.wav" or "_MASTERS/master.wav"). `nil` = follow
    /// the latest bounce. Relocated from `NotesDocument` in schema v2.
    var selectedAudioPath: String?
    /// Newest-bounce modDate at the moment `selectedAudioPath` was pinned.
    /// The pin is sticky until a strictly-newer bounce appears, then
    /// auto-releases. `nil` when nothing is pinned. Relocated in schema v2.
    var pinWatermark: Date?

    var id: String { displayName.lowercased() }

    init(displayName: String, addedAt: Date, hideTitle: Bool = false, status: SongStatus = .inProgress,
         starred: Bool = false, selectedAudioPath: String? = nil, pinWatermark: Date? = nil) {
        self.displayName = displayName
        self.addedAt = addedAt
        self.hideTitle = hideTitle
        self.status = status
        self.starred = starred
        self.selectedAudioPath = selectedAudioPath
        self.pinWatermark = pinWatermark
    }

    private enum CodingKeys: String, CodingKey {
        case displayName, addedAt, hideTitle, status, starred, selectedAudioPath, pinWatermark
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.addedAt = try c.decode(Date.self, forKey: .addedAt)
        self.hideTitle = try c.decodeIfPresent(Bool.self, forKey: .hideTitle) ?? false
        self.status = try c.decodeIfPresent(SongStatus.self, forKey: .status) ?? .inProgress
        self.starred = try c.decodeIfPresent(Bool.self, forKey: .starred) ?? false
        self.selectedAudioPath = try c.decodeIfPresent(String.self, forKey: .selectedAudioPath)
        self.pinWatermark = try c.decodeIfPresent(Date.self, forKey: .pinWatermark)
    }
}
