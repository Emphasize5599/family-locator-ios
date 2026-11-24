import SwiftUI

/// A wrapping draft field. Its parent keeps the surrounding controls in their usual positions.
struct InlineNameField: View {
    let label: String
    @Binding var text: String
    var style: UIFont.TextStyle = .body
    let onSave: () -> Void
    let onCancel: () -> Void

    private var font: Font {
        switch style {
        case .title2: return .title2.bold()
        case .headline: return .headline
        default: return .body
        }
    }

    var body: some View {
        Text(verbatim: text.isEmpty ? " " : text)
            .font(font)
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, Spacing.tight)
            .hidden()
            .accessibilityHidden(true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground).opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .leading) {
                if text.isEmpty {
                    Text(verbatim: label).font(font).foregroundStyle(.secondary).lineLimit(1)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                NameTextView(label: label, text: $text, style: style, onSave: onSave, onCancel: onCancel)
            }
    }
}

/// UITextView keeps soft wrapping and gives the return key an explicit submit action.
private struct NameTextView: UIViewRepresentable {
    let label: String
    @Binding var text: String
    let style: UIFont.TextStyle
    let onSave: () -> Void
    let onCancel: () -> Void

    final class Editor: UITextView {
        var onSave: () -> Void = {}
        var onCancel: () -> Void = {}
        private var needsInitialFocus = true
        lazy var outsideTap: UITapGestureRecognizer = {
            let tap = UITapGestureRecognizer(target: self, action: #selector(discardDraft))
            tap.cancelsTouchesInView = false
            return tap
        }()

        override func willMove(toWindow newWindow: UIWindow?) {
            if let window, window !== newWindow { window.removeGestureRecognizer(outsideTap) }
            super.willMove(toWindow: newWindow)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window else { return }
            if outsideTap.view !== window { window.addGestureRecognizer(outsideTap) }
            guard needsInitialFocus else { return }
            needsInitialFocus = false
            Task { @MainActor [weak self] in
                guard let self, self.window != nil else { return }
                self.becomeFirstResponder()
            }
        }

        override func insertText(_ text: String) {
            if text == "\n", markedTextRange == nil {
                onSave()
            } else {
                super.insertText(text)
            }
        }

        @objc private func discardDraft() { onCancel() }
    }

    func makeUIView(context: Context) -> Editor {
        let editor = Editor()
        editor.backgroundColor = .clear
        editor.textColor = .label
        editor.textContainerInset = UIEdgeInsets(top: Spacing.tight, left: 0, bottom: Spacing.tight, right: 0)
        editor.textContainer.lineFragmentPadding = 0
        editor.textContainer.lineBreakMode = .byWordWrapping
        editor.returnKeyType = .done
        editor.autocapitalizationType = .words
        editor.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        editor.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        editor.delegate = context.coordinator
        editor.outsideTap.delegate = context.coordinator
        context.coordinator.editor = editor
        return editor
    }

    func updateUIView(_ editor: Editor, context: Context) {
        context.coordinator.field = self
        editor.onSave = onSave
        editor.onCancel = onCancel
        editor.accessibilityLabel = label
        let preferred = UIFont.preferredFont(forTextStyle: style, compatibleWith: editor.traitCollection)
        editor.font = style == .title2 ? .boldSystemFont(ofSize: preferred.pointSize) : preferred
        if editor.text != text && editor.markedTextRange == nil {
            editor.text = text
            if !editor.isFirstResponder { editor.selectedRange = NSRange(location: text.utf16.count, length: 0) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(field: self) }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        weak var editor: Editor?
        var field: NameTextView

        init(field: NameTextView) { self.field = field }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var hit = touch.view
            while let view = hit {
                if view === editor || view.accessibilityIdentifier == InlineNameActions.saveID
                    || view.accessibilityIdentifier == InlineNameActions.discardID { return false }
                hit = view.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

        func textViewDidChange(_ textView: UITextView) {
            field.text = textView.text
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n", textView.markedTextRange == nil else { return true }
            field.onSave()
            return false
        }
    }
}

struct InlineNameActions: View {
    static let saveID = "inline-name-save"
    static let discardID = "inline-name-discard"
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: Spacing.tight) {
            Spacer(minLength: 0)
            PanelIconButton(systemName: "checkmark.circle.fill", tint: UIColor(Color.zoodGreen),
                            accessibilityLabel: String(localized: "Save"), accessibilityIdentifier: Self.saveID, action: onSave)
                .frame(width: 44, height: 44)
            PanelIconButton(systemName: "xmark.circle", tint: UIColor(Color.zoodYellow),
                            accessibilityLabel: String(localized: "Cancel"), accessibilityIdentifier: Self.discardID, action: onCancel)
                .frame(width: 44, height: 44)
        }
    }
}
