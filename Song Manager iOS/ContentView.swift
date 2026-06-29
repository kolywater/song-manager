import SwiftUI
import UIKit

struct ContentView: View {
    @State private var store = SongStore()
    @State private var showAddSheet = false
    @Environment(\.scenePhase) private var scenePhase

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    @ViewBuilder
    private func sectionHeader(_ section: ProjectSection) -> some View {
        Text(section.title)
            .font(.title2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.top, 14)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func contextMenu(for project: ProjectReference) -> some View {
        let currentStatus = store.status[project.id] ?? .inProgress
        ForEach(SongStatus.allCases) { s in
            Button {
                Task { await store.setStatus(s, for: project) }
            } label: {
                Label(s.displayName, systemImage: currentStatus == s ? "checkmark" : s.systemImage)
            }
        }
        Divider()
        Button {
            Task { await store.toggleHideTitle(project) }
        } label: {
            let hidden = store.hideTitle[project.id] == true
            Label(hidden ? "Show title" : "Hide title",
                  systemImage: hidden ? "textformat" : "textformat.alt")
        }
        Button {
            Task { await store.refreshAlbumArt(for: project) }
        } label: {
            Label("Refresh artwork", systemImage: "arrow.clockwise")
        }
        Button(role: .destructive) {
            store.removeProject(project)
        } label: {
            Label("Remove from Library", systemImage: "trash")
        }
    }

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(store.projectSections) { section in
                        Section {
                            ForEach(section.projects) { project in
                                SongCard(project: project, store: store)
                                    .contextMenu { contextMenu(for: project) }
                            }
                        } header: {
                            sectionHeader(section)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
            }
            .background {
                Color.black.ignoresSafeArea()
            }
            .overlay {
                if store.projects.isEmpty {
                    ContentUnavailableView {
                        Label("No songs yet", systemImage: "music.note.list")
                    } description: {
                        Text("Tap + to add a song from Dropbox.")
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $store.sortMode) {
                            ForEach(LibrarySortMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.body.weight(.semibold))
                    }
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddSongSheet(store: store)
            }
            .sheet(isPresented: .constant(!store.isAuthorized)) {
                DropboxConnectView(store: store)
                    .interactiveDismissDisabled()
            }
            .onReceive(NotificationCenter.default.publisher(for: .dropboxAuthDidChange)) { _ in
                store.rebuildSourceFromKeychain()
            }
            .safeAreaInset(edge: .bottom) {
                MiniPlayerView(store: store)
            }
            .overlay(alignment: .top) {
                if let message = store.errorMessage {
                    ToastView(message: message) {
                        store.errorMessage = nil
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(5))
                        if store.errorMessage == message {
                            store.errorMessage = nil
                        }
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: store.errorMessage)
        }
        .fullScreenCover(isPresented: $store.presentingFullPlayer) {
            FullPlayerView(store: store)
        }
        .animation(.easeInOut(duration: 0.2), value: store.projectSections.map(\.id))
        .task {
            if DevHarness.autoOpenPlayer, let first = store.projects.first {
                await store.play(first)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Leaving the foreground: keep the app alive briefly so any
            // in-flight note/metadata upload finishes instead of being
            // stranded half-sent on the device.
            if phase == .background {
                var bgTask = UIBackgroundTaskIdentifier.invalid
                bgTask = UIApplication.shared.beginBackgroundTask(withName: "FlushPendingWrites") {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
                Task { [store] in
                    await store.flushPendingWrites()
                    if bgTask != .invalid {
                        UIApplication.shared.endBackgroundTask(bgTask)
                        bgTask = .invalid
                    }
                }
                return
            }
            // Detached: the refresh fans out Dropbox calls and shouldn't
            // hold up scene activation. The await points inside suspend
            // on network I/O, so main isn't blocked either way.
            guard phase == .active else { return }
            Task.detached { [store] in
                await store.pullLibraryFromDropbox()
            }
            Task.detached { [store] in
                await store.refreshActivityDates()
            }
            Task.detached { [store] in
                await store.refreshStaleAlbumArt()
            }
            Task.detached { [store] in
                await store.refreshCurrentAudio()
            }
        }
    }
}

#Preview {
    ContentView()
}
