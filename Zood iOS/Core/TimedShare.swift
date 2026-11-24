import Foundation
import Security

/// A running timed share: someone without the app can follow our location from a link until it expires.
/// Same scheme as george's `TimedShareService` and the locationshare.zood.xyz viewer (zood/Lucille):
/// a throwaway keypair + drop box. Locations are boxed to the throwaway public key, and the link carries the
/// throwaway *secret* key in its #fragment (never sent to a server), so only link holders can decrypt.
nonisolated struct TimedShare: Codable, Equatable, Sendable {
    var keyPair: KeyPair
    var boxID: Data
    /// When the share ends.
    var expiresAt: Date
    /// The countdown ring empties from this point (reset whenever the time is changed, like Android).
    var countdownStart: Date

    /// Android starts at 30 m + 30 s so the countdown reads "30m" for a moment instead of "29m".
    static let initialDuration: TimeInterval = 30 * 60 + 30

    var isExpired: Bool { expiresAt <= Date() }

    func remaining(at now: Date = Date()) -> TimeInterval { max(0, expiresAt.timeIntervalSince(now)) }

    /// 1 → full ring, 0 → empty.
    func fractionRemaining(at now: Date = Date()) -> Double {
        let total = expiresAt.timeIntervalSince(countdownStart)
        guard total > 0 else { return 0 }
        return min(1, max(0, remaining(at: now) / total))
    }

    /// `https://locationshare.zood.xyz/#u=<username>&k=<secret hex>&b=<box hex>&i=<user id hex>`
    func url(username: String, userID: Data) -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let user = username.addingPercentEncoding(withAllowedCharacters: allowed) ?? username
        return URL(string: "https://locationshare.zood.xyz/#u=\(user)&k=\(keyPair.secretKey.hexString)&b=\(boxID.hexString)&i=\(userID.hexString)")!
    }

    /// The + button: george's TimedShareFragment steps (5 m under 20 m left, 10 m under an hour, else 1 h).
    static func increased(_ remaining: TimeInterval) -> TimeInterval {
        let minutes = Int(remaining / 60)
        if minutes < 20 { return remaining + 5 * 60 }
        if minutes < 60 { return remaining + 10 * 60 }
        return remaining + 60 * 60
    }

    /// The − button. Returns nil when the share should simply stop (1 minute or less left).
    static func decreased(_ remaining: TimeInterval) -> TimeInterval? {
        let minutes = Int(remaining / 60)
        if minutes <= 1 { return nil }
        if minutes > 120 { return remaining - 60 * 60 }
        if minutes > 60 { return remaining - 30 * 60 }
        if minutes > 20 { return remaining - 10 * 60 }
        if minutes > 10 { return remaining - 5 * 60 }
        return remaining - 60
    }

    /// "1h" / "25m" / "40s", like Android's countdown label.
    static func shortLabel(_ remaining: TimeInterval) -> String {
        let seconds = Int(remaining.rounded(.down))
        if seconds < 1 { return String(localized: "Off") }
        if seconds >= 3600 { return "\(seconds / 3600)h" }
        if seconds >= 60 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }
}

/// The running share lives in the Keychain (it holds a secret key), so it survives the app being relaunched.
/// It's discarded once expired, so a share can never outlive its time even if the app was killed.
nonisolated enum TimedShareStore {
    private static let service = "com.bensanzone.amidst.timed-share"
    private static let account = "current"

    static func load() -> TimedShare? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let share = try? JSONDecoder().decode(TimedShare.self, from: data) else { return nil }
        guard !share.isExpired else {
            delete()
            return nil
        }
        return share
    }

    static func save(_ share: TimedShare) {
        guard let data = try? JSONEncoder().encode(share) else { return }
        delete()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
