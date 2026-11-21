import Foundation
import Security

/// Everything needed to act as a logged-in user. Lives in the Keychain, never on disk in the clear.
nonisolated struct Credentials: Codable, Sendable {
    var username: String
    var userID: Data
    var accessToken: String
    var keyPair: KeyPair
    var symmetricKey: Data
    var passwordSalt: Data
}

nonisolated enum CredentialStore {
    private static let service = "com.bensanzone.zood.credentials"
    private static let account = "current"

    static func load() -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    static func save(_ credentials: Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        delete()
        // AfterFirstUnlock so background location wakes can still read the keys while the phone is locked.
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
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

// MARK: - Local data

nonisolated struct ZoodUser: Codable, Hashable, Sendable, Identifiable {
    var userID: Data
    var username: String
    var publicKey: Data
    var id: Data { userID }
}

nonisolated struct FriendLocation: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double
    var time: Date
    var accuracy: Double?
    var speed: Double?
    var bearing: Double?
    var movement: String?
    var batteryLevel: Int?
    var batteryCharging: Bool?
}

/// What we know about the device a friend is using. `nil` fields = never reported (stock Zood).
nonisolated struct FriendDevice: Codable, Hashable, Sendable {
    var platform: Platform?
    var liveRequests: Bool?
    var reportedAt: Date
}

nonisolated struct Friend: Codable, Hashable, Sendable, Identifiable {
    var user: ZoodUser
    /// Box we drop our location into (i.e. we share with them).
    var sendingBoxID: Data?
    /// Box they drop their location into (i.e. they share with us).
    var receivingBoxID: Data?
    var location: FriendLocation?
    var device: FriendDevice?
    var avatar: Data?

    var id: Data { user.userID }
    var weShare: Bool { sendingBoxID != nil }
    var theyShare: Bool { receivingBoxID != nil }
}

nonisolated struct LocalData: Codable, Sendable {
    var users: [Data: ZoodUser] = [:]
    var friends: [Data: Friend] = [:]
    var myAvatar: Data?
    var lastLocationUpload: Date?
}

/// Small JSON file in Application Support, protected until first unlock. Family-sized data, so no database.
nonisolated enum LocalDataStore {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("zood-data.json")
    }

    static func load() -> LocalData {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(LocalData.self, from: data) else { return LocalData() }
        return decoded
    }

    static func save(_ local: LocalData) {
        guard let data = try? JSONEncoder().encode(local) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
