import Combine
import SwiftUI

struct NoteEditorView: View {
    let songName: String
    @Binding var text: String
    var onSave: () -> Void
    var onDismiss: () -> Void

    @State private var isEditing = false
    private let autoSaveInterval: TimeInterval = 3

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(songName)
                    .font(.headline)
                Spacer()
                Button("Add Task") { text.insert(contentsOf: "- [ ] \n", at: text.startIndex) }
                Button("Add Date") { insertDate() }
                Button(isEditing ? "Done" : "Edit") { isEditing.toggle() }
                Button("Close") { onDismiss() }
            }
            .padding()

            Divider()

            if isEditing {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
            } else {
                ChecklistView(text: $text)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(Timer.publish(every: autoSaveInterval, on: .main, in: .common).autoconnect()) { _ in
            onSave()
        }
        .onDisappear { onSave() }
    }

    private func insertDate() {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        let snippet = "\(formatter.string(from: Date()))\n——————————————————\n"
        text.insert(contentsOf: snippet, at: text.startIndex)
    }
}

struct ChecklistView: View {
    @Binding var text: String

    private var lines: [String] {
        text.components(separatedBy: "\n")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    if let match = parseCheckbox(line) {
                        HStack(alignment: .top, spacing: 6) {
                            Toggle("", isOn: Binding(
                                get: { match.checked },
                                set: { newVal in toggleCheckbox(at: index, checked: newVal) }
                            ))
                            .toggleStyle(.checkbox)
                            .labelsHidden()

                            Text(match.content)
                                .font(.system(.body, design: .monospaced))
                                .strikethrough(match.checked)
                                .foregroundStyle(match.checked ? .secondary : .primary)
                        }
                    } else if !line.isEmpty {
                        Text(line)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        Text(" ")
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func toggleCheckbox(at index: Int, checked: Bool) {
        var allLines = text.components(separatedBy: "\n")
        guard index < allLines.count, let match = parseCheckbox(allLines[index]) else { return }
        allLines[index] = "- [\(checked ? "x" : " ")] \(match.content)"
        text = allLines.joined(separator: "\n")
    }

    private func parseCheckbox(_ text: String) -> (checked: Bool, content: String)? {
        if text.hasPrefix("- [x] ") {
            return (true, String(text.dropFirst(6)))
        } else if text.hasPrefix("- [ ] ") {
            return (false, String(text.dropFirst(6)))
        }
        return nil
    }
}
