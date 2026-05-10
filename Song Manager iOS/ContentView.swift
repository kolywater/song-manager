import SwiftUI

struct ContentView: View {
    @State private var store = SongStore()
    @State private var showAddSheet = false

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(store.projects) { project in
                        SongCard(project: project)
                            .contextMenu {
                                Button(role: .destructive) {
                                    store.removeProject(project)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
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
                ToolbarItem(placement: .topBarTrailing) {
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
        }
    }
}

#Preview {
    ContentView()
}
