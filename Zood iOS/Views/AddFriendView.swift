import SwiftUI

struct AddFriendView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showingInvite = false

    var body: some View {
        CompatNavigationStack {
            Form {
                Section {
                    TextField("Friend's username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(add)
                } footer: {
                    Text("They'll start seeing your location right away. You'll see theirs once they add you back. Works with people using Zood on Android too.")
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.zoodRed)
                    }
                }
                Section {
                    Button {
                        showingInvite = true
                    } label: {
                        Label("Invite Someone", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .sheet(isPresented: $showingInvite) {
                ActivityView(items: [inviteText])
            }
            .navigationTitle("Add Friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button("Add", action: add)
                            .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private var inviteText: String {
        "Install Family Locator (iPhone) or Zood Location (Android) so we can securely share our location with each other. My username is \(model.credentials?.username ?? "")."
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
