import SwiftUI

struct FriendNicknameView: View {
    @EnvironmentObject private var model: AppModel
    let friend: Friend

    var body: some View {
        NicknameEditor(title: "Friend Nickname", username: friend.user.username, initial: friend.nickname,
                       explanation: "Only you see this name. Clear it to use their shared nickname or username.") { nickname in
            model.setFriendNickname(nickname, for: friend.id)
        }
    }
}

struct NicknameEditor: View {
    @Environment(\.dismiss) private var dismiss
    let title: LocalizedStringKey
    let username: String
    let initial: String?
    let explanation: LocalizedStringKey
    let onSave: (String) async -> Void
    @State private var nickname = ""
    @State private var saving = false

    private var changed: Bool { Nickname.normalized(nickname) != initial }

    var body: some View {
        CompatNavigationStack {
            Form {
                Section {
                    TextField("Nickname (optional)", text: $nickname)
                        .textContentType(.nickname)
                        .submitLabel(.done)
                        .onSubmit(save)
                } header: {
                    if !username.isEmpty { Text("@\(username)").textCase(nil) }
                } footer: {
                    Text(explanation)
                }
                if saving { ProgressView("Saving…") }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .tint(changed ? .zoodYellow : .zoodBlue)
                        .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .tint(.zoodYellow)
                        .disabled(!changed || saving)
                }
            }
            .disabled(saving)
        }
        .onAppear { nickname = initial ?? "" }
        .interactiveDismissDisabled(saving)
    }

    private func save() {
        guard changed, !saving else { return }
        saving = true
        Task {
            await onSave(nickname)
            saving = false
            dismiss()
        }
    }
}
