import SwiftUI

struct AddNoteSheet: View {
    let project: ProjectReference
    var store: SongStore
    let currentTime: Double
    /// When non-nil, the sheet edits this note in place (text + UI tags)
    /// instead of creating a new one. Voice-only tags (anything not in
    /// `NoteTags.allTags`) aren't editable in the picker but are
    /// preserved on save via `hiddenTags`.
    let editing: Note?

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var tags: Set<String>
    @State private var hiddenTags: [String]
    @FocusState private var textFocused: Bool

    private let categories: [NoteTagCategory] = NoteTags.categories

    init(project: ProjectReference, store: SongStore, currentTime: Double, editing: Note? = nil) {
        self.project = project
        self.store = store
        self.currentTime = currentTime
        self.editing = editing
        let uiTags = Set(NoteTags.allTags)
        if let note = editing {
            _text = State(initialValue: note.text)
            _tags = State(initialValue: Set(note.tags).intersection(uiTags))
            _hiddenTags = State(initialValue: note.tags.filter { !uiTags.contains($0) })
        } else {
            _text = State(initialValue: "")
            _tags = State(initialValue: [])
            _hiddenTags = State(initialValue: [])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 16)

            TextEditor(text: $text)
                .focused($textFocused)
                .scrollContentBackground(.hidden)
                .padding(11)
                .frame(minHeight: 90)
                .background(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("What are you hearing?")
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.35))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 19)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(categories, id: \.name) { category in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(category.name.uppercased())
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.white.opacity(0.4))
                            .tracking(0.6)
                            .padding(.horizontal, 16)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(category.tags, id: \.self) { tag in
                                    tagChip(tag)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
            }
            .padding(.top, 16)

            Spacer(minLength: 12)

            Button {
                save()
            } label: {
                Text(editing == nil ? "Save Note" : "Save")
                    .font(.system(size: 15, weight: .heavy))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color.white.opacity(0.1)
                                : Color.white)
                    .foregroundStyle(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                     ? Color.white.opacity(0.3)
                                     : Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(red: 0.118, green: 0.118, blue: 0.133).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                textFocused = true
            }
        }
    }

    private func tagChip(_ tag: String) -> some View {
        let isSelected = tags.contains(tag)
        let color = NoteTags.color(for: tag)
        return Button {
            if isSelected { tags.remove(tag) } else { tags.insert(tag) }
        } label: {
            Text(tag)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .foregroundStyle(isSelected ? Color.white : color.opacity(0.85))
                .background(isSelected ? color : Color.clear)
                .overlay(
                    Capsule().stroke(
                        isSelected ? color : color.opacity(0.55),
                        lineWidth: 1
                    )
                )
                .clipShape(Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let mergedTags = (Array(tags) + hiddenTags).sorted()
        let project = project
        if let editing {
            let updated = Note(
                id: editing.id,
                time: editing.time,
                text: trimmed,
                tags: mergedTags,
                version: editing.version,
                createdAt: editing.createdAt
            )
            Task { await store.updateNote(updated, in: project) }
        } else {
            let note = Note(time: currentTime, text: trimmed, tags: mergedTags)
            Task { await store.addNote(note, to: project) }
        }
        dismiss()
    }
}
