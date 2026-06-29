import Foundation

/// Pure, dependency-free helpers for conflict-safe Dropbox sync.
///
/// Conflicts are detected server-side: a conditional upload (`mode:
/// .update(rev)`) is rejected by Dropbox when the file's `rev` moved since
/// we loaded it. On rejection the store **re-pulls the current file and
/// re-applies the single user operation** to that fresh copy, rather than
/// merging two whole-document snapshots. Replaying the op (not unioning
/// state) is what guarantees a note deleted on another device never
/// resurrects — the re-pulled list already lacks it, and we only re-apply
/// "the one thing the user just did".
///
/// These functions are intentionally free of Dropbox / store / SwiftUI
/// types so the standalone `just unit-tests` driver can exercise them
/// without a network or Xcode.
enum SyncMerge {

    // MARK: - Notes operations

    /// A single user edit to a song's note list, replayable onto the freshest
    /// server copy.
    enum NoteOp: Equatable {
        /// Add a note, or replace it in place if its `id` is already present.
        /// Used for the "add note" action; idempotent so a retry after a
        /// partial failure can neither duplicate nor corrupt.
        case upsert(Note)
        /// Edit an existing note — replace by `id`, but **do nothing if the
        /// note is absent**. This is the "no resurrection" guarantee: an edit
        /// can never re-introduce a note that was deleted on another device.
        case replaceIfPresent(Note)
        /// Delete a note by `id`. Idempotent (no-op if already gone).
        case remove(UUID)
    }

    /// Apply one operation to a notes array in place, keeping it sorted by
    /// `time` (the timeline order the UI renders).
    static func apply(_ op: NoteOp, to notes: inout [Note]) {
        switch op {
        case .upsert(let note):
            if let idx = notes.firstIndex(where: { $0.id == note.id }) {
                notes[idx] = note
            } else {
                notes.append(note)
            }
            notes.sort { $0.time < $1.time }
        case .replaceIfPresent(let note):
            guard let idx = notes.firstIndex(where: { $0.id == note.id }) else { return }
            notes[idx] = note
            notes.sort { $0.time < $1.time }
        case .remove(let id):
            notes.removeAll { $0.id == id }
        }
    }

    // MARK: - Library entry field updates

    /// Apply a mutation to a single song's `LibraryEntry`, matched by the
    /// cross-device identity key (`displayName`, case-insensitively). No-op if
    /// the song isn't in the freshly-pulled list (it was removed on another
    /// device) — the caller's field change is simply dropped rather than
    /// re-creating a deleted entry, mirroring the notes "no resurrection" rule.
    @discardableResult
    static func updateEntry(_ displayName: String,
                            in doc: inout LibraryDocument,
                            _ mutate: (inout LibraryEntry) -> Void) -> Bool {
        let key = displayName.lowercased()
        guard let idx = doc.items.firstIndex(where: { $0.id == key }) else { return false }
        mutate(&doc.items[idx])
        return true
    }
}
