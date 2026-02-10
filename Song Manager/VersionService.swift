import Foundation

enum VersionService {
    static let versionPattern = try! Regex(" (\\d+(?:\\.\\d+)*)$")

    static func parseVersion(fromStem stem: String) -> [Int]? {
        guard let match = stem.firstMatch(of: versionPattern),
              let capture = match.output[1].substring else { return nil }
        return String(capture).split(separator: ".").compactMap { Int($0) }
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
        guard var parts = parseVersion(fromStem: stem) else {
            return stem + " 1.\(ext)"
        }
        parts[parts.count - 1] += 1
        let baseName = stem.replacing(versionPattern, with: "")
        let newVersion = parts.map(String.init).joined(separator: ".")
        return "\(baseName) \(newVersion).\(ext)"
    }
}
