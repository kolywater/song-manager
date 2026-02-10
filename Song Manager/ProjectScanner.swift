import AppKit

enum ProjectScanner {
    struct ScanResult {
        var alsFiles: [URL] = []
        var bounceFiles: [URL] = []
        var hasMastersFolder: Bool = false
        var masterFiles: [URL] = []
        var albumArtURL: URL?
    }

    static func scan(rootURL: URL) -> ScanResult {
        var result = ScanResult()
        let fm = FileManager.default

        // Scan for .als files in the root directory
        if let contents = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            result.alsFiles = contents
                .filter { $0.pathExtension.lowercased() == "als" }
                .sorted { a, b in
                    let stemA = a.deletingPathExtension().lastPathComponent
                    let stemB = b.deletingPathExtension().lastPathComponent
                    let vA = VersionService.parseVersion(fromStem: stemA) ?? []
                    let vB = VersionService.parseVersion(fromStem: stemB) ?? []
                    return VersionService.compare(vA, vB) == .orderedAscending
                }
        }

        // Scan bounces/ folder
        let bouncesURL = rootURL.appending(path: "bounces")
        if let contents = try? fm.contentsOfDirectory(
            at: bouncesURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            let audioExtensions: Set<String> = ["wav", "mp3", "aif", "aiff", "flac", "m4a"]
            result.bounceFiles = contents
                .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { a, b in
                    let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    return dateA < dateB
                }
        }

        // Scan _MASTERS/ folder
        let mastersURL = rootURL.appending(path: "_MASTERS")
        var isDir: ObjCBool = false
        result.hasMastersFolder = fm.fileExists(atPath: mastersURL.path(percentEncoded: false), isDirectory: &isDir) && isDir.boolValue
        if let contents = try? fm.contentsOfDirectory(
            at: mastersURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            let audioExtensions: Set<String> = ["wav", "mp3", "aif", "aiff", "flac", "m4a"]
            result.masterFiles = contents
                .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { a, b in
                    let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    return dateA < dateB
                }
        }

        // Scan _ALBUM ART/ folder for images
        let artURL = rootURL.appending(path: "_ALBUM ART")
        if let contents = try? fm.contentsOfDirectory(
            at: artURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "webp"]
            let images = contents
                .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { a, b in
                    let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    return dateA > dateB
                }
            result.albumArtURL = images.first
        }

        return result
    }

    static func loadAlbumArt(from url: URL?) -> NSImage? {
        guard let url else { return nil }
        return NSImage(contentsOf: url)
    }
}
