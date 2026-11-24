import SwiftUI

struct AddFriendView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var enteringUsername: Bool

    @State private var username = ""
    @State private var lookup: UsernameLookup?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showingInvite = false
    @State private var candidate: ZoodUser?

    init(preview: ZoodUser? = nil) {
        _candidate = State(initialValue: preview)
    }

    private var handle: String { Username.forLookup(username) }
    private var pending: PendingRequest? { model.pendingRequest(username: handle) }
    private var isSelf: Bool {
        handle == model.credentials.map { Username.forLookup($0.username) }
    }

    var body: some View {
        CompatNavigationStack {
            Form {
                if let candidate {
                    Section {
                        Label("@\(candidate.username)", systemImage: "person.crop.circle")
                    } footer: {
                        Text("Send your friend request with or without sharing your location. You can change sharing later.")
                    }
                    Section {
                        Button {
                            send(to: candidate, sharing: true)
                        } label: {
                            Label("Share My Location", systemImage: "location.fill")
                        }
                        .tint(.zoodGreen)
                        Button("Not Now") { send(to: candidate, sharing: false) }
                    }
                } else {
                    Section {
                        TextField("Friend’s username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($enteringUsername)
                            .submitLabel(.continue)
                            .onSubmit { if canContinue { next() } }
                        if isSelf {
                            Label("You can’t add yourself", systemImage: "exclamationmark.circle")
                                .foregroundStyle(Color.zoodRed)
                        } else if pending != nil {
                            Label("Incoming request", systemImage: "person.crop.circle.badge.checkmark")
                                .foregroundStyle(Color.zoodGreen)
                        } else if ZoodConstants.isValidUsername(handle) {
                            UsernameLookupStatus(result: lookup?.username == handle ? lookup?.result : nil)
                        }
                    }
                    Section {
                        Button(pending == nil ? "Continue" : "Approve Request", action: next)
                            .tint(pending == nil ? .zoodBlue : .zoodGreen)
                            .disabled(!canContinue)
                        Button { showingInvite = true } label: {
                            Label("Invite Someone", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                if isWorking { ProgressView() }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle").foregroundStyle(Color.zoodRed)
                }
            }
            .disabled(isWorking)
            .navigationTitle(candidate == nil ? "Add Friend" : "Share Location?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if candidate == nil {
                        Button("Cancel") { dismiss() }.disabled(isWorking)
                    } else {
                        Button("Back") {
                            candidate = nil
                            errorMessage = nil
                        }
                        .disabled(isWorking)
                    }
                }
            }
        }
        .interactiveDismissDisabled(isWorking)
        .task(id: handle) {
            let entered = handle
            guard ZoodConstants.isValidUsername(entered), !isSelf, pending == nil else { return }
            await UsernameLookup.check(entered, registration: false, model: model) { lookup = $0 }
        }
        .sheet(isPresented: $showingInvite) { ActivityView(items: [inviteText]) }
    }

    private var canContinue: Bool {
        !isWorking && !isSelf && ZoodConstants.isValidUsername(handle)
            && (pending != nil || (lookup?.username == handle && lookup?.result != .notFound))
    }

    private var inviteText: String {
        "Install Amidst (iPhone or Android) or Zood Location (Android) so we can securely share our location with each other. My username is @\(model.credentials?.username ?? "")."
    }

    private func next() {
        let entered = handle
        perform {
            if let user = try await model.prepareAddFriend(username: entered) {
                enteringUsername = false
                candidate = user
            } else {
                dismiss()
            }
        }
    }

    private func send(to user: ZoodUser, sharing: Bool) {
        perform {
            try await model.confirmAddFriend(with: user, sharing: sharing)
            dismiss()
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do { try await action() }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

/// Key each response to the normalized input so a late answer can never decorate the next username.
struct UsernameLookup {
    enum Result { case found, notFound, unavailable }
    let username: String
    let result: Result

    @MainActor
    static func check(_ username: String, registration: Bool, model: AppModel, apply: (Self) -> Void) async {
        do {
            try await Task.sleep(nanoseconds: 350_000_000)
            let exists = try await model.usernameExists(username, registration: registration)
            guard !Task.isCancelled else { return }
            apply(Self(username: username, result: exists ? .found : .notFound))
        } catch {
            guard !Task.isCancelled else { return }
            apply(Self(username: username, result: .unavailable))
        }
    }
}

struct UsernameLookupStatus: View {
    var result: UsernameLookup.Result?
    var registration = false

    var body: some View {
        Group {
            switch result {
            case .found:
                if registration {
                    Label("Username already taken", systemImage: "xmark.circle").foregroundStyle(Color.zoodRed)
                } else {
                    Label("Account found", systemImage: "checkmark.circle").foregroundStyle(Color.zoodGreen)
                }
            case .notFound:
                if registration {
                    Label("Username available", systemImage: "checkmark.circle").foregroundStyle(Color.zoodGreen)
                } else {
                    Label("Account not found", systemImage: "xmark.circle").foregroundStyle(Color.zoodRed)
                }
            case .unavailable:
                Text("Couldn’t check right now").foregroundStyle(.secondary)
            case nil:
                ProgressView("Checking username…")
            }
        }
        .font(.footnote)
    }
}
