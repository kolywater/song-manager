import SwiftUI

/// Bounces + masters list for a project. Selecting one pins it via
/// `store.selectAudioFile`, which uploads the pin into the NotesDocument
/// (cross-device sync) and reloads playback. Dark theme matches the
/// other sheets.
struct AudioFilePickerSheet: View {
    @Bindable var store: SongStore
    let project: ProjectReference
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(width: 560, height: 560)
        .background(Color(red: 0.118, green: 0.118, blue: 0.133))
        .preferredColorScheme(.dark)
        .task(id: project.id) {
            if store.audioFiles[project.id] == nil {
                await store.loadAudioFiles(for: project)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Audio Files")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Button {
                Task { await store.loadAudioFiles(for: project) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .foregroundStyle(.white)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var content: some View {
        let all = store.audioFiles[project.id] ?? []
        let bounces = all.filter { !$0.isMaster }
        let masters = all.filter { $0.isMaster }
        let selected = store.selectedAudioPath[project.id]

        if all.isEmpty {
            VStack {
                Spacer()
                ProgressView().tint(.white)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    autoRow(selected: selected)

                    if !bounces.isEmpty {
                        section(title: "Bounces", files: bounces, selected: selected)
                    }
                    if !masters.isEmpty {
                        section(title: "Masters", files: masters, selected: selected)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
        }
    }

    private func autoRow(selected: String?) -> some View {
        Button {
            Task {
                await store.clearAudioSelection(for: project)
                dismiss()
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected == nil ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(selected == nil ? Color.accentColor : Color.white.opacity(0.4))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Latest bounce (auto)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Auto-tracks newer bounces as they appear.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected == nil ? Color.white.opacity(0.08) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func section(title: String, files: [AudioFileMeta], selected: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.white.opacity(0.4))
                .tracking(0.6)
                .padding(.horizontal, 12)
            VStack(spacing: 2) {
                ForEach(files) { file in
                    row(file: file, isSelected: selected == file.relativePath)
                }
            }
        }
    }

    private func row(file: AudioFileMeta, isSelected: Bool) -> some View {
        Button {
            Task {
                await store.selectAudioFile(file, for: project)
                dismiss()
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.white.opacity(0.4))
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.filename)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(file.relativePath)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
                Spacer()
                Text(file.modDate.formatted(.dateTime.month().day().year(.twoDigits)))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.white.opacity(0.08) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
