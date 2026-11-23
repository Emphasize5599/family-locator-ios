import Foundation

// MARK: - JSON coding

/// Zood speaks snake_case JSON with standard base64 for binary fields (matches george's Gson config).
nonisolated enum ZoodJSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dataEncodingStrategy = .base64
        // oscar's encodable.Bytes decodes the raw JSON token without unescaping, so base64's "/" must not
        // be written as "\/" (JSONEncoder's default). Gson in george doesn't escape it either.
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dataDecodingStrategy = .base64
        return d
    }()
}

// MARK: - REST payloads

nonisolated struct NewUser: Encodable, Sendable {
    var username: String
    var email: String?
    var publicKey: Data
    var passwordSalt: Data
    var passwordHashAlgorithm: String
    var passwordHashOperationsLimit: UInt64
    var passwordHashMemoryLimit: UInt64
    var wrappedSecretKey: Data
    var wrappedSecretKeyNonce: Data
    var wrappedSymmetricKey: Data
    var wrappedSymmetricKeyNonce: Data
}

nonisolated struct CreateUserResponse: Decodable, Sendable {
    var id: Data
}

nonisolated struct AuthChallenge: Decodable, Sendable {
    struct User: Decodable, Sendable {
        var publicKey: Data
        var wrappedSecretKey: Data
        var wrappedSecretKeyNonce: Data
        var passwordSalt: Data
        var passwordHashAlgorithm: String
        var passwordHashOperationsLimit: UInt64
        var passwordHashMemoryLimit: UInt64
    }
    var user: User
    var challenge: Data
    var creationDate: Data
}

nonisolated struct FinishedAuthChallenge: Encodable, Sendable {
    var challenge: EncryptedData
    var creationDate: EncryptedData
}

nonisolated struct LoginResponse: Decodable, Sendable {
    var id: Data
    var accessToken: String
    var wrappedSymmetricKey: Data
    var wrappedSymmetricKeyNonce: Data
}

nonisolated struct ServerPublicKey: Decodable, Sendable {
    var publicKey: Data
}

nonisolated struct PublicUserInfo: Decodable, Sendable {
    var username: String
    var publicKey: Data
}

nonisolated struct UserSearchResult: Decodable, Sendable {
    var id: Data
    var username: String
    var publicKey: Data
}

nonisolated struct InboxMessage: Decodable, Sendable {
    var id: Int64
    var senderId: Data
    var cipherText: Data
    var nonce: Data
    var sentDate: Int64?
}

nonisolated struct OutboundMessage: Encodable, Sendable {
    var cipherText: Data
    var nonce: Data
    var urgent: Bool
    var transient: Bool
}

nonisolated struct SessionTicket: Decodable, Sendable {
    var ticket: String
}

nonisolated struct OscarErrorBody: Decodable, Sendable {
    var errorCode: Int
    var errorMessage: String?
}

/// Encrypted backup of the user's social graph. Field-for-field compatible with george's `Snapshot`.
nonisolated struct Snapshot: Codable, Sendable {
    struct Friend: Codable, Sendable {
        var userId: Data
        var sendingBoxId: Data?
        var receivingBoxId: Data?
        var nickname: String?
        var sharedNickname: String?
        /// The phone contact this friend is linked to (Family Locator only; stock Zood ignores these keys).
        /// The name restores on any device; the id is a Contacts identifier on iOS or a lookup URI on
        /// Android, so it's only reused on the same platform (`linkedContactPlatform`).
        var linkedContactName: String?
        var linkedContactId: String?
        var linkedContactPlatform: String?
    }
    struct User: Codable, Sendable {
        var userId: Data
        var publicKey: Data
        var username: String
    }
    var friends: [Friend] = []
    var users: [User] = []
    /// People you've blocked (Family Locator only; older clients ignore it). Optional so older backups,
    /// which don't have it, still decode.
    var blocked: [User]?
    /// Friend-bar folders and the bar's order (Family Locator only; older clients ignore them).
    struct Folder: Codable, Sendable {
        var id: String
        var name: String?
        var members: [Data]
    }
    var folders: [Folder]?
    /// Bar entries in order: "friend:<base64 user id>" or "folder:<folder id>".
    var barOrder: [String]?
    /// The device the account was most recently signed in on (see DeviceSession). Shared with Android.
    struct ActiveDevice: Codable, Sendable, Equatable {
        var id: String
        var platform: String
        var since: Int64
    }
    var activeDevice: ActiveDevice?
    var avatar: Data?
    var nickname: String?
    /// Android refuses to restore snapshots newer than its DB schema (1).
    var schemaVersion: Int = 1
    var timestamp: Int64 = 0
}

// MARK: - UserComm (plaintext of every message and drop-box package)

nonisolated enum Platform: String, Codable, Sendable {
    case ios
    case android
}

nonisolated enum CommType: String, Sendable {
    case avatarRequest = "avatar_request"
    case avatarUpdate = "avatar_update"
    case browseDevices = "browse_devices"
    case debug
    case deviceInfo = "device_info"
    case locationInfo = "location_info"
    case locationSharingGrant = "location_sharing_grant"
    case locationUpdateRequest = "location_update_request"
    case locationUpdateRequestReceived = "location_update_request_received"
    case locationSharingRevocation = "location_sharing_revocation"
    case scream
    case screamBegan = "scream_began"
    // Fork extension: "can you answer location requests right now?" and the reply. Carries no location.
    case deviceStatusRequest = "device_status_request"
    case deviceStatus = "device_status"
    case nicknameUpdate = "nickname_update"
    case unknown
}

nonisolated enum UpdateRequestAction: String, Codable, Sendable {
    case starting
    case tooSoon = "too_soon"
    case finished
}

nonisolated struct UserComm: Codable, Sendable {
    var type: CommType
    var dropBox: Data?
    var avatar: Data?
    var latitude: Double?
    var longitude: Double?
    /// Milliseconds since 1970.
    var time: Int64?
    var accuracy: Float?
    var speed: Float?
    var bearing: Float?
    var movement: String?
    var batteryLevel: Int?
    var batteryCharging: Bool?
    var locationUpdateRequestAction: UpdateRequestAction?
    var debugData: String?

    // Fork extension: stock Zood ignores these, our iOS and Android forks read them.
    var platform: Platform?
    var liveRequests: Bool?
    /// Empty string explicitly clears a shared nickname; absent means an older sender.
    var nickname: String?
    /// A two-way removal carried in a revocation so older clients still stop receiving locations.
    var friendRemoved: Bool?

    init(type: CommType) {
        self.type = type
    }

    enum CodingKeys: String, CodingKey {
        case type, dropBox, avatar, latitude, longitude, time, accuracy, speed, bearing, movement
        case batteryLevel, batteryCharging, locationUpdateRequestAction, debugData, platform, liveRequests, nickname, friendRemoved
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = CommType(rawValue: (try? c.decode(String.self, forKey: .type)) ?? "") ?? .unknown
        dropBox = try? c.decodeIfPresent(Data.self, forKey: .dropBox)
        avatar = try? c.decodeIfPresent(Data.self, forKey: .avatar)
        latitude = try? c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try? c.decodeIfPresent(Double.self, forKey: .longitude)
        time = try? c.decodeIfPresent(Int64.self, forKey: .time)
        accuracy = try? c.decodeIfPresent(Float.self, forKey: .accuracy)
        speed = try? c.decodeIfPresent(Float.self, forKey: .speed)
        bearing = try? c.decodeIfPresent(Float.self, forKey: .bearing)
        movement = try? c.decodeIfPresent(String.self, forKey: .movement)
        batteryLevel = try? c.decodeIfPresent(Int.self, forKey: .batteryLevel)
        batteryCharging = try? c.decodeIfPresent(Bool.self, forKey: .batteryCharging)
        locationUpdateRequestAction = try? c.decodeIfPresent(UpdateRequestAction.self, forKey: .locationUpdateRequestAction)
        debugData = try? c.decodeIfPresent(String.self, forKey: .debugData)
        platform = try? c.decodeIfPresent(Platform.self, forKey: .platform)
        nickname = try? c.decodeIfPresent(String.self, forKey: .nickname)
        friendRemoved = try? c.decodeIfPresent(Bool.self, forKey: .friendRemoved)
        liveRequests = try? c.decodeIfPresent(Bool.self, forKey: .liveRequests)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type.rawValue, forKey: .type)
        try c.encodeIfPresent(dropBox, forKey: .dropBox)
        try c.encodeIfPresent(avatar, forKey: .avatar)
        try c.encodeIfPresent(latitude, forKey: .latitude)
        try c.encodeIfPresent(longitude, forKey: .longitude)
        try c.encodeIfPresent(time, forKey: .time)
        try c.encodeIfPresent(accuracy, forKey: .accuracy)
        try c.encodeIfPresent(speed, forKey: .speed)
        try c.encodeIfPresent(bearing, forKey: .bearing)
        try c.encodeIfPresent(movement, forKey: .movement)
        try c.encodeIfPresent(batteryLevel, forKey: .batteryLevel)
        try c.encodeIfPresent(batteryCharging, forKey: .batteryCharging)
        try c.encodeIfPresent(locationUpdateRequestAction, forKey: .locationUpdateRequestAction)
        try c.encodeIfPresent(debugData, forKey: .debugData)
        try c.encodeIfPresent(platform, forKey: .platform)
        try c.encodeIfPresent(liveRequests, forKey: .liveRequests)
        try c.encodeIfPresent(nickname, forKey: .nickname)
        try c.encodeIfPresent(friendRemoved, forKey: .friendRemoved)
    }

    /// Same validity rules george applies in `UserComm.isValid()`.
    var isValid: Bool {
        switch type {
        case .avatarUpdate: return avatar != nil
        case .locationSharingGrant: return dropBox?.count == ZoodConstants.dropBoxIDLength
        case .locationInfo:
            guard let lat = latitude, let lng = longitude, let t = time else { return false }
            if let b = batteryLevel, !(-1...100).contains(b) { return false }
            return (-90...90).contains(lat) && (-180...180).contains(lng) && t > 0
        case .locationUpdateRequestReceived: return locationUpdateRequestAction != nil
        case .nicknameUpdate: return nickname != nil
        case .unknown: return false
        default: return true
        }
    }

    func jsonData() throws -> Data { try ZoodJSON.encoder.encode(self) }
}

nonisolated enum ZoodConstants {
    static let dropBoxIDLength = 16
    static let userIDLength = 16
    static let minimumPasswordLength = 6
    /// Server rule: `^[a-z0-9]{5,}$`, max 32.
    static func isValidUsername(_ s: String) -> Bool {
        s.count >= 5 && s.count <= 32 && s.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }
}
