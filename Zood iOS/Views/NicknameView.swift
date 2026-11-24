import SwiftUI

/// A wrapping draft field. Its parent keeps the surrounding controls in their usual positions.
struct InlineNameField: View {
    let label: LocalizedStringKey
    @Binding var text: String
    var font: Font = .body

    @FocusState private var focused: Bool

    var body: some View {
        field
            .font(font)
            .focused($focused)
            .accessibilityLabel(label)
            .frame(maxWidth: .infinity, alignment: .leading)
            .task {
                await Task.yield()
                focused = true
            }
    }

    @ViewBuilder private var field: some View {
        if #available(iOS 16, *) {
            TextField(label, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, Spacing.tight)
                .background(Color(uiColor: .secondarySystemBackground).opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
        } else {
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

struct InlineNameActions: View {
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: Spacing.tight) {
            Spacer(minLength: 0)
            PanelIconButton(systemName: "checkmark.circle.fill", tint: UIColor(Color.zoodGreen),
                            accessibilityLabel: String(localized: "Save"), action: onSave)
                .frame(width: 44, height: 44)
            PanelIconButton(systemName: "xmark.circle", tint: UIColor(Color.zoodYellow),
                            accessibilityLabel: String(localized: "Cancel"), action: onCancel)
                .frame(width: 44, height: 44)
        }
    }
}
