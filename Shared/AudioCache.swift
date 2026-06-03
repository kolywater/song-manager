import Darwin
import Foundation

/// Per-bounce on-disk cache for streamed Dropbox audio. Files are keyed
/// by `<projectID>/<filename>` so different versions coexist. Lives in
/// the app's Documents directory (excluded from iCloud/device backup)
/// so iOS won't evict under storage pressure — critical because the
/// only path back to a bounce when offline is what's already on disk.
/// We LRU-prune to a hard byte cap on every successful download.
nonisolated final class AudioCache {
    static let shared = AudioCache()
    private init() {}

    /// Hard cap on the audio cache. ~1.5 GB ≈ 20–30 uncompressed bounces.
    private static let maxBytes: Int64 = 1_500_000_000

    private static func cacheDir() -> URL {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appending(path: "Audio")
        if !fm.fileExists(atPath: dir.path(percentEncoded: false)) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var mutable = dir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? mutable.setResourceValues(values)
        }
        migrateFromCachesIfNeeded(into: dir)
        return dir
    }

    /// Cached audio used to live in `cachesDirectory/Audio` where iOS
    /// could evict it. Move anything still there into the Documents
    /// location on first access; idempotent once oldDir is gone.
    private static func migrateFromCachesIfNeeded(into newDir: URL) {
        let fm = FileManager.default
        let oldDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!.appending(path: "Audio")
        guard fm.fileExists(atPath: oldDir.path(percentEncoded: false)) else { return }
        if let entries = try? fm.contentsOfDirectory(at: oldDir, includingPropertiesForKeys: nil) {
            for entry in entries {
                let dest = newDir.appending(path: entry.lastPathComponent)
                if !fm.fileExists(atPath: dest.path(percentEncoded: false)) {
                    try? fm.moveItem(at: entry, to: dest)
                }
            }
        }
        try? fm.removeItem(at: oldDir)
    }

    static func localPath(projectID: UUID, filename: String) -> URL {
        let projectDir = cacheDir().appending(path: projectID.uuidString)
        try? FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        return projectDir.appending(path: filename)
    }

    /// Returns the local URL if the file is on disk; touches its modification
    /// date so LRU prune sees this as fresh.
    func localURL(projectID: UUID, filename: String) -> URL? {
        let url = Self.localPath(projectID: projectID, filename: filename)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()],
                                               ofItemAtPath: url.path(percentEncoded: false))
        return url
    }

    /// Most-recently-touched cached file for this project, if any. Used
    /// as an offline fallback when we don't know the exact filename to
    /// play (e.g. no explicit `selectedAudioPath` and Dropbox is
    /// unreachable so we can't ask for the latest bounce).
    func latestCachedURL(projectID: UUID) -> URL? {
        let fm = FileManager.default
        let dir = Self.localPath(projectID: projectID, filename: "").deletingLastPathComponent()
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys
        ) else { return nil }
        let scored: [(URL, Date)] = entries.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }
        return scored.sorted { $0.1 > $1.1 }.first?.0
    }

    /// Downloads a remote URL into the cache. Idempotent — if the file is
    /// already on disk we return it without re-fetching. Triggers a prune
    /// pass after each successful download. `remoteModified` is stamped
    /// onto the cached file as an xattr so callers can later detect a
    /// same-name remote replacement and invalidate the cache.
    @discardableResult
    func download(from remote: URL, projectID: UUID, filename: String, remoteModified: Date? = nil) async throws -> URL {
        let dest = Self.localPath(projectID: projectID, filename: filename)
        if FileManager.default.fileExists(atPath: dest.path(percentEncoded: false)) {
            try? FileManager.default.setAttributes([.modificationDate: Date()],
                                                   ofItemAtPath: dest.path(percentEncoded: false))
            if let remoteModified { Self.setRemoteModified(remoteModified, at: dest) }
            return dest
        }
        let (tmp, _) = try await URLSession.shared.download(from: remote)
        if FileManager.default.fileExists(atPath: dest.path(percentEncoded: false)) {
            try? FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: tmp, to: dest)
        if let remoteModified { Self.setRemoteModified(remoteModified, at: dest) }
        Task.detached { Self.prune() }
        return dest
    }

    /// Drop a single cached file. Used when we detect the remote version
    /// no longer matches what's on disk (same-name replacement).
    func invalidate(projectID: UUID, filename: String) {
        let url = Self.localPath(projectID: projectID, filename: filename)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Remote modified xattr
    //
    // We can't reuse the file's mtime as "what remote version this is" —
    // `localURL` and `download` already touch mtime to keep the cache
    // fresh for the LRU prune. Store the Dropbox clientModified as an
    // extended attribute on the cached file instead. xattr survives
    // moves within the filesystem and disappears with the file, so we
    // don't need a sidecar.

    private static let remoteModifiedXAttr = "com.adenel.songmanager.remoteModified"

    /// Returns nil for files with no stamp (legacy caches downloaded
    /// before this xattr existed) — callers should treat that as "version
    /// unknown" and refresh.
    func remoteModified(projectID: UUID, filename: String) -> Date? {
        let url = Self.localPath(projectID: projectID, filename: filename)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return Self.remoteModified(at: url)
    }

    private static func setRemoteModified(_ date: Date, at url: URL) {
        var value = date.timeIntervalSince1970
        let path = url.path(percentEncoded: false)
        _ = withUnsafePointer(to: &value) { ptr in
            setxattr(path, remoteModifiedXAttr, ptr, MemoryLayout<Double>.size, 0, 0)
        }
    }

    private static func remoteModified(at url: URL) -> Date? {
        let path = url.path(percentEncoded: false)
        var value: Double = 0
        let read = withUnsafeMutablePointer(to: &value) { ptr in
            getxattr(path, remoteModifiedXAttr, ptr, MemoryLayout<Double>.size, 0, 0)
        }
        guard read == MemoryLayout<Double>.size else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    /// Walk the cache, sum bytes, and delete oldest-first until under the cap.
    private nonisolated static func prune() {
        let fm = FileManager.default
        let dir = Self.cacheDir()
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: keys) else { return }

        var entries: [(url: URL, size: Int64, mtime: Date)] = []
        var total: Int64 = 0
        while let url = walker.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  let mtime = values.contentModificationDate else { continue }
            entries.append((url, Int64(size), mtime))
            total += Int64(size)
        }
        guard total > Self.maxBytes else { return }
        let oldestFirst = entries.sorted { $0.mtime < $1.mtime }
        var remaining = total - Self.maxBytes
        for entry in oldestFirst where remaining > 0 {
            if (try? fm.removeItem(at: entry.url)) != nil {
                remaining -= entry.size
            }
        }
    }
}
