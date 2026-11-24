import AppKit
import SwiftUI

/// An `NSTextField` (SwiftUI's `TextField` can't take focus reliably in a
/// non-activating panel); Return and Escape handled here.
struct SearchField: NSViewRepresentable {

    @Binding var text: String
    /// Changing this value re-asserts focus.
    var focusToken: Int
    var placeholder: String
    var onSubmit: () -> Void
    var onCancel: () -> Void
    var style: Style = .standard

    /// The search panel's field, or Pip's, which follows his design spec:
    /// SF Pro Rounded at 15, a leaf-green cursor, and greyed text while he
    /// thinks about what was typed.
    enum Style: Equatable {
        case standard
        /// `compact`: the small "Ask Pip" pill — smaller text, no caret
        /// until you type (typing opens the full bar).
        case pip(thinking: Bool, compact: Bool = false)

        var font: NSFont {
            switch self {
            case .standard:
                return .systemFont(ofSize: 13.5, weight: .regular)
            case .pip(_, let compact):
                return .systemFont(ofSize: compact ? 13 : 15, weight: .regular)
            }
        }

        var textColour: NSColor {
            if case .pip(true, _) = self { return Self.grey }
            return .white
        }

        var placeholderColour: NSColor {
            self == .standard ? NSColor.white.withAlphaComponent(0.32) : NSColor.white.withAlphaComponent(0.55)
        }

        var caret: NSColor? {
            switch self {
            case .standard: return nil
            // No caret in the greyed question while Pip works on it.
            case .pip(let thinking, let compact): return compact || thinking ? .clear : .white
            }
        }

        var kern: CGFloat { 0 }

        private static let grey = NSColor.white.withAlphaComponent(0.55)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        apply(style, to: field)
        context.coordinator.lastStyle = style
        return field
    }

    private func apply(_ style: Style, to field: NSTextField) {
        field.font = style.font
        // Pip's bar, when not being typed in: a long sentence shows its end
        // ("…the PDF from last week"), the words just said.
        if case .pip = style { field.lineBreakMode = .byTruncatingHead }
        field.textColor = style.textColour
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: style.placeholderColour,
                         .font: style.font,
                         .kern: style.kern])
        if let editor = field.currentEditor() as? NSTextView {
            if let caret = style.caret { editor.insertionPointColor = caret }
            editor.typingAttributes[.kern] = style.kern
            // Mid-edit, the field editor keeps its own font; keep it in step.
            editor.font = style.font
            editor.typingAttributes[.font] = style.font
        }
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
            // Set from outside (your words as you speak): keep the end in
            // view. The field showed the start, so the newest words of a
            // long sentence were cut off at the right.
            if let editor = field.currentEditor() as? NSTextView {
                let end = NSRange(location: (text as NSString).length, length: 0)
                editor.selectedRange = end
                editor.scrollRangeToVisible(end)
            }
        }
        // The same field serves search and Pip, so its prompt and colours
        // can change after it has been made.
        if field.placeholderAttributedString?.string != placeholder
            || context.coordinator.lastStyle != style {
            context.coordinator.lastStyle = style
            apply(style, to: field)
        }
        context.coordinator.parent = self

        guard context.coordinator.lastToken != focusToken else { return }
        context.coordinator.lastToken = focusToken
        DispatchQueue.main.async {
            guard let window = field.window else { return }
            window.makeFirstResponder(field)
            // The field editor only exists once the field is first responder,
            // so the cursor colour can only be set now.
            if let editor = field.currentEditor() as? NSTextView {
                if let caret = self.style.caret { editor.insertionPointColor = caret }
                editor.typingAttributes[.kern] = self.style.kern
            }
            // Put the caret at the end rather than selecting everything, so
            // typing after a re-focus appends instead of replacing.
            field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.count, length: 0)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        var lastToken = -1
        var lastStyle: Style = .standard

        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl,
                     textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}
