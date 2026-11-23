import ContactsUI
import SwiftUI

/// Lets someone link a friend to a person in their own Contacts, so the friend shows up under the name
/// they already know. Opened from "Link Contact" in the friend card's ⋯ menu.
///
/// Privacy: the link lives only on this device. It is never uploaded or added to the encrypted backup,
/// because a contact identifier means nothing on another phone and the address book is not ours to share.
struct ContactLinkView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let friendID: Data
    @State private var choosingContact = false

    var body: some View {
        ContentFittedSheet(title: "Linked Contact", showsCloseButton: true) {
            Text("Choose a contact to use their name on this device. A nickname you've set takes priority. Contacts are never uploaded.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let contact = model.local.friends[friendID]?.linkedContact {
                Label(contact.name, systemImage: "person.crop.circle")
                Button("Unlink Contact", role: .destructive) {
                    model.setLinkedContact(nil, for: friendID)
                    dismiss()
                }
                .frame(minHeight: 44)
            }
            Button("Choose Contact") { choosingContact = true }
                .frame(minHeight: 44)
        }
        .sheet(isPresented: $choosingContact) {
            ContactPicker { contact in
                choosingContact = false
                guard let contact else { return }
                model.setLinkedContact(contact, for: friendID)
                dismiss()
            }
        }
    }
}

/// The system picker returns only the selected contact; broad address-book authorization is unnecessary.
private struct ContactPicker: UIViewControllerRepresentable {
    let onSelect: (LinkedContact?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onSelect: (LinkedContact?) -> Void

        init(onSelect: @escaping (LinkedContact?) -> Void) {
            self.onSelect = onSelect
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            // Fall back to the company name for business cards, and to a placeholder for blank entries,
            // so the friend card never ends up with an empty title.
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName
            onSelect(LinkedContact(identifier: contact.identifier,
                                   name: name.isEmpty ? String(localized: "Unnamed Contact") : name))
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            onSelect(nil)
        }
    }
}
