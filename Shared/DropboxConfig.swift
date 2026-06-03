import Foundation

enum DropboxConfig {
    /// Public Dropbox app key (the "App key" field on the Dropbox developer
    /// console). Safe to commit. The app uses this together with a refresh
    /// token (stored in Keychain) to mint short-lived access tokens.
    static let appKey = "cuti3ayzmx7e7ma"
}
