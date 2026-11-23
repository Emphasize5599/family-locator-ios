import Foundation

/// Integration checks run against the production models and the Android-compatible JSON format.
@main
struct NicknameCompatibilityCheck {
    static func main() throws {
        guard Username.forLookup("  @AlexDemo\n") == "alexdemo",
              Username.forLookup("alexdemo") == "alexdemo" else {
            fatalError("Copied handle cannot be pasted into account lookup")
        }
        let user = ZoodUser(userID: Data(repeating: 2, count: 16), username: "alexdemo", publicKey: Data(repeating: 3, count: 32))
        var friend = Friend(user: user)
        guard friend.displayName == "@alexdemo" else { fatalError("Username fallback failed") }
        friend.sharedNickname = "Alex"
        guard friend.displayName == "Alex" else { fatalError("Shared nickname not displayed") }
        friend.nickname = "Dad"
        friend.sharedNickname = "Alexander"
        guard friend.displayName == "Dad" else { fatalError("Remote profile overwrote private nickname") }
        friend.nickname = Nickname.normalized("  \n ")
        guard friend.displayName == "Alexander" else { fatalError("Clearing override did not restore shared name") }
        friend.sharedNickname = nil
        guard friend.displayName == "@alexdemo" else { fatalError("Clearing profile did not restore username") }

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let legacy = try decoder.decode(UserComm.self, from: Data("{\"type\":\"avatar_request\"}".utf8))
        guard legacy.nickname == nil, legacy.isValid else { fatalError("Legacy client messages changed") }
        let reset = try decoder.decode(UserComm.self, from: Data("{\"type\":\"nickname_update\",\"nickname\":\"\"}".utf8))
        guard reset.nickname == "", reset.isValid else { fatalError("Explicit reset was lost") }
        let malformed = try decoder.decode(UserComm.self, from: Data("{\"type\":\"nickname_update\"}".utf8))
        guard !malformed.isValid else { fatalError("Missing profile accepted as reset") }
        var snapshot = Snapshot()
        snapshot.nickname = "My shared name"
        snapshot.users = [.init(userId: user.id, publicKey: user.publicKey, username: user.username)]
        snapshot.friends = [.init(userId: user.id, nickname: "Private name", sharedNickname: "Their shared name")]
        let json = try encoder.encode(snapshot)
        let restored = try decoder.decode(Snapshot.self, from: json)
        guard restored.schemaVersion == 1, restored.nickname == snapshot.nickname,
              restored.friends.first?.nickname == "Private name",
              restored.friends.first?.sharedNickname == "Their shared name",
              String(decoding: json, as: UTF8.self).contains("shared_nickname") else {
            fatalError("Android-compatible backup round trip failed")
        }
        let oldSnapshot = try decoder.decode(Snapshot.self, from: Data("{\"schema_version\":1,\"timestamp\":0,\"users\":[],\"friends\":[]}".utf8))
        guard oldSnapshot.nickname == nil else { fatalError("Legacy backup rejected") }
        guard oldSnapshot.blocked == nil, oldSnapshot.friends.isEmpty else { fatalError("Legacy backup grew fields") }

        // Blocks and linked contacts ride along in the same backup under snake_case keys that Android's
        // Gson (LOWER_CASE_WITH_UNDERSCORES) reads, and older clients simply ignore.
        var extended = Snapshot()
        extended.users = snapshot.users
        extended.friends = [.init(userId: user.id, linkedContactName: "Alex Rivera",
                                  linkedContactId: "ABC-123", linkedContactPlatform: "ios")]
        extended.blocked = [.init(userId: Data(repeating: 9, count: 16), publicKey: Data(repeating: 8, count: 32), username: "blockeddemo")]
        let extendedJSON = try encoder.encode(extended)
        let text = String(decoding: extendedJSON, as: UTF8.self)
        guard text.contains("\"blocked\""), text.contains("linked_contact_name"),
              text.contains("linked_contact_id"), text.contains("linked_contact_platform") else {
            fatalError("New backup keys aren't the snake_case names Android expects")
        }
        let back = try decoder.decode(Snapshot.self, from: extendedJSON)
        guard back.blocked?.first?.username == "blockeddemo",
              back.friends.first?.linkedContactName == "Alex Rivera",
              back.friends.first?.linkedContactId == "ABC-123",
              back.friends.first?.linkedContactPlatform == "ios" else {
            fatalError("Blocked users or linked contacts lost in the backup round trip")
        }
        // A backup written by Android: the name restores, its lookup URI is for Android only.
        let fromAndroid = try decoder.decode(Snapshot.self, from: Data("""
            {"schema_version":1,"timestamp":0,"users":[],"blocked":[],
             "friends":[{"user_id":"AgICAgICAgICAgICAgICAg==","linked_contact_name":"Mom",
                         "linked_contact_id":"content://com.android.contacts/1","linked_contact_platform":"android"}]}
            """.utf8))
        guard fromAndroid.friends.first?.linkedContactName == "Mom",
              fromAndroid.friends.first?.linkedContactPlatform == "android" else {
            fatalError("Android-written linked contact not readable")
        }
        print("Nickname precedence, explicit resets, legacy messages/backups, shared backup fields, blocked users and linked contacts passed.")
    }
}
