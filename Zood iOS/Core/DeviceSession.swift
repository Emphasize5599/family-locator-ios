import Foundation

/// One device at a time per account, so two phones don't fight over the same backup.
///
/// Zood's servers can't sign other devices out, so this uses the end-to-end encrypted backup both apps
/// already share: a fresh sign-in records itself as the active device there, and every device checks that
/// record when it opens and before it writes a backup. If a newer sign-in happened elsewhere, this device
/// signs itself out locally (nothing on the account is deleted).
///
/// Only fresh sign-ins claim the account, so updating the app never signs anyone out by itself. Stock Zood
/// clients ignore the record. The Android app does the same with the same backup field.
nonisolated enum DeviceSession {
    private static let defaults = UserDefaults.standard

    /// A random ID for this install, kept across sign-ins.
    static var deviceID: String {
        if let id = defaults.string(forKey: "device-session.id") { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "device-session.id")
        return id
    }

    private static func claimKey(_ account: Data) -> String { "device-session.claimed." + account.base64EncodedString() }

    /// When this device signed in (ms), or 0 if it was signed in before this feature existed.
    static func claimedAt(_ account: Data) -> Int64 { Int64(defaults.integer(forKey: claimKey(account))) }

    /// Called right after a fresh sign-in: this device becomes the active one.
    static func claim(_ account: Data) {
        defaults.set(Int(Date().timeIntervalSince1970 * 1000), forKey: claimKey(account))
    }

    static func forget(_ account: Data) { defaults.removeObject(forKey: claimKey(account)) }

    /// True if `remote` says a different device signed in after this one.
    static func isSuperseded(by remote: Snapshot.ActiveDevice?, account: Data) -> Bool {
        guard let remote else { return false }
        return remote.id != deviceID && remote.since > claimedAt(account)
    }

    /// The record to write into an outgoing backup: ours if we claimed, otherwise the one already there.
    static func record(for account: Data, remote: Snapshot.ActiveDevice?) -> Snapshot.ActiveDevice? {
        let since = claimedAt(account)
        return since > 0 ? Snapshot.ActiveDevice(id: deviceID, platform: "ios", since: since) : remote
    }
}
