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
        let ordinaryRevocation = try ZoodJSON.decoder.decode(UserComm.self, from: Data(#"{"type":"location_sharing_revocation"}"#.utf8))
        let fullRemoval = try ZoodJSON.decoder.decode(UserComm.self, from: Data(#"{"type":"location_sharing_revocation","friend_removed":true}"#.utf8))
        guard ordinaryRevocation.type == .locationSharingRevocation, ordinaryRevocation.friendRemoved == nil,
              fullRemoval.type == .locationSharingRevocation, fullRemoval.friendRemoved == true,
              String(decoding: try fullRemoval.jsonData(), as: UTF8.self).contains("\"friend_removed\"") else {
            fatalError("Sharing revocation and friendship removal must remain distinct")
        }
        let offer = Data(repeating: 4, count: ZoodConstants.dropBoxIDLength)
        var returnGrant = UserComm(type: .locationSharingGrant)
        returnGrant.dropBox = Data(repeating: 5, count: ZoodConstants.dropBoxIDLength)
        returnGrant.replyToBox = offer
        let grantJSON = try returnGrant.jsonData()
        let decodedGrant = try ZoodJSON.decoder.decode(UserComm.self, from: grantJSON)
        guard String(decoding: grantJSON, as: UTF8.self).contains("\"reply_to_box\""),
              decodedGrant.repliesToSharingOffer(on: offer),
              !decodedGrant.repliesToSharingOffer(on: nil),
              !decodedGrant.repliesToSharingOffer(on: returnGrant.dropBox) else {
            fatalError("Return grants must match the active offer")
        }
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
        // Folders and the bar's order.
        var arranged = Snapshot()
        let folderID = UUID()
        arranged.folders = [.init(id: folderID.uuidString, name: "Family", members: [user.id])]
        arranged.barOrder = ["folder:" + folderID.uuidString, "friend:" + user.id.base64EncodedString()]
        let arrangedJSON = try encoder.encode(arranged)
        guard String(decoding: arrangedJSON, as: UTF8.self).contains("bar_order") else { fatalError("bar_order key missing") }
        let arrangedBack = try decoder.decode(Snapshot.self, from: arrangedJSON)
        guard arrangedBack.folders?.first?.name == "Family", arrangedBack.folders?.first?.members == [user.id],
              arrangedBack.barOrder?.count == 2 else {
            fatalError("Folders or bar order lost in the backup round trip")
        }
        // Cross-platform: write a full iPhone backup for Android's test to read, and read Android's if given.
        var full = Snapshot()
        let friendID = Data(repeating: 2, count: 16)
        full.nickname = "Ben"
        full.avatar = Data([0xFF, 0xD8, 0xFF])
        full.users = [.init(userId: friendID, publicKey: Data(repeating: 3, count: 32), username: "alexdemo")]
        full.friends = [.init(userId: friendID, sendingBoxId: Data(repeating: 4, count: 32), receivingBoxId: Data(repeating: 5, count: 32),
                              nickname: "Dad", sharedNickname: "Alex", linkedContactName: "Alex Rivera",
                              linkedContactId: "ABC-123", linkedContactPlatform: "ios")]
        full.blocked = [.init(userId: Data(repeating: 9, count: 16), publicKey: Data(repeating: 8, count: 32), username: "blockeddemo")]
        let fullFolderID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        full.folders = [.init(id: fullFolderID.uuidString, name: "Family", members: [friendID])]
        full.barOrder = ["folder:" + fullFolderID.uuidString]
        full.activeDevice = .init(id: "ios-device", platform: "ios", since: 1_700_000_000_000)
        full.timestamp = 1_700_000_000_000
        let args = CommandLine.arguments
        if args.count > 1 {
            try ZoodJSON.encoder.encode(full).write(to: URL(fileURLWithPath: args[1]))  // the app's real encoder
        }
        if args.count > 2 {
            let android = try ZoodJSON.decoder.decode(Snapshot.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
            guard android.nickname == "Ana", android.avatar == Data([0x89, 0x50]),
                  android.users.first?.username == "momdemo",
                  android.friends.first?.nickname == "Mom", android.friends.first?.sharedNickname == "Maria",
                  android.friends.first?.sendingBoxId == Data(repeating: 6, count: 32),
                  android.friends.first?.linkedContactName == "Maria Lopez",
                  android.friends.first?.linkedContactPlatform == "android",
                  android.blocked?.first?.username == "blockedandroid",
                  android.folders?.first?.name == "Kids", android.folders?.first?.members.count == 1,
                  android.barOrder?.count == 2,
                  android.activeDevice == .init(id: "android-device", platform: "android", since: 1_800_000_000_000) else {
                fatalError("An Android-written backup didn't restore every field on iPhone")
            }
            print("Android-written backup: every field read correctly on iPhone.")
        }
        print("Nickname precedence, explicit resets, legacy messages/backups, shared backup fields, blocked users, linked contacts, folders and bar order passed.")
    }
}
