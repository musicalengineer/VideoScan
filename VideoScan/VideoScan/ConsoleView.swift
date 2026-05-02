import SwiftUI
import AppKit

/// High-performance console using NSTextView instead of SwiftUI ForEach.
/// NSTextView handles large text natively without per-line diffing overhead.
struct ConsoleView: NSViewRepresentable {
    let lines: [String]

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textColor = NSColor.textColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        // Keep reference for updates
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coord = context.coordinator
        let newCount = lines.count

        // Skip if nothing changed
        guard newCount != coord.lastLineCount else { return }

        guard let textView = coord.textView, let storage = textView.textStorage else { return }

        if newCount < coord.lastLineCount || coord.lastLineCount == 0 {
            // Reset — lines were cleared or first load
            let text = lines.joined(separator: "\n")
            storage.setAttributedString(NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor.textColor
                ]
            ))
        } else {
            // Append only new lines
            let newLines = lines[coord.lastLineCount...]
            let appendText = "\n" + newLines.joined(separator: "\n")
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.textColor
            ]
            storage.append(NSAttributedString(string: appendText, attributes: attrs))
        }

        coord.lastLineCount = newCount

        // Auto-scroll to bottom
        textView.scrollToEndOfDocument(nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var textView: NSTextView?
        var scrollView: NSScrollView?
        var lastLineCount = 0
    }
}
