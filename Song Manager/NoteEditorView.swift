import Combine
import SwiftUI
import AppKit

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
                Button("Add Task") {
                    text.insert(contentsOf: "[ ] \n", at: text.startIndex)
                }
                Button("Add Date") { insertDate() }
                Button("Close") { onDismiss() }
            }
            .padding()

            Divider()

            CheckboxTextEditor(text: $text)
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
        let snippet = "\(formatter.string(from: Date()))\n——————————————————\n"
        text.insert(contentsOf: snippet, at: text.startIndex)
    }
}

struct CheckboxTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = CheckboxNSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.textContainer?.widthTracksTextView = true
        textView.drawsBackground = false
        textView.string = text

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CheckboxTextEditor
        weak var textView: NSTextView?

        init(_ parent: CheckboxTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

class CheckboxNSTextView: NSTextView {
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let charIndex = characterIndexForInsertion(at: point)

        if toggleCheckbox(at: charIndex) {
            return
        }
        super.mouseDown(with: event)
    }

    private func toggleCheckbox(at charIndex: Int) -> Bool {
        let text = string as NSString
        let lineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))
        let line = text.substring(with: lineRange)
        let offsetInLine = charIndex - lineRange.location

        guard offsetInLine < 3 else { return false }

        if line.hasPrefix("[ ] ") {
            let checkboxRange = NSRange(location: lineRange.location, length: 3)
            replaceCharacters(in: checkboxRange, with: "[x]")
            delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: self))
            return true
        } else if line.hasPrefix("[x] ") {
            let checkboxRange = NSRange(location: lineRange.location, length: 3)
            replaceCharacters(in: checkboxRange, with: "[ ]")
            delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: self))
            return true
        }
        return false
    }
}
