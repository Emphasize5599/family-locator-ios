import Foundation

/// Run on macOS with production Storage/Models/Crypto and the macOS Clibsodium slice.
@main
struct SafetyStateCheck {
    static func main() throws {
        let accountA = Crypto.randomBytes(16)
        let accountB = Crypto.randomBytes(16)
        defer { SafetyStore.delete(for: accountA); SafetyStore.delete(for: accountB) }
        let user = ZoodUser(userID: Crypto.randomBytes(16), username: "safety-test", publicKey: Crypto.randomBytes(32))
        let request = PendingRequest(user: user, boxID: Crypto.randomBytes(16))
        var state = SafetyState()
        state.pending[user.id] = request
        try SafetyStore.save(state, for: accountA)
        guard SafetyStore.load(for: accountA).pending[user.id]?.boxID == request.boxID,
              SafetyStore.load(for: accountB).pending.isEmpty else { fatalError("Pending state was lost or leaked between accounts") }
        state.pending[user.id] = nil
        state.blocked[user.id] = user
        try SafetyStore.save(state, for: accountA)
        let blocked = SafetyStore.load(for: accountA)
        guard blocked.pending.isEmpty, blocked.blocked[user.id] == user,
              SafetyStore.load(for: accountB).blocked.isEmpty else { fatalError("Block persistence or account isolation failed") }
        state.blocked[user.id] = nil
        try SafetyStore.save(state, for: accountA)
        guard SafetyStore.load(for: accountA).blocked.isEmpty else { fatalError("Unblock did not persist") }
        // Older on-disk friend data must still decode after this update.
        _ = try JSONDecoder().decode(LocalData.self, from: Data("{\"users\":[],\"friends\":[]}".utf8))
        print("Pending/block/unblock Keychain round trips, account isolation, and existing local data decoding passed.")
    }
}
