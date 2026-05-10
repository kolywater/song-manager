import SwiftUI

struct AddSongSheet: View {
    @Bindable var store: SongStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if store.isLoadingPicker {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading folders…")
                            .foregroundStyle(.secondary)
                    }
                } else if let error = store.errorMessage {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } else if store.availableFolders.isEmpty {
                    Section {
                        Text("No folders available to add.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Folders in /music/aidenel songs/") {
                        ForEach(store.availableFolders) { folder in
                            Button {
                                store.addProject(folder: folder)
                                dismiss()
                            } label: {
                                HStack {
                                    Image(systemName: "folder")
                                        .foregroundStyle(.secondary)
                                    Text(folder.displayName)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                await store.loadAvailableFolders()
            }
        }
    }
}
