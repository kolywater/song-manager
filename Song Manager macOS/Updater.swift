import AppKit
import Foundation
import Observation

/// In-app self-update for the Mac build, sourced from GitHub releases.
///
/// The app is ad-hoc signed (no Developer ID / notarization), so any
/// build downloaded from the internet carries the `com.apple.quarantine`
/// flag and Gatekeeper would block the relaunch ("Open Anyway"). To get a
/// clean in-place update we strip that attribute (`xattr -dr`) on the new
/// bundle before swapping it in. This is fighting Gatekeeper's intent and
/// is only acceptable because it's a personal app installed on the user's
/// own Macs.
///
/// Release convention on `kolywater/song-manager`:
///   - tag the release `v<version>` (e.g. `v1.1`), matching the app's
///     `CFBundleShortVersionString` (MARKETING_VERSION),
///   - attach a single zipped bundle as a `.zip` asset, e.g.
///     `ditto -c -k --keepParent "Song Manager.app" SongManager.zip`.
@MainActor
@Observable
final class Updater {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case downloading
        case installing
        case failed(String)
    }

    struct ReleaseInfo: Equatable {
        let version: String      // raw tag, e.g. "v1.1" (shown to the user)
        let notes: String
        let downloadURL: URL
    }

    private(set) var status: Status = .idle

    /// The pending update, if one was found. Drives the alert in ContentView.
    var available: ReleaseInfo? {
        if case let .available(info) = status { return info }
        return nil
    }

    /// True while a download/swap is in flight — used to show a blocking
    /// "Updating…" overlay (the app terminates itself at the end).
    var isBusy: Bool {
        switch status {
        case .downloading, .installing: return true
        default: return false
        }
    }

    private let repo = "kolywater/song-manager"

    /// The running app's version, e.g. "1.0".
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: - Check

    /// Query GitHub for the latest release and compare versions. On a
    /// background check we stay silent unless an update is found; on a
    /// user-initiated check we also surface "up to date" / failures.
    func check(userInitiated: Bool) async {
        if isBusy { return }
        status = .checking
        do {
            let release = try await fetchLatestRelease()
            let current = VersionService.parse(versionString: Self.currentVersion) ?? []
            let latest = VersionService.parse(versionString: release.version) ?? []
            if VersionService.compare(latest, current) == .orderedDescending {
                status = .available(release)
            } else {
                status = userInitiated ? .upToDate : .idle
            }
        } catch {
            status = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    /// Reset transient result states (up-to-date / failed) back to idle —
    /// called when the user dismisses the info alert.
    func clearResult() {
        switch status {
        case .upToDate, .failed:
            status = .idle
        default:
            break
        }
    }

    private func fetchLatestRelease() async throws -> ReleaseInfo {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.noRelease
        }
        let decoded = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let asset = decoded.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }),
              let downloadURL = URL(string: asset.browser_download_url) else {
            throw UpdateError.noAsset
        }
        return ReleaseInfo(
            version: decoded.tag_name,
            notes: decoded.body ?? "",
            downloadURL: downloadURL
        )
    }

    // MARK: - Install

    /// Download the pending update, swap it in, and relaunch. Does not
    /// return on success — the app terminates so a helper can replace the
    /// running bundle.
    func install() async {
        guard case let .available(info) = status else { return }
        do {
            status = .downloading
            let zipURL = try await download(info.downloadURL)
            status = .installing
            try installZip(zipURL)   // relaunches + terminates
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func download(_ url: URL) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.downloadFailed
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("SongManagerUpdate-\(UUID().uuidString).zip")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    private func installZip(_ zipURL: URL) throws {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("SongManagerUpdate-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: zipURL) }

        // ditto preserves bundle structure / symlinks better than unzip.
        try run("/usr/bin/ditto", ["-x", "-k", zipURL.path, workDir.path])

        guard let newApp = try fm.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.badArchive
        }

        // Strip Gatekeeper quarantine so the relaunch isn't blocked.
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

        let currentApp = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier

        // We can't reliably replace our own running bundle from inside the
        // process, so hand off to a detached shell: wait for us to quit,
        // swap the bundle, relaunch.
        let script = """
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf \(shellQuote(currentApp.path))
        /bin/mv \(shellQuote(newApp.path)) \(shellQuote(currentApp.path))
        /usr/bin/open \(shellQuote(currentApp.path))
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try task.run()

        NSApp.terminate(nil)
    }

    @discardableResult
    private func run(_ launchPath: String, _ args: [String]) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            throw UpdateError.commandFailed(launchPath)
        }
        return task.terminationStatus
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Wire

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let body: String?
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
    }

    enum UpdateError: LocalizedError {
        case noRelease, noAsset, downloadFailed, badArchive, commandFailed(String)
        var errorDescription: String? {
            switch self {
            case .noRelease: return "No release found on GitHub."
            case .noAsset: return "The latest release has no .zip asset."
            case .downloadFailed: return "Download failed."
            case .badArchive: return "The downloaded archive didn't contain an app."
            case .commandFailed(let c): return "Update step failed (\(c))."
            }
        }
    }
}
