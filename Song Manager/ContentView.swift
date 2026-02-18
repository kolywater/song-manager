import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var store = ProjectStore()
    @State private var player = AudioPlayer()
    @State private var showingNewVersion = false
    @State private var newVersionText = ""
    @State private var projectForNewVersion: ProjectReference?
    @State private var draggingProject: ProjectReference?
    @State private var showingNotes = false
    @State private var notesText = ""
    @State private var projectForNotes: ProjectReference?

    private let columns = [
        GridItem(.adaptive(minimum: 310, maximum: 310), spacing: 16)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(store.sortedProjects) { project in
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
                        onNotes: {
                            projectForNotes = project
                            notesText = store.loadNotes(for: project)
                            showingNotes = true
                        },
                        onShowInFinder: { store.showInFinder(for: project) },
                        onOpenProject: { store.openProject(for: project) },
                        onRemove: { store.removeProject(project) },
                        onChangeColor: { store.changeColor(for: project) },
                        onDropAlbumArt: { providers in
                            guard let provider = providers.first else { return }
                            provider.loadFileRepresentation(forTypeIdentifier: "public.image") { url, _ in
                                guard let url else { return }
                                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                                try? FileManager.default.removeItem(at: tmp)
                                try? FileManager.default.copyItem(at: url, to: tmp)
                                DispatchQueue.main.async {
                                    store.setAlbumArt(for: project, imageURL: tmp)
                                    try? FileManager.default.removeItem(at: tmp)
                                }
                            }
                        }
                    )
                    .opacity(draggingProject == project ? 0 : 1)
                    .animation(nil, value: draggingProject)
                    .onDrag {
                        draggingProject = project
                        return NSItemProvider(object: project.id.uuidString as NSString)
                    }
                    .onDrop(of: [.text], delegate: ProjectReorderDelegate(
                        item: project,
                        items: store.projects,
                        dragging: $draggingProject,
                        store: store
                    ))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, player.currentURL != nil ? 70 : 20)
        }
        .onDrop(of: [.text], delegate: DropOutsideDelegate(dragging: $draggingProject, store: store))
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
                    Menu {
                        ForEach(SortMode.allCases, id: \.self) { mode in
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
        .onChange(of: store.sortMode) {
            UserDefaults.standard.set(store.sortMode.rawValue, forKey: "sortMode")
        }
        .animation(.easeInOut(duration: 0.3), value: store.sortedProjects.map(\.id))
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
        .overlay {
            if showingNotes, let project = projectForNotes {
                NoteEditorView(
                    songName: project.displayName,
                    text: $notesText,
                    onSave: { store.saveNotes(for: project, text: notesText) },
                    onDismiss: {
                        store.saveNotes(for: project, text: notesText)
                        showingNotes = false
                    }
                )
                .background(.regularMaterial)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showingNotes)
    }
}

struct ProjectReorderDelegate: DropDelegate {
    let item: ProjectReference
    let items: [ProjectReference]
    @Binding var dragging: ProjectReference?
    let store: ProjectStore

    func dropEntered(info: DropInfo) {
        guard store.sortMode == .custom,
              let current = dragging, item != current,
              let from = items.firstIndex(of: current),
              let to = items.firstIndex(of: item) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            store.moveProject(from: IndexSet(integer: from), to: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: store.sortMode == .custom ? .move : .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        store.save()
        return true
    }
}

struct DropOutsideDelegate: DropDelegate {
    @Binding var dragging: ProjectReference?
    let store: ProjectStore

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        store.save()
        return true
    }
}

#Preview {
    ContentView()
}
