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
    @State private var bgProjectID: UUID?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var sortedProjects: [ProjectReference] {
        switch sortMode {
        case .recent:
            return store.projects.sorted {
                let a = store.activityDates[$0.id] ?? .distantPast
                let b = store.activityDates[$1.id] ?? .distantPast
                return a > b
            }
        case .alphabetical:
            return store.projects.sorted {
                $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
            }
        }
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
                blurredBackground
                    .ignoresSafeArea()
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
        }
        .fullScreenCover(isPresented: $store.presentingFullPlayer) {
            FullPlayerView(store: store)
        }
        .task {
            if DevHarness.autoOpenPlayer, let first = store.projects.first {
                await store.play(first)
            }
        }
        .task(id: store.projects.map(\.id)) {
            guard bgProjectID == nil else { return }
            let allowed = ["moonlit", "burning bridges", "the only", "veil", "falling into the sun"]
            let pool = store.projects.filter { project in
                let name = project.displayName.lowercased()
                return allowed.contains { name.contains($0) }
            }
            // Prefer art already loaded by visible cards.
            let loaded = pool.filter { store.albumArt[$0.id] != nil }
            if let chosen = loaded.randomElement() {
                bgProjectID = chosen.id
                return
            }
            // Otherwise try the allow-listed pool in random order.
            for project in pool.shuffled() {
                await store.loadAlbumArt(for: project)
                if store.albumArt[project.id] != nil {
                    bgProjectID = project.id
                    return
                }
            }
        }
    }

    @ViewBuilder
    private var blurredBackground: some View {
        if let id = bgProjectID, let art = store.albumArt[id] {
            GeometryReader { geo in
                Image(uiImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(1.4)
                    .blur(radius: 60)
                    .clipped()
            }
        } else {
            Color(.systemBackground)
        }
    }
}

#Preview {
    ContentView()
}
