import Foundation
import SwiftyDropbox

/// Dev-time replacement for SwiftyDropbox's Keychain-backed storage.
/// Mac Debug builds are ad-hoc signed — every rebuild changes the
/// codesign hash, so Keychain ACLs reject the new binary and the user
/// has to reauth on every iteration. This implementation drops the
/// token to a JSON file in Application Support so it survives rebuilds.
///
/// Security tradeoff: anyone with read access to the user's home folder
/// can lift the refresh token (which grants full Dropbox API access).
/// Acceptable for a personal dev app on a personal machine; would need
/// to revert to Keychain (with a stable Developer-ID signing identity)
/// before shipping.
final class FileBackedTokenStore: SecureStorageAccess {
    private let directory: URL

    init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appending(path: "Adenel Songs/dropbox_tokens", directoryHint: .isDirectory)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.directory = dir
    }

    func checkAccessibilityMigrationOneTime() {
        // No-op: there's no Keychain accessibility flag to migrate.
    }

    func setAccessTokenData(for userId: String, data: Data) -> Bool {
        let url = directory.appending(path: "\(userId).json")
        do {
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    func getAllUserIds() -> [String] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return contents
            .filter { $0.pathExtension.lowercased() == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    func getDropboxAccessToken(for key: String) -> DropboxAccessToken? {
        let url = directory.appending(path: "\(key).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Same fallback shape the default implementation uses: try the
        // structured Codable first, fall back to the raw access-token
        // string the older SDK versions used to write.
        if let decoded = try? JSONDecoder().decode(DropboxAccessToken.self, from: data) {
            return decoded
        }
        if let tokenString = String(data: data, encoding: .utf8) {
            return DropboxAccessToken(accessToken: tokenString, uid: key)
        }
        return nil
    }

    func deleteInfo(for key: String) -> Bool {
        let url = directory.appending(path: "\(key).json")
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    func deleteInfoForAllKeys() -> Bool {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }
        var allOK = true
        for url in contents where url.pathExtension.lowercased() == "json" {
            do {
                try fm.removeItem(at: url)
            } catch {
                allOK = false
            }
        }
        return allOK
    }
}
