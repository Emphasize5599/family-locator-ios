import SwiftUI

struct AddFriendView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showingInvite = false
    @State private var sharingCandidate: ZoodUser?

    var body: some View {
        ContentFittedSheet(title: "Add Friend") {
            TextField("Friend's username", text: $username).submitLabel(.done)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            Text(model.pendingRequest(username: username) != nil
                 ? "Approve their incoming request to see their location."
                 : "Enter a username to check for an incoming request or start sharing.")
                .font(.footnote).foregroundStyle(.secondary)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.zoodRed)
            }
            Button(action: add) {
                HStack {
                    Text(model.pendingRequest(username: username) == nil ? "Add" : "Approve Request")
                    if isWorking { ProgressView() }
                }.frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking || username.trimmingCharacters(in: .whitespaces).isEmpty)
            Button { showingInvite = true } label: {
                Label("Invite Someone", systemImage: "square.and.arrow.up").frame(minHeight: 44)
            }
        }
        .alert("Share your location?", isPresented: Binding(get: { sharingCandidate != nil },
                                                             set: { if !$0 { sharingCandidate = nil } }),
               presenting: sharingCandidate) { user in
            Button("Cancel", role: .cancel) {}
            Button("Share My Location") {
                isWorking = true
                Task {
                    defer { isWorking = false }
                    do {
                        try await model.confirmAddFriendSharing(with: user)
                        dismiss()
                    } catch { errorMessage = error.localizedDescription }
                }
            }
        } message: { user in
            Text("Allow @\(user.username) to see your location.")
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
                if let user = try await model.prepareAddFriend(username: username) {
                    sharingCandidate = user
                } else {
                    dismiss()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}
