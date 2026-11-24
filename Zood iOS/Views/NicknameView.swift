import SwiftUI

/// Edits a draft where its name normally appears. The caller decides when to commit it.
struct InlineNameEditor: View {
    let label: LocalizedStringKey
    @Binding var text: String
    var font: Font = .body
    let onSave: () -> Void
    let onCancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.tight) {
            field
                .font(font)
                .focused($focused)
                .accessibilityLabel(label)
                .layoutPriority(1)
            Button(action: onSave) {
                Image(systemName: "checkmark").frame(width: 36, height: 44)
            }
            .accessibilityLabel("Save")
            .tint(.zoodYellow)
            Button(action: onCancel) {
                Image(systemName: "xmark").frame(width: 36, height: 44)
            }
            .accessibilityLabel("Cancel")
            .tint(.zoodYellow)
        }
        .buttonStyle(.borderless)
        .task {
            // Let the field join its card or Form before asking for the keyboard.
            await Task.yield()
            focused = true
        }
    }

    @ViewBuilder private var field: some View {
        if #available(iOS 16, *) {
            TextField(label, text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .frame(minHeight: 44)
        } else {
            // TextEditor gives iOS 15 a wrapping input. Its sizing text follows the same layout.
            Text(text.isEmpty ? " " : text)
                .lineLimit(4)
                .padding(8)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .hidden()
                .overlay {
                    TextEditor(text: $text)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                }
        }
    }
}
