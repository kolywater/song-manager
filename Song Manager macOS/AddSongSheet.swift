import SwiftUI

/// Lists folders under `/music/aidenel songs/` from Dropbox that aren't
/// already in the library. Single-select + add. Dark theme to match
/// AddNoteSheet so all the sheets read as one family.
struct AddSongSheet: View {
    @Bindable var store: SongStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: FolderRef.ID?

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            footer
        }
        .frame(width: 540, height: 540)
        .background(Color(red: 0.118, green: 0.118, blue: 0.133))
        .preferredColorScheme(.dark)
        .task {
            await store.loadAvailableFolders()
        }
    }

    private var header: some View {
        HStack {
            Text("Add Song")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Button {
                Task { await store.loadAvailableFolders() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.isLoadingPicker)

            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .foregroundStyle(.white.opacity(0.7))
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoadingPicker && store.availableFolders.isEmpty {
            VStack {
                Spacer()
                ProgressView().tint(.white)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.availableFolders.isEmpty {
            VStack {
                Spacer()
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.white.opacity(0.35))
                Text("Nothing new to add")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 8)
                Text("Every folder under /music/aidenel songs/ is already in your library.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 48)
                    .padding(.top, 4)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(store.availableFolders) { folder in
                        folderRow(folder)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
        }
    }

    private func folderRow(_ folder: FolderRef) -> some View {
        let isSelected = selection == folder.id
        return Button {
            selection = folder.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.55))
                Text(folder.displayName)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.85))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.white.opacity(0.15) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button {
                if let id = selection,
                   let folder = store.availableFolders.first(where: { $0.id == id }) {
                    store.addProject(folder: folder)
                    dismiss()
                }
            } label: {
                Text("Add")
                    .font(.system(size: 15, weight: .heavy))
                    .frame(minWidth: 120)
                    .padding(.vertical, 11)
                    .background(selection == nil ? Color.white.opacity(0.1) : Color.white)
                    .foregroundStyle(selection == nil ? Color.white.opacity(0.3) : Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(selection == nil)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
        .padding(.top, 8)
    }
}
