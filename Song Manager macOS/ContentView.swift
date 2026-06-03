import SwiftUI

struct ContentView: View {
    @State private var store = SongStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showAddSheet = false
    @State private var newVersionProject: ProjectReference?
    @State private var newVersionText = ""

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 16)
    ]

    var body: some View {
        @Bindable var store = store
        Group {
            if !store.isAuthorized {
                DropboxConnectView(store: store)
            } else {
                gridView
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .navigationTitle("Songs")
        .toolbar { toolbarContent }
        .onReceive(NotificationCenter.default.publisher(for: .dropboxAuthDidChange)) { _ in
            store.rebuildSourceFromKeychain()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task.detached { [store] in await store.pullLibraryFromDropbox() }
            Task.detached { [store] in await store.refreshStaleAlbumArt() }
            Task.detached { [store] in await store.refreshCurrentAudio() }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if let error = store.errorMessage {
                    ToastView(message: error) { store.errorMessage = nil }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                MiniPlayerView(store: store)
            }
            .padding(.bottom, store.audio.nowPlaying != nil || store.errorMessage != nil ? 0 : 16)
        }
        .animation(.easeInOut(duration: 0.25), value: store.errorMessage != nil)
        .animation(.easeInOut(duration: 0.2), value: store.audio.nowPlaying?.id)
        .sheet(isPresented: $showAddSheet) {
            AddSongSheet(store: store)
        }
        .sheet(isPresented: $store.presentingFullPlayer) {
            FullPlayerView(store: store)
        }
        .alert("Create New Version", isPresented: Binding(
            get: { newVersionProject != nil },
            set: { if !$0 { newVersionProject = nil; newVersionText = "" } }
        )) {
            TextField("Version (e.g. 1.3)", text: $newVersionText)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                if let p = newVersionProject {
                    store.duplicateLatestALS(for: p, version: newVersionText)
                }
            }
        } message: {
            if let current = newVersionProject?.latestVersionString {
                Text("Current version: \(current)")
            } else {
                Text("Pick the version number for the new .als file.")
            }
        }
    }

    private var gridView: some View {
        ScrollView {
            if store.projects.isEmpty {
                ContentUnavailableView {
                    Label("No songs yet", systemImage: "music.note.list")
                } description: {
                    Text("Click + to add a song from Dropbox.")
                }
                .padding(.top, 80)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(store.projectSections) { section in
                        Section {
                            ForEach(section.projects) { project in
                                SongCard(project: project, store: store)
                                    .contextMenu {
                                        contextMenu(for: project)
                                    }
                            }
                        } header: {
                            sectionHeader(section)
                        }
                    }
                }
                .padding(20)
                .animation(.easeInOut(duration: 0.25), value: store.projectSections.map(\.id))
            }
        }
        .background(.background)
    }

    @ViewBuilder
    private func sectionHeader(_ section: ProjectSection) -> some View {
        Text(section.title)
            .font(.title2.weight(.bold))
            .foregroundStyle(.primary)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func contextMenu(for project: ProjectReference) -> some View {
        let localURL = SongStore.localFolderURL(for: project)
        Button {
            store.showInFinder(project)
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }
        .disabled(localURL == nil)

        Button {
            store.openLatestALS(for: project)
        } label: {
            Label("Open Latest .als", systemImage: "music.note")
        }
        .disabled(localURL == nil)

        Button {
            newVersionProject = project
            newVersionText = ""
        } label: {
            Label("Create New Version…", systemImage: "plus.square.on.square")
        }
        .disabled(localURL == nil)

        Divider()

        let currentStatus = store.status[project.id] ?? .inProgress
        ForEach(SongStatus.allCases) { s in
            Button {
                store.setStatus(s, for: project)
            } label: {
                Label(s.displayName, systemImage: currentStatus == s ? "checkmark" : s.systemImage)
            }
        }

        Divider()

        Button {
            store.toggleHideTitle(project)
        } label: {
            let hidden = store.hideTitle[project.id] == true
            Label(hidden ? "Show Title" : "Hide Title",
                  systemImage: hidden ? "textformat" : "textformat.alt")
        }

        Button {
            Task { await store.refreshAlbumArt(for: project) }
        } label: {
            Label("Refresh Artwork", systemImage: "arrow.clockwise")
        }

        Divider()

        Button(role: .destructive) {
            store.removeProject(project)
        } label: {
            Label("Remove from Library", systemImage: "trash")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 4) {
                Menu {
                    ForEach(LibrarySortMode.allCases) { mode in
                        Button {
                            store.sortMode = mode
                        } label: {
                            if store.sortMode == mode {
                                Label(mode.rawValue, systemImage: "checkmark")
                            } else {
                                Text(mode.rawValue)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }

                Button {
                    Task {
                        await store.pullLibraryFromDropbox()
                        await store.refreshActivityDates()
                        await store.refreshStaleAlbumArt()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)

                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(!store.isAuthorized)
            }
        }
    }
}
