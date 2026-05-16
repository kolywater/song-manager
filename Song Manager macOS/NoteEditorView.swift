import Combine
import SwiftUI
import AppKit

struct NoteEditorView: View {
    let songName: String
    @Binding var text: String
    var onSave: () -> Void
    var onDismiss: () -> Void
    var baseText: String = ""
    var rootURL: URL?
    var notesURL: URL?
    var reloadNotes: (() -> String)?

    private let autoSaveInterval: TimeInterval = 3

    @State private var baseSnapshot = ""
    @State private var watcher = FileWatcher()

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
        .onAppear {
            baseSnapshot = baseText
            if let rootURL, let notesURL {
                watcher.start(rootURL: rootURL, notesPath: notesURL.path(percentEncoded: false)) {
                    handleExternalChange()
                }
            }
        }
        .onDisappear {
            watcher.stop()
            onSave()
        }
        .onReceive(Timer.publish(every: autoSaveInterval, on: .main, in: .common).autoconnect()) { _ in
            onSave()
        }
    }

    private func handleExternalChange() {
        guard let reloadNotes else { return }
        let fresh = reloadNotes()
        guard fresh != text else { return }
        if text == baseSnapshot {
            text = fresh
        } else {
            text = TextMerge.merge(base: baseSnapshot, local: text, remote: fresh)
        }
        baseSnapshot = fresh
    }

    private func insertDate() {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        let snippet = "\(formatter.string(from: Date()))\n——————————————————\n"
        text.insert(contentsOf: snippet, at: text.startIndex)
    }
}

final class FileWatcher {
    private var source: (any DispatchSourceFileSystemObject)?

    func start(rootURL: URL, notesPath: String, onChange: @escaping () -> Void) {
        stop()
        guard rootURL.startAccessingSecurityScopedResource() else { return }
        let fd = open(notesPath, O_EVTONLY)
        guard fd >= 0 else {
            rootURL.stopAccessingSecurityScopedResource()
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        src.setEventHandler { onChange() }
        src.setCancelHandler {
            close(fd)
            rootURL.stopAccessingSecurityScopedResource()
        }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit { stop() }
}

struct CheckboxTextEditor: NSViewRepresentable {
    @Binding var text: String

    static let regularFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    static let boldFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .bold)

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = CheckboxNSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.textContainer?.widthTracksTextView = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false

        textView.textStorage?.setAttributedString(markdownToAttributedString(text))
        context.coordinator.lastSyncedMarkdown = text

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CheckboxNSTextView else { return }
        if text != context.coordinator.lastSyncedMarkdown {
            let selectedRanges = textView.selectedRanges
            textView.textStorage?.setAttributedString(markdownToAttributedString(text))
            textView.selectedRanges = selectedRanges
            context.coordinator.lastSyncedMarkdown = text
        }
    }

    func markdownToAttributedString(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let pattern = try! NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*")
        let nsString = markdown as NSString
        var lastEnd = 0

        for match in pattern.matches(in: markdown, range: NSRange(location: 0, length: nsString.length)) {
            if match.range.location > lastEnd {
                let before = nsString.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
                result.append(NSAttributedString(string: before, attributes: [.font: Self.regularFont, .foregroundColor: NSColor.textColor]))
            }
            let inner = nsString.substring(with: match.range(at: 1))
            result.append(NSAttributedString(string: inner, attributes: [.font: Self.boldFont, .foregroundColor: NSColor.textColor]))
            lastEnd = match.range.location + match.range.length
        }

        if lastEnd < nsString.length {
            let remaining = nsString.substring(with: NSRange(location: lastEnd, length: nsString.length - lastEnd))
            result.append(NSAttributedString(string: remaining, attributes: [.font: Self.regularFont, .foregroundColor: NSColor.textColor]))
        }

        return result
    }

    static func attributedStringToMarkdown(_ attrString: NSAttributedString) -> String {
        var result = ""
        attrString.enumerateAttribute(.font, in: NSRange(location: 0, length: attrString.length)) { value, range, _ in
            let text = (attrString.string as NSString).substring(with: range)
            if let font = value as? NSFont, font.fontDescriptor.symbolicTraits.contains(.bold) {
                result += "**\(text)**"
            } else {
                result += text
            }
        }
        return result
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CheckboxTextEditor
        weak var textView: NSTextView?
        var lastSyncedMarkdown: String = ""

        init(_ parent: CheckboxTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  let textStorage = textView.textStorage else { return }
            let markdown = CheckboxTextEditor.attributedStringToMarkdown(textStorage)
            lastSyncedMarkdown = markdown
            parent.text = markdown
        }
    }
}

class CheckboxNSTextView: NSTextView {
    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "b" {
            toggleBold()
            return
        }
        super.keyDown(with: event)
    }

    private func toggleBold() {
        let range = selectedRange()
        guard range.length > 0 else { return }

        var allBold = true
        textStorage?.enumerateAttribute(.font, in: range) { value, _, stop in
            if let font = value as? NSFont, !font.fontDescriptor.symbolicTraits.contains(.bold) {
                allBold = false
                stop.pointee = true
            }
        }

        let newFont = allBold ? CheckboxTextEditor.regularFont : CheckboxTextEditor.boldFont
        textStorage?.addAttribute(.font, value: newFont, range: range)
        delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: self))
    }

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
