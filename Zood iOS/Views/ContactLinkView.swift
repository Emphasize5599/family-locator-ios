import ContactsUI
import SwiftUI

/// Links only the selected Contacts card and optionally uses its photo for this friend.
struct ContactLinkView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let friendID: Data
    @State private var choosingContact = false
    @State private var confirmingUnlink = false
    @State private var restoringPhoto = false
    @State private var photoUnavailable = false
    @State private var selectedContact: LinkedContact?

    var body: some View {
        ContentFittedSheet(title: selectedContact == nil ? "Linked Contact" : "Use Contact Photo?", showsCloseButton: true) {
            if let selectedContact, let friend = model.local.friends[friendID] {
                replacementPrompt(selectedContact, friend: friend)
            } else if confirmingUnlink {
                Text("Unlink this contact?")
                    .font(.headline)
                Text("Amidst will stop using the linked photo and name. A picture or nickname you chose separately will stay.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    model.setLinkedContact(nil, for: friendID)
                    dismiss()
                } label: {
                    Text("Unlink Contact").frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .tint(.zoodRed)
                Button("Cancel") { confirmingUnlink = false }.frame(minHeight: 44)
            } else {
                Text("Link a contact to use their name and choose whether to show their photo. Amidst saves the selected name, contact reference and small photo in your encrypted account backup. This is private to your account.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let contact = model.local.friends[friendID]?.linkedContact {
                    HStack(spacing: Spacing.medium) {
                        AvatarView(username: contact.name, imageData: contact.photo, size: 44)
                        Text(contact.name).font(.headline)
                    }
                    if contact.photo == nil, !contact.identifier.isEmpty {
                        Button("Restore Contact Photo") {
                            restoringPhoto = true
                            Task {
                                photoUnavailable = !(await model.restoreContactPhoto(for: friendID))
                                restoringPhoto = false
                            }
                        }
                        .frame(minHeight: 44)
                        .disabled(restoringPhoto)
                    }
                    if photoUnavailable {
                        Label("Choose the contact again to load its current photo.", systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    choosingContact = true
                } label: {
                    Label("Choose Contact", systemImage: "person.crop.circle.badge.plus")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                if model.local.friends[friendID]?.linkedContact != nil {
                    Button("Unlink Contact", role: .destructive) { confirmingUnlink = true }
                        .frame(minHeight: 44)
                }
            }
        }
        .tint(.zoodBlue)
        .sheet(isPresented: $choosingContact) {
            ContactPicker { contact in
                choosingContact = false
                guard let contact, let friend = model.local.friends[friendID] else { return }
                if let photo = contact.photo, let current = friend.displayAvatar, current != photo {
                    selectedContact = contact
                } else {
                    link(contact, usePhoto: contact.photo != nil || friend.displayAvatar == nil)
                }
            }
        }
    }

    private func replacementPrompt(_ contact: LinkedContact, friend: Friend) -> some View {
        VStack(spacing: Spacing.medium) {
            Text("Use the photo from Contacts or keep the current picture. Both choices link the contact.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(alignment: .top, spacing: Spacing.large) {
                photoPreview("Current", data: friend.displayAvatar, name: friend.avatarName)
                photoPreview("Contact", data: contact.photo, name: contact.name)
            }
            Button {
                link(contact, usePhoto: true)
            } label: {
                Text("Use Contact Photo").frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            Button("Keep Current Photo") { link(contact, usePhoto: false) }.frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity)
    }

    private func photoPreview(_ label: LocalizedStringKey, data: Data?, name: String) -> some View {
        VStack(spacing: Spacing.small) {
            AvatarView(username: name, imageData: data, size: 56)
            Text(label).font(.caption)
        }
        .frame(maxWidth: .infinity)
    }

    private func link(_ contact: LinkedContact, usePhoto: Bool) {
        model.setLinkedContact(contact, usePhoto: usePhoto, for: friendID)
        dismiss()
    }
}

/// Manages the picture shown only on the signed-in account’s map, cards and friend bar.
struct FriendPhotoView: View {
    @EnvironmentObject private var model: AppModel
    let friendID: Data
    @State private var showingPicker = false
    @State private var pickedImage: UIImage?
    @State private var crop: Crop?

    private struct Crop: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    var body: some View {
        ContentFittedSheet(title: "Friend Photo", showsCloseButton: true) {
            if let friend = model.local.friends[friendID] {
                VStack(spacing: Spacing.medium) {
                    AvatarView(username: friend.avatarName, imageData: friend.displayAvatar, size: 72)
                    Text("This photo is private to you and is saved in your encrypted account backup.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button { showingPicker = true } label: {
                        Label("Choose Photo", systemImage: "photo")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    if friend.linkedContact?.photo != nil,
                       friend.avatarOverride != nil || friend.useLinkedContactPhoto == false {
                        Button {
                            model.setFriendPhoto(useContact: true, for: friendID)
                        } label: {
                            Label("Use Contact Photo", systemImage: "person.crop.circle")
                                .frame(minHeight: 44)
                        }
                    }
                    if friend.avatarOverride != nil || (friend.linkedContact?.photo != nil && friend.useLinkedContactPhoto != false) {
                        Button {
                            model.setFriendPhoto(for: friendID)
                        } label: {
                            Label(friend.avatar == nil ? "Use Initials" : "Use Shared Photo", systemImage: "arrow.uturn.backward")
                                .frame(minHeight: 44)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .tint(.zoodBlue)
        .sheet(isPresented: $showingPicker, onDismiss: {
            if let pickedImage { crop = Crop(image: pickedImage) }
            pickedImage = nil
        }) {
            ImagePicker {
                pickedImage = $0.flatMap(UIImage.init(data:))
                showingPicker = false
            }
        }
        .fullScreenCover(item: $crop) { crop in
            AvatarCropView(image: crop.image, onChoose: {
                model.setFriendPhoto($0, for: friendID)
                self.crop = nil
            }, onCancel: { self.crop = nil })
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
