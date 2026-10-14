// A text field the editors use instead of SwiftUI's TextField. SwiftUI's field on macOS re-sets the field's text
// from the binding on every keystroke, and while that happens a trailing space is dropped until the next
// character arrives — so "Work documents" shows "Workdocuments" as it is typed. This one keeps the field's own
// text while it is being edited and only writes to it when the binding was changed from elsewhere (loading a
// destination, "From ~/.ssh/config", Choose…).
import SwiftUI
import AppKit

struct PlainTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var monospaced = false
    /// what the field is for, read out by VoiceOver and shown as the form label by the caller
    var label: String?

    init(_ placeholder: String, text: Binding<String>, monospaced: Bool = false, label: String? = nil) {
        self.placeholder = placeholder; _text = text; self.monospaced = monospaced; self.label = label
    }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField(string: text)
        f.delegate = context.coordinator
        f.placeholderString = placeholder
        f.isBordered = true
        f.bezelStyle = .roundedBezel
        f.lineBreakMode = .byClipping
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        f.cell?.usesSingleLineMode = true
        f.font = monospaced ? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize + 1, weight: .regular) : NSFont.systemFont(ofSize: NSFont.systemFontSize + 1)
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let label { f.setAccessibilityLabel(label) }
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        f.placeholderString = placeholder
        // while the user types, the field is the truth; a change from elsewhere (Choose…, loading) is applied
        if f.currentEditor() == nil, f.stringValue != text { f.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PlainTextField
        init(_ p: PlainTextField) { parent = p }
        func controlTextDidChange(_ n: Notification) {
            // SwiftUI may be mid-update; writing the binding on the next turn keeps the field's text intact
            guard let f = n.object as? NSTextField else { return }
            let value = f.stringValue
            DispatchQueue.main.async { [self] in if parent.text != value { parent.text = value } }
        }
    }
}

/// A labelled row in a Form: the label on the left, a PlainTextField on the right.
struct Field: View {
    let label: String
    @Binding var text: String
    let prompt: String
    var mono = false
    init(_ label: String, _ text: Binding<String>, _ prompt: String = "", mono: Bool = false) { self.label = label; _text = text; self.prompt = prompt; self.mono = mono }
    var body: some View {
        LabeledContent(label) { PlainTextField(prompt, text: $text, monospaced: mono, label: label) }
    }
}
