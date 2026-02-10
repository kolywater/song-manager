import AppKit

enum FileActions {
    static func showInFinder(_ rootURL: URL) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: rootURL.path(percentEncoded: false))
    }

    static func openLatestALS(in rootURL: URL) {
        let scanResult = ProjectScanner.scan(rootURL: rootURL)
        guard let latestALS = scanResult.alsFiles.last else { return }
        NSWorkspace.shared.open(latestALS)
    }

    static func openLatestBounce(in rootURL: URL) {
        let scanResult = ProjectScanner.scan(rootURL: rootURL)
        guard let latestBounce = scanResult.bounceFiles.last else { return }
        NSWorkspace.shared.open(latestBounce)
    }

    static func duplicateLatestALS(in rootURL: URL, version: String) throws -> URL? {
        let scanResult = ProjectScanner.scan(rootURL: rootURL)
        guard let latestALS = scanResult.alsFiles.last else { return nil }
        let stem = (latestALS.deletingPathExtension().lastPathComponent as NSString)
        let baseName = String(stem).replacing(VersionService.versionPattern, with: "")
        let newFilename = "\(baseName) \(version).als"
        let destinationURL = rootURL.appending(path: newFilename)
        try FileManager.default.copyItem(at: latestALS, to: destinationURL)
        return destinationURL
    }
}
