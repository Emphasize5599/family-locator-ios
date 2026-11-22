import SwiftUI

struct FriendNicknameView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let friend: Friend

    // Edit a draft: dismissing with Close or a swipe must never change the saved name.
    @State private var nickname = ""

    var body: some View {
        ContentFittedSheet(title: "Friend Nickname", showsCloseButton: true) {
            Text("@\(friend.user.username)")
                .font(.subheadline)
                .textSelection(.enabled)
            TextField("Nickname (optional)", text: $nickname)
                .textFieldStyle(.roundedBorder)
                .textContentType(.nickname)
            Text("Only you see this name. Clear it to use their shared nickname or username.")
                .font(.footnote).foregroundStyle(.secondary)
            Button {
                model.setFriendNickname(nickname, for: friend.id)
                dismiss()
            } label: {
                Text("Save").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
        }
        .onAppear { nickname = friend.nickname ?? "" }
    }
}
