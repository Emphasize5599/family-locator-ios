import SwiftUI

struct DeleteAccountView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var confirmation = ""
    @State private var isDeleting = false
    @State private var showingConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Text("Permanently delete your Zood account and its encrypted friends-list backup from the server. This affects this account in Family Locator and other Zood apps.")
                Text("You will be signed out and location sharing will stop on this iPhone. Previously received locations or copies saved by other people cannot be recalled.")
            }
            Section {
                TextField("Your username", text: $confirmation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Type your username to confirm")
            } footer: {
                Text("This cannot be undone. To stop sharing without deleting your account, turn off sharing for each friend instead.")
            }
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(Color.zoodRed)
                }
            }
            Section {
                Button("Delete Account", role: .destructive) {
                    showingConfirmation = true
                }
                .disabled(isDeleting || model.credentials?.username != confirmation.trimmingCharacters(in: .whitespacesAndNewlines))
                if isDeleting {
                    ProgressView("Deleting account…")
                }
            }
        }
        .disabled(isDeleting)
        .navigationTitle("Delete Account")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Permanently delete your account?", isPresented: $showingConfirmation, titleVisibility: .visible) {
            Button("Delete Account Permanently", role: .destructive) {
                isDeleting = true
                errorMessage = nil
                Task {
                    do {
                        try await model.deleteAccount()
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    isDeleting = false
                }
            }
        } message: {
            Text("Your account and encrypted backup will be deleted. You cannot undo this.")
        }
    }
}
