import Foundation

// Standalone test driver for the version-handling logic. There is no
// XCTest target in the Xcode project, and `VersionService` /
// `FileActions` are pure Foundation + AppKit, so we compile them directly
// alongside this file and run a tiny assertion harness:
//
//   swiftc Shared/VersionService.swift \
//          "Song Manager macOS/FileActions.swift" \
//          Tests/VersionServiceTests.swift -o /tmp/versiontests && /tmp/versiontests
//
// or just `just test`. Exits non-zero if any check fails.

// MARK: - Tiny harness

var failures: [String] = []
var checks = 0

func expect<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected {
        failures.append("✗ \(label)\n    expected: \(expected)\n    actual:   \(actual)")
    }
}

// MARK: - VersionService.parse (bare version strings)

expect(VersionService.parse(versionString: "1.2"), [1, 2], "parse 1.2")
expect(VersionService.parse(versionString: "v1.2.3"), [1, 2, 3], "parse v1.2.3")
expect(VersionService.parse(versionString: "  3 "), [3], "parse padded 3")
expect(VersionService.parse(versionString: "abc"), nil, "parse non-numeric → nil")

// MARK: - splitVersion / parseVersion (filename stems)

func split(_ stem: String) -> (String, [Int]?) {
    let r = VersionService.splitVersion(fromStem: stem)
    return (r.base, r.version)
}

expect(split("peaches 1.1").0, "peaches", "split base: peaches 1.1")
expect(split("peaches 1.1").1, [1, 1], "split version: peaches 1.1")

// No version suffix → base is the whole (trimmed) stem, version nil.
expect(split("peaches").0, "peaches", "split base: peaches (no version)")
expect(split("peaches").1, nil, "split version: peaches (no version)")

// The bug this fixes: a descriptive suffix after the version must not
// hide the version, and must be dropped from the base name.
expect(split("project 1.1 chris feedback").0, "project", "split base: descriptive suffix")
expect(split("project 1.1 chris feedback").1, [1, 1], "split version: descriptive suffix")

// A number inside the song name must not be mistaken for the version —
// the LAST version-like token wins.
expect(split("Track 2 1.1").0, "Track 2", "split base: number in name")
expect(split("Track 2 1.1").1, [1, 1], "split version: number in name")

// Ableton auto-backup format: "<name> <version> [timestamp]". The
// bracketed timestamp is not a version token (no leading space + dot
// digits terminated by space/end), so 1.1 still wins.
expect(split("peaches 1.1 [2026-06-08 112540]").1, [1, 1], "split version: ableton backup")
expect(split("peaches 1.1 [2026-06-08 112540]").0, "peaches", "split base: ableton backup")

// Multi-component versions are preserved.
expect(split("song 1.2.3").1, [1, 2, 3], "split version: 1.2.3")

// parseVersion is a thin wrapper over splitVersion.
expect(VersionService.parseVersion(fromStem: "peaches 1.1"), [1, 1], "parseVersion: peaches 1.1")
expect(VersionService.parseVersion(fromStem: "peaches"), nil, "parseVersion: no version")

// MARK: - suggestedBump

expect(VersionService.suggestedBump(from: [1, 1]), "1.2", "bump 1.1 → 1.2")
expect(VersionService.suggestedBump(from: [1, 1, 1]), "1.1.2", "bump 1.1.1 → 1.1.2")
expect(VersionService.suggestedBump(from: [1]), "2", "bump 1 → 2")

// MARK: - bumpedFilename

expect(VersionService.bumpedFilename(from: "peaches 1.1.als", ext: "als"),
       "peaches 1.2.als", "bumpedFilename: peaches 1.1 → 1.2")
expect(VersionService.bumpedFilename(from: "project 1.1 chris feedback.als", ext: "als"),
       "project 1.2.als", "bumpedFilename: drops descriptive suffix")
expect(VersionService.bumpedFilename(from: "peaches.als", ext: "als"),
       "peaches 1.als", "bumpedFilename: no version → ' 1'")

// MARK: - FileActions against the real example project

let here = URL(fileURLWithPath: #filePath)            // .../Tests/VersionServiceTests.swift
let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
let example = repoRoot.appending(path: "example project")

if FileManager.default.fileExists(atPath: example.path) {
    // Read-only: the most recently modified root .als is "peaches 1.1.als",
    // so the suggested next version is 1.2.
    expect(FileActions.suggestedNextVersion(in: example), "1.2",
           "suggestedNextVersion(example project)")

    // Destructive: run duplicateLatestALS against a temp COPY so we never
    // mutate the committed fixture.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "vstest-\(UUID().uuidString)")
    do {
        try FileManager.default.copyItem(at: example, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let created = try FileActions.duplicateLatestALS(in: tmp, version: "1.2")
        expect(created?.lastPathComponent, "peaches 1.2.als",
               "duplicateLatestALS names new file from clean base")
        expect(created.map { FileManager.default.fileExists(atPath: $0.path) }, true,
               "duplicateLatestALS actually writes the file")
    } catch {
        failures.append("✗ duplicateLatestALS integration threw: \(error)")
        checks += 1
    }
} else {
    print("⚠︎ skipping example-project integration tests (folder not found at \(example.path))")
}

// MARK: - SyncMerge: note operations (conflict-safe sync)

func applyOp(_ op: SyncMerge.NoteOp, to notes: [Note]) -> [Note] {
    var n = notes
    SyncMerge.apply(op, to: &n)
    return n
}

let nid1 = UUID(), nid2 = UUID(), nid3 = UUID()
let baseNotes = [Note(id: nid1, time: 3.0, text: "three"),
                 Note(id: nid2, time: 1.0, text: "one")]

// upsert (add) inserts and keeps the list time-sorted.
expect(applyOp(.upsert(Note(id: nid3, time: 2.0, text: "two")), to: baseNotes).map(\.text),
       ["one", "two", "three"], "upsert adds and sorts by time")

// upsert on an existing id replaces in place — never duplicates (idempotent retry).
let upReplaced = applyOp(.upsert(Note(id: nid1, time: 3.0, text: "THREE")), to: baseNotes)
expect(upReplaced.count, 2, "upsert by existing id does not duplicate")
expect(upReplaced.first(where: { $0.id == nid1 })?.text, "THREE", "upsert replaces by id")

// replaceIfPresent edits an existing note...
expect(applyOp(.replaceIfPresent(Note(id: nid2, time: 1.0, text: "ONE")), to: baseNotes)
        .first(where: { $0.id == nid2 })?.text, "ONE", "replaceIfPresent edits existing")

// ...but SKIPS a note that isn't there — the no-resurrection guarantee.
let skipped = applyOp(.replaceIfPresent(Note(id: nid3, time: 5.0, text: "ghost")), to: baseNotes)
expect(skipped.count, 2, "replaceIfPresent skips when id absent (no resurrection)")
expect(skipped.contains(where: { $0.id == nid3 }), false, "replaceIfPresent adds no ghost")

// remove deletes by id and is idempotent.
let removed = applyOp(.remove(nid1), to: baseNotes)
expect(removed.map(\.id), [nid2], "remove deletes by id")
expect(applyOp(.remove(nid1), to: removed).map(\.id), [nid2], "remove is idempotent")

// Op-replay: another device deleted nid1 (server is now [nid2]); replaying our
// local "add nid3" onto the FRESH server list must keep nid1 gone.
let merged = applyOp(.upsert(Note(id: nid3, time: 2.0, text: "two")), to: [baseNotes[1]])
expect(merged.contains(where: { $0.id == nid1 }), false, "op-replay: deleted note stays gone")
expect(merged.contains(where: { $0.id == nid3 }), true, "op-replay: local add preserved")

// MARK: - SyncMerge: library entry updates

var lib = LibraryDocument(items: [LibraryEntry(displayName: "Peaches", addedAt: Date())])
expect(SyncMerge.updateEntry("peaches", in: &lib) { $0.starred = true }, true,
       "updateEntry matches case-insensitively")
expect(lib.items.first?.starred, true, "updateEntry mutates the entry")
// A field change to a song that was removed elsewhere is dropped, not recreated.
expect(SyncMerge.updateEntry("ghost song", in: &lib) { $0.starred = true }, false,
       "updateEntry no-ops when song absent")
expect(lib.items.count, 1, "updateEntry does not recreate a removed song")

// MARK: - Codec: notes-only NotesDocument (v3) + legacy migration tolerance

// A legacy v2 file (with the metadata that moved to the library) decodes —
// the metadata keys are ignored and only the notes survive.
let legacyNotesJSON = """
{"version":2,"notes":[{"id":"\(nid1.uuidString)","time":1.0,"text":"hi","tags":[],"createdAt":0}],"starred":true,"selectedAudioPath":"bounces/x.wav","pinWatermark":0}
"""
let decodedNotes = try! JSONDecoder().decode(NotesDocument.self, from: Data(legacyNotesJSON.utf8))
expect(decodedNotes.notes.count, 1, "legacy v2 notes file still decodes its notes")
// Re-encoding produces a notes-only document (the relocated keys are gone).
let reencoded = String(data: try! JSONEncoder().encode(decodedNotes), encoding: .utf8)!
expect(reencoded.contains("starred"), false, "re-encoded notes doc drops starred")
expect(reencoded.contains("selectedAudioPath"), false, "re-encoded notes doc drops selectedAudioPath")
expect(reencoded.contains("pinWatermark"), false, "re-encoded notes doc drops pinWatermark")

// A legacy library entry (pre-v2, no relocated fields) decodes with safe defaults.
let legacyEntryJSON = """
{"displayName":"X","addedAt":0,"hideTitle":true,"status":"released"}
"""
let decodedEntry = try! JSONDecoder().decode(LibraryEntry.self, from: Data(legacyEntryJSON.utf8))
expect(decodedEntry.starred, false, "legacy entry defaults starred=false")
expect(decodedEntry.selectedAudioPath, nil, "legacy entry defaults selectedAudioPath=nil")
expect(decodedEntry.pinWatermark, nil, "legacy entry defaults pinWatermark=nil")

// MARK: - Report

if failures.isEmpty {
    print("✓ all \(checks) checks passed")
    exit(0)
} else {
    print(failures.joined(separator: "\n"))
    print("\n\(failures.count)/\(checks) checks FAILED")
    exit(1)
}
