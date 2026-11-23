import SwiftUI

struct AddFriendView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showingInvite = false

    var body: some View {
        ContentFittedSheet(title: "Add Friend") {
            TextField("Friend's username", text: $username).submitLabel(.done)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            Text("They'll start seeing your location right away. You'll see theirs after they share with you and you approve their request. Works with people using Zood on Android too.")
                .font(.footnote).foregroundStyle(.secondary)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.zoodRed)
            }
            Button(action: add) {
                HStack {
                    Text("Add")
                    if isWorking { ProgressView() }
                }.frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking || username.trimmingCharacters(in: .whitespaces).isEmpty)
            Button { showingInvite = true } label: {
                Label("Invite Someone", systemImage: "square.and.arrow.up").frame(minHeight: 44)
            }
        }
        .sheet(isPresented: $showingInvite) { ActivityView(items: [inviteText]) }
    }

    private var inviteText: String {
        "Install Family Locator (iPhone) or Zood Location (Android) so we can securely share our location with each other. My username is @\(model.credentials?.username ?? "")."
    }

    private func add() {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await model.addFriend(username: username)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}
