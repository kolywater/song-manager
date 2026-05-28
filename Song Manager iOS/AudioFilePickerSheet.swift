import SwiftUI

struct AudioFilePickerSheet: View {
    let project: ProjectReference
    var store: SongStore

    @Environment(\.dismiss) private var dismiss

    private var files: [AudioFileMeta] { store.audioFiles[project.id] ?? [] }
    private var masters: [AudioFileMeta] { files.filter { $0.isMaster } }
    private var bounces: [AudioFileMeta] { files.filter { !$0.isMaster } }
    private var selectedPath: String? { store.selectedAudioPath[project.id] }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    autoRow
                }
                if !masters.isEmpty {
                    Section("Masters") {
                        ForEach(masters) { row(for: $0) }
                    }
                }
                if !bounces.isEmpty {
                    Section("Bounces") {
                        ForEach(bounces) { row(for: $0) }
                    }
                }
                if files.isEmpty {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Loading audio files…")
                                .foregroundStyle(.secondary)
                                .padding(.leading, 8)
                        }
                    }
                }
            }
            .navigationTitle("Audio File")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await store.loadAudioFiles(for: project)
        }
    }

    /// Default behavior: no explicit pin. Plays the latest bounce and
    /// moves to a newer one automatically as it's added. Selecting any
    /// file below pins it (sticky until something newer lands); tapping
    /// this row clears the pin.
    private var autoRow: some View {
        let isAuto = selectedPath == nil
        return Button {
            Task { await store.clearAudioSelection(for: project) }
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Latest bounce")
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text("Follows new bounces automatically")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isAuto {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(for file: AudioFileMeta) -> some View {
        let isSelected = selectedPath == file.relativePath
        let subpath = subfolderLabel(for: file)
        return Button {
            Task { await store.selectAudioFile(file, for: project) }
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.filename)
                        .font(.body)
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        if let subpath {
                            Text(subpath)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tint)
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(file.modDate.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Returns the subfolder chain within `_MASTERS/` (or `bounces/`) so
    /// the user can disambiguate files with the same name across mixes.
    /// nil for files sitting directly in the root section folder.
    private func subfolderLabel(for file: AudioFileMeta) -> String? {
        let parent = (file.relativePath as NSString).deletingLastPathComponent
        for root in ["_MASTERS/", "bounces/"] {
            if parent.hasPrefix(root) {
                return String(parent.dropFirst(root.count))
            }
        }
        return nil
    }
}
