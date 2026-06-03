import AppKit
import SwiftUI
import SwiftyDropbox

/// First-launch screen. Tapping Connect kicks off the Dropbox PKCE OAuth
/// flow in the user's default browser (`NSWorkspace.shared.open(url)`).
/// After approval Dropbox redirects to `db-<APPKEY>://...` which routes
/// back to the app via the URL scheme registered in `Info-macOS.plist`,
/// and `Adenel_SongsApp.onOpenURL` finishes the handshake.
struct DropboxConnectView: View {
    var store: SongStore

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "link.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Connect Dropbox")
                .font(.title.weight(.bold))
            Text("This app needs access to your Dropbox to read your song folders. You'll be sent to Dropbox to approve, then bounced back here.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
                .padding(.horizontal, 32)
            Spacer()
            Button {
                startAuth()
            } label: {
                Text("Connect with Dropbox")
                    .font(.headline)
                    .frame(maxWidth: 320)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 40)
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    private func startAuth() {
        // SwiftyDropbox falls back to `NSApp.keyWindow?.contentViewController`
        // when `controller` is nil, which is what we want under SwiftUI
        // (we don't have a real NSViewController handy).
        DropboxClientsManager.authorizeFromControllerV2(
            sharedApplication: NSApplication.shared,
            controller: nil,
            loadingStatusDelegate: nil,
            openURL: { url in NSWorkspace.shared.open(url) },
            scopeRequest: nil
        )
    }
}
