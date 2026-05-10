import SwiftUI

struct AddNoteSheet: View {
    let project: ProjectReference
    var store: SongStore
    let currentTime: Double

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var tags: Set<String> = []
    @FocusState private var textFocused: Bool

    private let allTags = ["arrangement", "chorus", "compression", "eq", "lyrics", "pc", "performance", "verse"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Note at \(timecode(currentTime))")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)

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

            FlowLayout(spacing: 8) {
                ForEach(allTags, id: \.self) { tag in
                    let isSelected = tags.contains(tag)
                    Button {
                        if isSelected { tags.remove(tag) } else { tags.insert(tag) }
                    } label: {
                        Text(tag)
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.55))
                            .background(isSelected ? Color.white.opacity(0.16) : Color.clear)
                            .overlay(
                                Capsule().stroke(
                                    isSelected ? Color.white.opacity(0.5) : Color.white.opacity(0.18),
                                    lineWidth: 1
                                )
                            )
                            .clipShape(Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            Spacer(minLength: 12)

            Button {
                save()
            } label: {
                Text("Save Note")
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

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let note = Note(time: currentTime, text: trimmed, tags: Array(tags).sorted())
        let project = project
        Task {
            await store.addNote(note, to: project)
        }
        dismiss()
    }

    private func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}
