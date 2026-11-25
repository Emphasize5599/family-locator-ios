import SwiftUI

/// Add Friend: look up someone by exact username, choose whether to share your location with them right away,
/// or invite people who don't have the app yet. Exact-username lookup (no browsing) keeps strangers from finding people.
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
    @State private var choiceLabelHeight: CGFloat = 0

    /// Which invite the share sheet sends (see `inviteText`).
    @State private var inviteWithLink = true
    @State private var choosingInvite = false
    /// The one-time link minted for this share, when the user chose to include one.
    @State private var issuedInviteLink: URL?
    /// Set when Add Friend was opened from a one-time invite. Nil for a username-only link.
    private let linkToken: Data?
    private let invitedUsername: String?

    private var inviteToken: Data? { handle == invitedUsername ? linkToken : nil }

    /// `prefill` fills in a username from a friend link; the account check starts right away, but nothing is sent
    /// until the user taps Share My Location or Not Now. `inviteToken` connects immediately instead of requesting.
    init(preview: ZoodUser? = nil, prefill: String? = nil, inviteToken: Data? = nil) {
        _candidate = State(initialValue: preview)
        _username = State(initialValue: prefill ?? "")
        linkToken = inviteToken
        invitedUsername = prefill.map(Username.forLookup)
    }

    private var handle: String { Username.forLookup(username) }
    private var pending: PendingRequest? { model.pendingRequest(username: handle) }
    private var isSelf: Bool {
        handle == model.credentials.map { Username.forLookup($0.username) }
    }

    private var title: LocalizedStringKey {
        if candidate == nil { return "Add Friend" }
        return inviteToken == nil ? "Share Location?" : "Connect?"
    }
    private var backAction: (() -> Void)? { candidate == nil ? nil : { goBack() } }

    var body: some View {
        ContentFittedSheet(title: title, showsCloseButton: true, backAction: backAction) {
            if let candidate {
                sharingStep(for: candidate)
            } else {
                lookupStep
            }
            if isWorking { ProgressView() }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle").foregroundStyle(Color.zoodRed)
            }
        }
        .disabled(isWorking)
        .interactiveDismissDisabled(isWorking)
        .task(id: handle) {
            let entered = handle
            guard ZoodConstants.isValidUsername(entered), !isSelf, pending == nil else { return }
            await UsernameLookup.check(entered, registration: false, model: model) { lookup = $0 }
            guard !Task.isCancelled, inviteToken != nil, candidate == nil,
                  lookup?.username == entered, lookup?.result == .found else { return }
            next()
        }
        .sheet(isPresented: $showingInvite) { ActivityView(items: [inviteText]) }
        // Some people want to hand out a link straight to their profile; others would rather not share their
        // username with everyone who sees the message (for example in a group chat), so it's their choice.
        .confirmationDialog("Share an Invite", isPresented: $choosingInvite, titleVisibility: .visible) {
            Button("Include a One-Time Link") { shareInvite(withLink: true) }
            Button("Without My Username") { shareInvite(withLink: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A one-time link connects them right away. You won’t share your location unless you turn it on later.")
        }
    }

    private func sharingStep(for user: ZoodUser) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Label("@\(user.username)", systemImage: "person.crop.circle")
                .font(.headline)
            Group {
                if inviteToken == nil {
                    Text("Send your friend request with or without sharing your location. You can change sharing later.")
                } else {
                    Text("A valid invite connects you when their app receives it. They choose when to share their location.")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            HStack(spacing: Spacing.small) {
                Button {
                    send(to: user, sharing: true)
                } label: {
                    choiceLabel("Share My Location")
                }
                .tint(Color.zoodGreen)
                Button {
                    send(to: user, sharing: false)
                } label: {
                    choiceLabel("Not Now")
                }
            }
            .buttonStyle(.bordered)
            .onPreferenceChange(ChoiceLabelHeightKey.self) { choiceLabelHeight = $0 }
        }
    }

    private func choiceLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: ChoiceLabelHeightKey.self, value: geometry.size.height)
                }
            }
            .frame(maxWidth: .infinity, minHeight: max(44, choiceLabelHeight))
    }

    private struct ChoiceLabelHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    @ViewBuilder private var lookupStep: some View {
        TextField("Friend’s username", text: $username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textFieldStyle(.roundedBorder)
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
        Button(action: next) {
            Text(pending == nil ? "Continue" : "Approve Request")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(pending == nil ? Color.zoodBlue : Color.zoodGreen)
        .disabled(!canContinue)
        Button { choosingInvite = true } label: {
            Label("Invite Someone", systemImage: "square.and.arrow.up").frame(minHeight: 44)
        }
    }

    private var canContinue: Bool {
        !isWorking && !isSelf && ZoodConstants.isValidUsername(handle)
            && (pending != nil || (lookup?.username == handle && lookup?.result != .notFound))
    }

    /// With a link, friends can tap it once to connect. Without it, the invite only points to Amidst.
    private var inviteText: String {
        if inviteWithLink, let link = issuedInviteLink {
            return "Add me on Amidst, private location sharing for family and friends: \(link.absoluteString)"
        }
        return "Let's share our locations privately with Amidst on iPhone or Android: \(FriendLink.homeURL.absoluteString)"
    }

    private func shareInvite(withLink: Bool) {
        inviteWithLink = withLink
        if withLink {
            perform {
                guard let link = try model.issueInviteLink() else { return }
                issuedInviteLink = link
                showingInvite = true
            }
        } else {
            issuedInviteLink = nil
            showingInvite = true
        }
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

    private func goBack() {
        candidate = nil
        errorMessage = nil
    }

    private func send(to user: ZoodUser, sharing: Bool) {
        perform {
            try await model.confirmAddFriend(with: user, sharing: sharing, inviteToken: Username.forLookup(user.username) == invitedUsername ? linkToken : nil)
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
