import SwiftUI

struct RequestsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var error: String?
    @State private var busy = false

    private var requests: [PendingRequest] {
        model.safety.pending.values.sorted { $0.user.username < $1.user.username }
    }

    var body: some View {
        ContentFittedSheet(title: "Pending Requests") {
            VStack(alignment: .leading, spacing: Spacing.large) {
                Text("Approve people before their location and profile photo appear. Approving does not share your location back.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if requests.isEmpty {
                    Label("No pending requests", systemImage: "bell")
                        .padding(Spacing.large)
                        .frame(maxWidth: .infinity)
                }
                ForEach(requests) { request in
                    VStack(alignment: .leading, spacing: Spacing.large) {
                        Label(request.nickname ?? "@\(request.user.username)", systemImage: "person.crop.circle")
                            .font(.headline)
                        if request.nickname != nil {
                            // Consent is tied to an account, so show its username even when a shared name exists.
                            Text("@\(request.user.username)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text("Wants to share their location with you.")
                        Button { perform { try await model.approveRequest(request) } } label: { Text("Approve").frame(maxWidth: .infinity, minHeight: 44) }
                            .buttonStyle(.borderedProminent)
                        HStack {
                            Button(role: .destructive) { perform { try model.denyRequest(request) } } label: { Text("Deny").frame(minWidth: 44, minHeight: 44) }
                            Spacer()
                            Button(role: .destructive) { perform { try await model.blockUser(request.user) } } label: { Text("Block").frame(minWidth: 44, minHeight: 44) }
                        }
                    }
                    .padding(Spacing.large)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                }
                if !requests.isEmpty {
                    Text("Deny dismisses this request. Block also prevents future requests from this person on this iPhone.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(Color.zoodRed) }
            }
            .disabled(busy)
        }
        .task { await model.refresh() }
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
}

struct BlockedUsersView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selected: ZoodUser?
    @State private var error: String?

    private var users: [ZoodUser] {
        model.safety.blocked.values.sorted { $0.username < $1.username }
    }

    var body: some View {
        List {
            Section {
                if users.isEmpty { Text("No blocked users").foregroundStyle(.secondary) }
                ForEach(users) { user in
                    VStack(alignment: .leading, spacing: Spacing.small) {
                        Text(user.username).font(.headline)
                        Button { selected = user } label: { Text("Unblock").frame(minHeight: 44) }
                            .buttonStyle(.borderless)
                    }
                }
            } footer: {
                Text("Blocks apply to this account on this iPhone and survive logout. Other Zood apps and devices have their own controls. Unblocking does not restore friendship or share your location. Previously received locations cannot be erased from another person's device.")
            }
            if let error { Text(error).foregroundStyle(Color.zoodRed) }
        }
        .navigationTitle("Blocked Users")
        .confirmationDialog("Unblock this user?", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), titleVisibility: .visible) {
            Button("Unblock") {
                guard let selected else { return }
                do { try model.unblockUser(selected) } catch { self.error = error.localizedDescription }
                self.selected = nil
            }
        }
    }
}
