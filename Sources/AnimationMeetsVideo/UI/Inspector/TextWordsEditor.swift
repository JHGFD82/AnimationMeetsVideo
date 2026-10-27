import AppKit
import SwiftUI

/// A Text effect's words, typed in place, whose selection picks the letters
/// the Character settings style (see `TextSelectionRows`). An AppKit text
/// view, since SwiftUI's editor doesn't say what is selected. Each edit is
/// sent as the letters it replaced, so styled runs keep to their letters
/// (`TextContent.replaceCharacters`).
struct TextWordsEditor: NSViewRepresentable {
    let content: TextContent
    /// The letters selected, in UTF-16 code units; empty at the cursor.
    @Binding var selection: NSRange
    let onChange: (TextContent) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let textView = WordsTextView(frame: .zero)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.string = content.string
        textView.setAccessibilityLabel("Text")
        textView.setAccessibilityHelp("The words the layer draws. Select letters to style them apart in Character.")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.content = content
        guard let textView = scroll.documentView as? NSTextView, !textView.hasMarkedText() else { return }
        if textView.string != content.string {
            textView.string = content.string
        }
        let length = (content.string as NSString).length
        let clamped = NSRange(location: min(selection.location, length), length: max(0, min(selection.length, length - min(selection.location, length))))
        if textView.selectedRange() != clamped { textView.setSelectedRange(clamped) }
    }

    /// The text view, which selects a line by triple-click without its
    /// line break.
    final class WordsTextView: NSTextView {
        override func selectionRange(forProposedRange proposedCharRange: NSRange, granularity: NSSelectionGranularity) -> NSRange {
            let range = super.selectionRange(forProposedRange: proposedCharRange, granularity: granularity)
            guard granularity == .selectByParagraph else { return range }
            return TextWordsEditor.withoutLineBreak(range, in: string as NSString)
        }
    }

    /// A paragraph selected whole (triple-clicked) without the line break
    /// ending it, so typing over the line keeps it a line of its own rather
    /// than joining the next. A selection of several lines keeps the break
    /// after the last, as does one of the break alone.
    static func withoutLineBreak(_ range: NSRange, in string: NSString) -> NSRange {
        guard range.length > 1, NSMaxRange(range) <= string.length else { return range }
        let breaks = CharacterSet.newlines
        var end = NSMaxRange(range)
        // A CR LF ends a line as one break.
        if end >= 2, string.substring(with: NSRange(location: end - 2, length: 2)) == "\r\n" {
            end -= 2
        } else if let last = string.substring(with: NSRange(location: end - 1, length: 1)).unicodeScalars.first, breaks.contains(last) {
            end -= 1
        } else {
            return range
        }
        let line = NSRange(location: range.location, length: end - range.location)
        guard line.length > 0, string.rangeOfCharacter(from: breaks, options: [], range: line).location == NSNotFound else { return range }
        return line
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TextWordsEditor
        /// The words as last sent or received, which the next edit applies to.
        var content: TextContent
        /// The edit the text view is about to make.
        private var pending: (range: NSRange, replacement: String)?

        init(_ parent: TextWordsEditor) {
            self.parent = parent
            content = parent.content
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            pending = (range, replacementString ?? "")
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            var edited = content
            if let pending, (edited.string as NSString).replacingCharacters(in: pending.range, with: pending.replacement) == textView.string {
                edited.replaceCharacters(in: pending.range, with: pending.replacement)
            } else {
                // An edit it made without asking (an undo): keep the styles
                // of what is unchanged at either end.
                edited.replaceString(with: textView.string)
            }
            pending = nil
            content = edited
            parent.onChange(edited)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            if parent.selection != range { parent.selection = range }
        }
    }
}
