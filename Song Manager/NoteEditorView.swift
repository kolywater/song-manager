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

    private func findTextView() -> NSTextView? {
        func search(_ view: NSView) -> NSTextView? {
            if let tv = view as? NSTextView { return tv }
            for sub in view.subviews {
                if let found = search(sub) { return found }
            }
            return nil
        }
        guard let contentView = NSApp.keyWindow?.contentView else { return nil }
        return search(contentView)
    }

    private func insertDate() {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        let dateStr = formatter.string(from: Date())
        let snippet = "\(dateStr)\n——————————————————\n"

        guard let textView = findTextView() else {
            text.insert(contentsOf: snippet, at: text.startIndex)
            return
        }

        let range = textView.selectedRange()
        textView.insertText(snippet, replacementRange: range)
        text = textView.string
    }
}
