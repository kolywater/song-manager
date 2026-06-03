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
    }
}

extension Notification.Name {
    /// Shared with iOS — both targets post this on successful OAuth
    /// completion so their SongStore can rebuild from the new token.
    static let dropboxAuthDidChange = Notification.Name("dropboxAuthDidChange")
}
