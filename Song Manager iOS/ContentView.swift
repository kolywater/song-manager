import SwiftUI

enum LibrarySortMode: String, CaseIterable, Identifiable {
    case recent = "Recent"
    case alphabetical = "A–Z"
    var id: Self { self }
}

struct ContentView: View {
    @State private var store = SongStore()
    @State private var showAddSheet = false
    @State private var sortMode: LibrarySortMode = .recent

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var sortedProjects: [ProjectReference] {
        let base: [ProjectReference]
        switch sortMode {
        case .recent:
            base = store.projects.sorted {
                let a = store.activityDates[$0.id] ?? .distantPast
                let b = store.activityDates[$1.id] ?? .distantPast
                return a > b
            }
        case .alphabetical:
            base = store.projects.sorted {
                $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
            }
        }
        // Stable partition: starred first, each side preserves the active sort.
        let starred = base.filter { store.starred[$0.id] == true }
        let rest = base.filter { store.starred[$0.id] != true }
        return starred + rest
    }

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(sortedProjects) { project in
                        SongCard(project: project, store: store)
                            .contextMenu {
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
                        Picker("Sort", selection: $sortMode) {
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
        .task {
            if DevHarness.autoOpenPlayer, let first = store.projects.first {
                await store.play(first)
            }
        }
    }
}

#Preview {
    ContentView()
}
