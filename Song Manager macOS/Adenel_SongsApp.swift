import SwiftUI
import SwiftyDropbox

@main
struct Adenel_SongsApp: App {
    init() {
        // FileBackedTokenStore swaps out Keychain so the refresh token
        // survives Debug rebuilds (ad-hoc signing changes the codesign
        // hash, which invalidates Keychain ACLs). See the file for the
        // security tradeoff.
        DropboxClientsManager.setupWithAppKeyDesktop(
            DropboxConfig.appKey,
            secureStorageAccess: FileBackedTokenStore()
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Album-art-forward grid was designed for a dark chrome;
                // pinning the whole app to dark keeps the look consistent
                // regardless of the system appearance setting.
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    // The Dropbox redirect arrives as `db-<APPKEY>://...`.
                    // SwiftyDropbox parses the URL, stores the refresh
                    // token via the configured secureStorageAccess, and
                    // signals via the notification so the store rebuilds.
                    DropboxClientsManager.handleRedirectURL(url, includeBackgroundClient: false) { result in
                        if case .success = result {
                            NotificationCenter.default.post(name: .dropboxAuthDidChange, object: nil)
                        }
                    }
                }
        }
        .defaultSize(width: 980, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            // Sits just under the "About" item in the app menu. The check
            // itself lives in ContentView's Updater; we just signal it.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    NotificationCenter.default.post(name: .checkForUpdatesRequested, object: nil)
                }
            }
        }
    }
}

extension Notification.Name {
    /// Shared with iOS — both targets post this on successful OAuth
    /// completion so their SongStore can rebuild from the new token.
    static let dropboxAuthDidChange = Notification.Name("dropboxAuthDidChange")

    /// Posted by the "Check for Updates…" menu command; ContentView's
    /// Updater listens and runs a user-initiated check.
    static let checkForUpdatesRequested = Notification.Name("checkForUpdatesRequested")
}
