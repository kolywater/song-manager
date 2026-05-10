//
//  Song_Manager_iOSApp.swift
//  Song Manager iOS
//
//  Created by Aiden Elliott on 5/9/26.
//

import SwiftUI
import SwiftyDropbox

@main
struct Song_Manager_iOSApp: App {
    init() {
        DropboxClientsManager.setupWithAppKey(DropboxConfig.appKey)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    DropboxClientsManager.handleRedirectURL(url, includeBackgroundClient: false) { result in
                        if case .success = result {
                            NotificationCenter.default.post(name: .dropboxAuthDidChange, object: nil)
                        }
                    }
                }
        }
    }
}

extension Notification.Name {
    static let dropboxAuthDidChange = Notification.Name("dropboxAuthDidChange")
}
