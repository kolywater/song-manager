import Foundation

enum VersionService {
    /// Matches a version token inside a filename stem: a leading space,
    /// dot-separated integers, terminated by a space or the end of the
    /// stem. Capture 1 is the bare version ("1.2").
    ///
    /// The trailing `(?= |$)` (rather than a hard `$`) lets the version
    /// sit mid-stem, so descriptive suffixes like "Song 1.1 chris
    /// feedback" still expose "1.1". `parseVersion`/`splitVersion` take
    /// the *last* such token, so a song name that itself contains a
    /// number ("Track 2 1.1") resolves to the real version (1.1), not the
    /// number in the name.
    static let versionPattern = try! Regex(#" (\d+(?:\.\d+)*)(?= |$)"#)

    /// Parse a bare version / git-tag string ("1.2", "v1.2.3") into its
    /// integer components. Tolerates a leading "v". Returns nil if no
    /// digits are present.
    static func parse(versionString: String) -> [Int]? {
        let trimmed = versionString.trimmingCharacters(in: .whitespaces)
        let stripped = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
            ? String(trimmed.dropFirst())
            : trimmed
        let parts = stripped.split(separator: ".").compactMap { Int($0) }
        return parts.isEmpty ? nil : parts
    }

    static func parseVersion(fromStem stem: String) -> [Int]? {
        splitVersion(fromStem: stem).version
    }

    /// Split a filename stem into its base name (everything before the
    /// version token) and the version components. Uses the *last* version
    /// token in the stem and drops anything after it, so
    /// "Song 1.1 chris feedback" → (base: "Song", version: [1, 1]).
    /// Returns (base: trimmed stem, version: nil) when no version is found.
    static func splitVersion(fromStem stem: String) -> (base: String, version: [Int]?) {
        guard let match = stem.matches(of: versionPattern).last,
              let capture = match.output[1].substring else {
            return (stem.trimmingCharacters(in: .whitespaces), nil)
        }
        let base = String(stem[stem.startIndex..<match.range.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let version = String(capture).split(separator: ".").compactMap { Int($0) }
        return (base, version)
    }

    static func compare(_ a: [Int], _ b: [Int]) -> ComparisonResult {
        let count = max(a.count, b.count)
        for i in 0..<count {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av < bv { return .orderedAscending }
            if av > bv { return .orderedDescending }
        }
        return .orderedSame
    }

    static func suggestedBump(from version: [Int]) -> String {
        var parts = version
        parts[parts.count - 1] += 1
        return parts.map(String.init).joined(separator: ".")
    }

    static func bumpedFilename(from filename: String, ext: String) -> String {
        let stem = (filename as NSString).deletingPathExtension
        let (baseName, parts) = splitVersion(fromStem: stem)
        guard var parts else {
            return stem + " 1.\(ext)"
        }
        parts[parts.count - 1] += 1
        let newVersion = parts.map(String.init).joined(separator: ".")
        return "\(baseName) \(newVersion).\(ext)"
    }
}
