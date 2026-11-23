import ContactsUI
import SwiftUI

/// Lets someone link a friend to a person in their own Contacts, so the friend shows up under the name
/// they already know. Opened from "Link Contact" in the friend card's ⋯ menu.
///
/// Privacy: only the chosen contact's name and its Contacts identifier are kept, on this device and in the
/// end-to-end encrypted backup (so the link survives signing in again; the server can't read it). The rest of
/// the address book is never read or uploaded, and the link is never sent to the friend.
struct ContactLinkView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let friendID: Data
    @State private var choosingContact = false
    @State private var confirmingUnlink = false

    var body: some View {
        ContentFittedSheet(title: "Linked Contact", showsCloseButton: true) {
            Text("Choose a contact to use their name as this friend's nickname and their photo as the friend's picture. Only that contact's name, photo and a reference to it are kept on this iPhone, and the name and reference in your end-to-end encrypted backup. Your other contacts are never read or uploaded.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let contact = model.local.friends[friendID]?.linkedContact {
                Label(contact.name, systemImage: "person.crop.circle")
                Button("Unlink Contact", role: .destructive) { confirmingUnlink = true }
                    .frame(minHeight: 44)
            }
            Button("Choose Contact") { choosingContact = true }
                .frame(minHeight: 44)
        }
        .alert("Unlink this contact?", isPresented: $confirmingUnlink) {
            Button("Cancel", role: .cancel) {}
            Button("Unlink Contact", role: .destructive) {
                model.setLinkedContact(nil, for: friendID)
                dismiss()
            }
        } message: {
            Text("Their contact photo is removed, and the nickname it set is cleared unless you've changed it since.")
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
            // First and last name become the friend's nickname. Fall back to the formatted name, then the company
            // name for business cards, and finally a placeholder, so the card never ends up with an empty title.
            let parts = [contact.givenName, contact.familyName].map { $0.trimmingCharacters(in: .whitespaces) }
            var name = parts.filter { !$0.isEmpty }.joined(separator: " ")
            if name.isEmpty { name = CNContactFormatter.string(from: contact, style: .fullName) ?? "" }
            if name.isEmpty { name = contact.organizationName }
            // The picker hands back the chosen card with its thumbnail; nothing else from Contacts is read.
            // The thumbnail is the contact photo as the person framed it in Contacts (the full `imageData` is the
            // uncropped original), so it's used as-is: re-cropping here could undo their framing.
            let photo = contact.isKeyAvailable(CNContactThumbnailImageDataKey) ? contact.thumbnailImageData : nil
            onSelect(LinkedContact(identifier: contact.identifier,
                                   name: name.isEmpty ? String(localized: "Unnamed Contact") : name,
                                   photo: photo))
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            onSelect(nil)
        }
    }
}
