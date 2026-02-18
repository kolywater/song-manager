import Combine
import SwiftUI

struct NoteLine: Identifiable, Equatable {
    let id = UUID()
    var text: String
}

struct NoteEditorView: View {
    let songName: String
    @Binding var text: String
    var onSave: () -> Void
    var onDismiss: () -> Void

    @State private var lines: [NoteLine] = []
    @FocusState private var focusedLineID: UUID?
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
                    ForEach($lines) { $line in
                        NoteLineView(
                            line: $line,
                            isFocused: focusedLineID == line.id,
                            onFocus: { focusedLineID = line.id },
                            onSubmit: { insertLineAfter(line.id) },
                            onDelete: { deleteLineIfEmpty(line.id) }
                        )
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onTapGesture {
                if lines.isEmpty || !lines.last!.text.isEmpty {
                    lines.append(NoteLine(text: ""))
                }
                focusedLineID = lines.last?.id
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { lines = text.components(separatedBy: "\n").map { NoteLine(text: $0) } }
        .onChange(of: lines) { syncText() }
        .onReceive(Timer.publish(every: autoSaveInterval, on: .main, in: .common).autoconnect()) { _ in
            onSave()
        }
        .onDisappear { onSave() }
    }

    private func syncText() {
        text = lines.map(\.text).joined(separator: "\n")
    }

    private func insertLineAfter(_ id: UUID) {
        guard let idx = lines.firstIndex(where: { $0.id == id }) else { return }
        let newLine = NoteLine(text: "")
        lines.insert(newLine, at: idx + 1)
        focusedLineID = newLine.id
    }

    private func deleteLineIfEmpty(_ id: UUID) {
        guard let idx = lines.firstIndex(where: { $0.id == id }),
              lines[idx].text.isEmpty, lines.count > 1 else { return }
        lines.remove(at: idx)
        let prevIdx = max(idx - 1, 0)
        focusedLineID = lines[prevIdx].id
    }

    private func insertDate() {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        let dateLines = [
            NoteLine(text: formatter.string(from: Date())),
            NoteLine(text: "——————————————————")
        ]
        lines.insert(contentsOf: dateLines, at: 0)
    }

    private func insertTask() {
        let newLine = NoteLine(text: "- [ ] ")
        lines.insert(newLine, at: 0)
        focusedLineID = newLine.id
    }
}

struct NoteLineView: View {
    @Binding var line: NoteLine
    let isFocused: Bool
    var onFocus: () -> Void
    var onSubmit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        if let match = parseCheckbox(line.text) {
            HStack(alignment: .center, spacing: 6) {
                Toggle("", isOn: Binding(
                    get: { match.checked },
                    set: { newVal in
                        line.text = "- [\(newVal ? "x" : " ")] \(match.content)"
                    }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()

                TextField("", text: Binding(
                    get: { match.content },
                    set: { newVal in
                        let check = parseCheckbox(line.text)?.checked ?? false
                        line.text = "- [\(check ? "x" : " ")] \(newVal)"
                    }
                ))
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .strikethrough(match.checked)
                .foregroundStyle(match.checked ? .secondary : .primary)
                .onTapGesture { onFocus() }
                .onSubmit { onSubmit() }
                .onChange(of: line.text) {
                    if line.text.isEmpty { onDelete() }
                }
            }
        } else {
            TextField("", text: $line.text)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .onTapGesture { onFocus() }
                .onSubmit { onSubmit() }
                .onChange(of: line.text) {
                    if line.text.isEmpty { onDelete() }
                }
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
