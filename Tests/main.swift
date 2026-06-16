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

// MARK: - Report

if failures.isEmpty {
    print("✓ all \(checks) checks passed")
    exit(0)
} else {
    print(failures.joined(separator: "\n"))
    print("\n\(failures.count)/\(checks) checks FAILED")
    exit(1)
}
