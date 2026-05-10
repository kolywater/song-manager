import SwiftUI
import SwiftyDropbox
import UIKit

/// One-time setup screen. Tapping Connect opens the Dropbox PKCE OAuth
/// flow in Safari. After approval Dropbox redirects back via the
/// `db-<APPKEY>` URL scheme, the app catches it in `.onOpenURL`, and
/// SwiftyDropbox stores the refresh token in the Keychain.
struct DropboxConnectView: View {
    var store: SongStore

    var body: some View {
        NavigationStack {
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
                    .padding(.horizontal, 32)
                Spacer()
                Button {
                    startAuth()
                } label: {
                    Text("Connect with Dropbox")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
        }
    }

    private func startAuth() {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let rootVC = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            return
        }
        // Find the topmost presented controller so the OAuth UI doesn't
        // try to present from one that's already presenting this sheet.
        var top = rootVC
        while let presented = top.presentedViewController { top = presented }

        DropboxClientsManager.authorizeFromControllerV2(
            UIApplication.shared,
            controller: top,
            loadingStatusDelegate: nil,
            openURL: { url in UIApplication.shared.open(url) },
            scopeRequest: nil
        )
    }
}
