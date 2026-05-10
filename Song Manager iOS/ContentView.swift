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
                            } preview: {
                                SongCard(project: project, store: store)
                                    .frame(width: 240, height: 240)
                            }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
            }
            .background(Color(.systemBackground))
            .overlay {
                if store.projects.isEmpty {
                    ContentUnavailableView {
                        Label("No songs yet", systemImage: "music.note.list")
                    } description: {
                        Text("Tap + to add a song from Dropbox.")
                    }
                }
            }
            .navigationTitle("Adenel")
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
    }
}

#Preview {
    ContentView()
}
