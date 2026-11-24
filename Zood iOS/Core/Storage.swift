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
    /// A private name chosen on this account; always wins over the name the friend shares.
    var nickname: String?
    /// Their latest name received inside encrypted messages, never used as an account identifier.
    var sharedNickname: String?
    var linkedContact: LinkedContact?
    var establishedWithoutLocation: Bool? = false

    var displayName: String { nickname ?? linkedContact?.name ?? sharedNickname ?? "@\(user.username)" }
    var avatarName: String { nickname ?? linkedContact?.name ?? sharedNickname ?? user.username }
    /// The picture to show for this friend: their linked contact's photo, otherwise the photo they shared.
    var displayAvatar: Data? { linkedContact?.photo ?? avatar }

    var id: Data { user.userID }
    var weShare: Bool { sendingBoxID != nil }
    var theyShare: Bool { receivingBoxID != nil }
    var acceptsLocationWithoutNewRequest: Bool {
        // Earlier builds saved request-only friendships as friend records with neither box.
        establishedWithoutLocation ?? (sendingBoxID == nil && receivingBoxID == nil)
    }
}

nonisolated struct LocalData: Codable, Sendable {
    var users: [Data: ZoodUser] = [:]
    var friends: [Data: Friend] = [:]
    var myNickname: String?
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
        #if DEBUG
        guard ProcessInfo.processInfo.environment["ZOOD_SCREENSHOT_TOUR"] == nil else { return }
        #endif
        guard let data = try? JSONEncoder().encode(local) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}

// Pending offers stay on this device. Blocks also travel in the encrypted account backup.
nonisolated struct PendingRequest: Codable, Identifiable, Sendable {
    var user: ZoodUser
    var boxID: Data
    var nickname: String?
    var avatar: Data?
    var requiresFreshOffer: Bool?
    var freshOfferAfter: Int64?
    var approved: Bool?
    var id: Data { user.userID }
    var includesLocation: Bool { boxID.count == ZoodConstants.dropBoxIDLength && requiresFreshOffer != true }
    /// Their shared nickname if they sent one, otherwise "@username".
    var displayName: String { nickname ?? "@\(user.username)" }
}

nonisolated struct SafetyState: Codable, Sendable {
    var pending: [Data: PendingRequest] = [:]
    var blocked: [Data: ZoodUser] = [:]
    /// A false entry awaits delivery. Existing blocks without an entry are repaired on unblock.
    var sentBlockRemovals: [Data: Bool]?

    var visibleRequests: [PendingRequest] {
        pending.values.filter { blocked[$0.id] == nil && $0.approved != true }
    }
}

nonisolated enum SafetyStore {
    private static let service = "com.bensanzone.zood.safety"

    static func load(for userID: Data) -> SafetyState {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: userID.base64EncodedString(),
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let state = try? JSONDecoder().decode(SafetyState.self, from: data) else { return SafetyState() }
        return state
    }

    static func save(_ state: SafetyState, for userID: Data) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: userID.base64EncodedString()]
        let data = try JSONEncoder().encode(state)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(attributes as CFDictionary, nil)
            guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func delete(for userID: Data) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: userID.base64EncodedString()] as CFDictionary)
    }
}

/// Names are presentation only; account lookup and safety numbers always use the immutable username.
nonisolated enum Nickname {
    static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = String(value.unicodeScalars.filter { $0.properties.generalCategory != .control })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : String(clean.prefix(64))
    }
}

/// Displayed @handles must paste back into account lookup without changing the server's account identity.
nonisolated enum Username {
    static func forLookup(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed).lowercased()
    }
}

/// Only the selected contact's name and identifier are retained, on this device and in the end-to-end
/// encrypted backup (the server can't read either). Never sent to the friend.
nonisolated struct LinkedContact: Codable, Hashable, Sendable {
    var identifier: String
    /// First and last name from the contact card (company name for business cards).
    var name: String
    /// The contact's photo as framed in Contacts (its thumbnail), shown as the friend's avatar. Kept on this
    /// iPhone only (not in the backup), so the backup stays small; it returns when the friend is linked again.
    var photo: Data?
}

nonisolated enum ContactLinkStore {
    private static func key(for account: Data) -> String {
        "linked-contacts." + account.base64EncodedString()
    }

    static func load(for account: Data) -> [Data: LinkedContact] {
        guard let data = UserDefaults.standard.data(forKey: key(for: account)) else { return [:] }
        return (try? JSONDecoder().decode([Data: LinkedContact].self, from: data)) ?? [:]
    }

    static func save(_ links: [Data: LinkedContact], for account: Data) {
        guard let data = try? JSONEncoder().encode(links) else { return }
        UserDefaults.standard.set(data, forKey: key(for: account))
    }

    static func delete(for account: Data) {
        UserDefaults.standard.removeObject(forKey: key(for: account))
    }
}
