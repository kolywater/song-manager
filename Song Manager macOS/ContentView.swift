import SwiftUI

struct ContentView: View {
    @State private var store = SongStore()
    @State private var updater = Updater()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showAddSheet = false
    @State private var newVersionProject: ProjectReference?
    @State private var newVersionText = ""
    /// Recent `.als` stems in the selected song's folder, listed for
    /// reference inside the new-version dialog.
    @State private var newVersionRecentFiles: [String] = []

    /// Three flexible columns — column count is fixed, each cell sizes
    /// to fill its third of the available width (minus padding and
    /// inter-column spacing). `SongCard`'s 1:1 aspectRatio makes the
    /// rows match the column width, so tiles grow and shrink together
    /// as the window resizes; the leading/trailing 20pt padding stays
    /// fixed.
    private let columns = [
        GridItem(.flexible(minimum: 220), spacing: 16),
        GridItem(.flexible(minimum: 220), spacing: 16),
        GridItem(.flexible(minimum: 220), spacing: 16),
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
        // 3 cols * 220 min cell + 2 * 16 inter-col spacing + 2 * 20 grid
        // padding = 732. Below this the tiles would have to shrink past
        // their 220pt floor, so we just stop the window resizing here.
        .frame(minWidth: 732, minHeight: 360)
        .navigationTitle("Songs")
        .toolbar { toolbarContent }
        .onReceive(NotificationCenter.default.publisher(for: .dropboxAuthDidChange)) { _ in
            store.rebuildSourceFromKeychain()
        }
        .task {
            // Quiet background check on launch — only surfaces if an
            // update is actually available.
            await updater.check(userInitiated: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .checkForUpdatesRequested)) { _ in
            Task { await updater.check(userInitiated: true) }
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
            set: { if !$0 { newVersionProject = nil; newVersionText = ""; newVersionRecentFiles = [] } }
        )) {
            TextField("Version (e.g. 1.3)", text: $newVersionText)
            Button("Create") {
                if let p = newVersionProject {
                    store.duplicateLatestALS(for: p, version: newVersionText, openAfter: false)
                }
            }
            Button("Create & Open") {
                if let p = newVersionProject {
                    store.duplicateLatestALS(for: p, version: newVersionText, openAfter: true)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if newVersionRecentFiles.isEmpty {
                Text("Pick the version number for the new .als file.")
            } else {
                Text("Recent files:\n" + newVersionRecentFiles.map { "•  \($0)" }.joined(separator: "\n"))
            }
        }
        .alert("Update Available", isPresented: Binding(
            get: { updater.available != nil && !updater.isBusy },
            set: { if !$0 { updater.clearResult() } }
        )) {
            Button("Install & Relaunch") {
                Task { await updater.install() }
            }
            Button("Later", role: .cancel) {}
        } message: {
            if let info = updater.available {
                let notes = info.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                Text("Version \(info.version) is available (you have \(Updater.currentVersion))."
                    + (notes.isEmpty ? "" : "\n\n\(notes)"))
            }
        }
        .alert("Software Update", isPresented: Binding(
            get: { updateInfoMessage != nil },
            set: { if !$0 { updater.clearResult() } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let message = updateInfoMessage { Text(message) }
        }
        .overlay {
            if updater.isBusy {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.large)
                        Text(updater.status == .installing ? "Installing update…" : "Downloading update…")
                            .font(.headline)
                        Text("The app will relaunch automatically.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: updater.isBusy)
    }

    /// Message for the result alert shown after a user-initiated check —
    /// either "up to date" or the failure reason. Nil otherwise.
    private var updateInfoMessage: String? {
        switch updater.status {
        case .upToDate:
            return "You're running the latest version (\(Updater.currentVersion))."
        case .failed(let reason):
            return "Couldn't check for updates.\n\n\(reason)"
        default:
            return nil
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
                                SongCard(
                                    project: project,
                                    store: store,
                                    onCreateNewVersion: {
                                        presentNewVersion(for: project)
                                    }
                                )
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

    /// Open the "Create New Version" alert for `project`, pre-filling the
    /// field with the suggested next version (bumped from the most recently
    /// modified `.als`) and listing recent `.als` files for reference. The
    /// alert itself offers both "Create" and "Create & Open".
    private func presentNewVersion(for project: ProjectReference) {
        newVersionProject = project
        newVersionText = store.suggestedNextVersion(for: project)
        newVersionRecentFiles = store.recentALSStems(for: project)
    }

    @ViewBuilder
    private func contextMenu(for project: ProjectReference) -> some View {
        let localURL = SongStore.localFolderURL(for: project)
        let latestLabel = store.latestALSLabel(for: project)
        let previousVersions = store.previousALSVersions(for: project)

        Button {
            store.openLatestALS(for: project)
        } label: {
            Label(latestLabel.map { "Open Latest (\($0))" } ?? "Open Latest",
                  systemImage: "music.note")
        }
        .disabled(localURL == nil)

        Divider()

        Button {
            presentNewVersion(for: project)
        } label: {
            Label("New Version", systemImage: "plus.square.on.square")
        }
        .disabled(localURL == nil)

        Divider()

        Button {
            store.showInFinder(project)
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }
        .disabled(localURL == nil)

        ForEach(previousVersions, id: \.url) { version in
            Button {
                store.openALS(at: version.url)
            } label: {
                Label("Open Previous (\(version.label))", systemImage: "clock.arrow.circlepath")
            }
        }

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
        }

        ToolbarItem(placement: .primaryAction) {
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
        }

        // Break the trailing toolbar group into two Liquid Glass pills —
        // sort + refresh in one, the primary "add" affordance in its own.
        // macOS 15 doesn't have toolbar pills, so the spacer is a no-op
        // there; items just sit next to each other.
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                showAddSheet = true
            } label: {
                Image(systemName: "plus")
            }
            .disabled(!store.isAuthorized)
        }
    }
}
