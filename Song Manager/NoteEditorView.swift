import AppKit
import Combine
import SwiftUI

struct NoteEditorView: View {
    let songName: String
    @Binding var text: String
    var onSave: () -> Void
    var onDismiss: () -> Void

    private let autoSaveInterval: TimeInterval = 3

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(songName)
                    .font(.headline)
                Spacer()
                Button("Add Date") { insertDate() }
                Button("Close") { onDismiss() }
            }
            .padding()

            Divider()

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
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
        let dateStr = formatter.string(from: Date())
        let snippet = "\(dateStr)\n---\n"

        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else {
            text.append(snippet)
            return
        }

        let range = textView.selectedRange()
        textView.insertText(snippet, replacementRange: range)
        text = textView.string
    }
}
