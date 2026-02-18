import Combine
import SwiftUI

struct NoteEditorView: View {
    let songName: String
    @Binding var text: String
    var onSave: () -> Void
    var onDismiss: () -> Void

    @State private var lines: [String] = []
    private let autoSaveInterval: TimeInterval = 3

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(songName)
                    .font(.headline)
                Spacer()
                Button("Add Task") { insertTask() }
                Button("Add Date") { insertDate() }
                Button("Close") { onDismiss() }
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(lines.indices, id: \.self) { i in
                        NoteLineView(line: $lines[i])
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { lines = text.components(separatedBy: "\n") }
        .onChange(of: lines) { syncText() }
        .onReceive(Timer.publish(every: autoSaveInterval, on: .main, in: .common).autoconnect()) { _ in
            onSave()
        }
        .onDisappear { onSave() }
    }

    private func syncText() {
        text = lines.joined(separator: "\n")
    }

    private func insertDate() {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        let snippet = "\(formatter.string(from: Date()))\n——————————————————"
        lines.insert(contentsOf: snippet.components(separatedBy: "\n"), at: 0)
    }

    private func insertTask() {
        lines.insert("- [ ] ", at: 0)
    }
}

struct NoteLineView: View {
    @Binding var line: String

    var body: some View {
        if let match = parseCheckbox(line) {
            HStack(alignment: .top, spacing: 6) {
                Toggle("", isOn: Binding(
                    get: { match.checked },
                    set: { newVal in
                        line = "- [\(newVal ? "x" : " ")] \(match.content)"
                    }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()

                TextField("", text: Binding(
                    get: { match.content },
                    set: { newVal in
                        line = "- [\(match.checked ? "x" : " ")] \(newVal)"
                    }
                ))
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .strikethrough(match.checked)
                .foregroundStyle(match.checked ? .secondary : .primary)
            }
        } else {
            TextField("", text: $line)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
        }
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
