import Foundation

/// A playable audio file in a song folder. `relativePath` is the
/// canonical key used everywhere — NotesDocument selection, picker
/// rows, Dropbox URL resolution.
struct AudioFileMeta: Identifiable, Hashable {
    var filename: String
    var relativePath: String
    var modDate: Date
    var isMaster: Bool

    var id: String { relativePath }
}
