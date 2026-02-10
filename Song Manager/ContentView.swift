import SwiftUI

struct ContentView: View {
    @State private var store = ProjectStore()
    @State private var player = AudioPlayer()
    @State private var showingNewVersion = false
    @State private var newVersionText = ""
    @State private var projectForNewVersion: ProjectReference?

    private let columns = [
        GridItem(.adaptive(minimum: 310, maximum: 310), spacing: 16)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(store.projects) { project in
                    ProjectCardView(
                        project: project,
                        albumArt: store.albumArtCache[project.id],
                        masterFilenames: project.masterFilenames,
                        onListen: {
                            if project.hasMastersFolder && project.masterFilenames.isEmpty {
                                store.errorMessage = "No master files found"
                            } else if !project.masterFilenames.isEmpty,
                               let result = store.selectedMasterURL(for: project) {
                                player.play(url: result.masterURL, rootURL: result.rootURL)
                            } else if let result = store.latestBounceURL(for: project) {
                                player.play(url: result.bounceURL, rootURL: result.rootURL)
                            }
                        },
                        onSelectMaster: { filename in
                            store.setSelectedMaster(for: project, filename: filename)
                            if let result = store.selectedMasterURL(for: project) {
                                player.play(url: result.masterURL, rootURL: result.rootURL)
                            }
                        },
                        onNewVersion: {
                            projectForNewVersion = project
                            newVersionText = store.suggestedVersion(for: project)
                            showingNewVersion = true
                        },
                        onShowInFinder: { store.showInFinder(for: project) },
                        onOpenProject: { store.openProject(for: project) },
                        onRemove: { store.removeProject(project) }
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, player.currentURL != nil ? 70 : 20)
        }
        .overlay(alignment: .bottom) {
            if player.currentURL != nil {
                PlayerBarView(player: player)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .overlay(alignment: .bottom) {
            if let error = store.errorMessage {
                ToastView(message: error) {
                    store.errorMessage = nil
                }
                .fixedSize()
                .padding(.bottom, player.currentURL != nil ? 64 : 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.errorMessage != nil)
        .onChange(of: player.errorMessage) { _, error in
            if let error {
                store.errorMessage = error
                player.errorMessage = nil
            }
        }
        .frame(minWidth: 350)
        .navigationTitle("Songs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 4) {
                    Button(action: { store.refresh() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .focusEffectDisabled()
                    Button(action: { store.addProject() }) {
                        Image(systemName: "plus")
                    }
                    .focusEffectDisabled()
                }
            }
        }
        .alert("New Version", isPresented: $showingNewVersion) {
            TextField("Version", text: $newVersionText)
            Button("Cancel", role: .cancel) {}
            Button("OK") {
                if let project = projectForNewVersion {
                    store.duplicateLatestALS(for: project, version: newVersionText)
                }
            }
        } message: {
            if let project = projectForNewVersion, let current = project.latestVersionString {
                Text("Current version: \(current)")
            }
        }
    }
}

#Preview {
    ContentView()
}
