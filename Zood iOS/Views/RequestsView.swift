import SwiftUI

struct RequestsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var error: String?
    @State private var busy = false
    /// A Deny or Block waiting for confirmation.
    @State private var decision: RequestDecision?

    private struct RequestDecision: Identifiable {
        let request: PendingRequest
        let block: Bool
        var id: Data { request.id }
    }

    private var requests: [PendingRequest] {
        model.safety.visibleRequests.sorted { $0.user.username < $1.user.username }
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
                    VStack(alignment: .leading, spacing: Spacing.small) {
                        Label(request.displayName, systemImage: "person.crop.circle")
                            .font(.headline)
                        if request.nickname != nil {
                            // Consent is tied to an account, so show its username even when a shared name exists.
                            Text("@\(request.user.username)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if request.requiresFreshOffer == true {
                            Text("Location will appear only if this person shares again.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: Spacing.tight) {
                            Button { perform { try await model.approveRequest(request) } } label: {
                                Text("Approve")
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.72)
                                    .frame(maxWidth: .infinity, minHeight: 36)
                            }
                            .buttonStyle(.borderedProminent)
                            Button(role: .destructive) { decision = RequestDecision(request: request, block: false) } label: {
                                Text("Deny")
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.72)
                                    .frame(maxWidth: .infinity, minHeight: 36)
                            }
                            .buttonStyle(.bordered)
                            Button(role: .destructive) { decision = RequestDecision(request: request, block: true) } label: {
                                Text("Block")
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.72)
                                    .frame(maxWidth: .infinity, minHeight: 36)
                            }
                            .buttonStyle(.bordered)
                        }
                        .controlSize(.small)
                    }
                    .padding(Spacing.medium)
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
        .alert(decision?.block == true ? "Block this person?" : "Deny this request?",
                            isPresented: Binding(get: { decision != nil }, set: { if !$0 { decision = nil } }),
                            presenting: decision) { decision in
            Button("Cancel", role: .cancel) {}
            if decision.block {
                Button("Block", role: .destructive) { perform { try await model.blockUser(decision.request.user) } }
            } else {
                Button("Deny", role: .destructive) { perform { try model.denyRequest(decision.request) } }
            }
        } message: { decision in
            Text(decision.block
                 ? "\(decision.request.displayName) won't be able to send you requests on this iPhone. You can unblock them in Settings › Account › Blocked Users."
                 : "This dismisses \(decision.request.displayName)'s request. They can send another one later.")
        }
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
    @State private var unblocking = false

    private var users: [ZoodUser] {
        model.safety.blocked.values.sorted { $0.username < $1.username }
    }

    var body: some View {
        List {
            Section {
                if users.isEmpty { Text("No blocked users").foregroundStyle(.secondary) }
                ForEach(users) { user in
                    VStack(alignment: .leading, spacing: Spacing.small) {
                        // Blocked users are always listed by account, never by a nickname.
                        Text("@\(user.username)").font(.headline)
                        Button { selected = user } label: { Text("Unblock").frame(minHeight: 44) }
                            .buttonStyle(.borderless)
                            .disabled(unblocking)
                    }
                }
            } footer: {
                Text("Blocks apply to this account on this iPhone and survive logout. Other Zood apps and devices have their own controls. Unblocking does not restore friendship or share your location. Previously received locations cannot be erased from another person's device.")
            }
            if let error { Text(error).foregroundStyle(Color.zoodRed) }
        }
        .navigationTitle("Blocked Users")
        .alert("Unblock this user?", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Unblock") {
                guard let selected else { return }
                self.selected = nil
                error = nil
                unblocking = true
                Task {
                    defer { unblocking = false }
                    do { try await model.unblockUser(selected) }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
    }
}
