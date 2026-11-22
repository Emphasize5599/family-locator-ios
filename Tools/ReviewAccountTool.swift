import Foundation

struct ReviewAccount: Codable {
    var username: String
    var password: String
    var userID: Data
    var keyPair: KeyPair
    var symmetricKey: Data
}

struct ReviewAccounts: Codable {
    var reviewer: ReviewAccount
    var sample: ReviewAccount
    var boxID: Data
}

@main
struct ReviewSetup {
    static func authenticate(_ account: ReviewAccount) async throws -> OscarAPI {
        let anon = OscarAPI()
        let challenge = try await anon.authChallenge(username: account.username)
        guard let algorithm = PasswordHashConfig.Algorithm(rawValue: challenge.user.passwordHashAlgorithm) else {
            throw OscarError.invalidResponse
        }
        let config = PasswordHashConfig(algorithm: algorithm, opsLimit: challenge.user.passwordHashOperationsLimit,
                                        memLimit: challenge.user.passwordHashMemoryLimit)
        let hash = try Crypto.stretchPassword(account.password, salt: challenge.user.passwordSalt, config: config)
        let secret = try Crypto.secretBoxOpen(challenge.user.wrappedSecretKey, nonce: challenge.user.wrappedSecretKeyNonce, key: hash)
        let serverKey = try await anon.serverPublicKey().publicKey
        let finished = FinishedAuthChallenge(
            challenge: try Crypto.box(challenge.challenge, receiverPublicKey: serverKey, senderSecretKey: secret),
            creationDate: try Crypto.box(challenge.creationDate, receiverPublicKey: serverKey, senderSecretKey: secret))
        let login = try await anon.completeAuthChallenge(username: account.username, finished)
        let symmetric = try Crypto.secretBoxOpen(login.wrappedSymmetricKey, nonce: login.wrappedSymmetricKeyNonce, key: hash)
        guard login.id == account.userID, symmetric == account.symmetricKey else { throw OscarError.invalidResponse }
        return OscarAPI(accessToken: login.accessToken)
    }

    static func create(prefix: String) async throws -> ReviewAccount {
        let username = prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased()
        let password = Crypto.randomBytes(18).hexString
        let pair = try Crypto.generateKeyPair()
        let config = PasswordHashConfig.signUpDefault
        let salt = Crypto.randomBytes(PasswordHashConfig.saltLength)
        let hash = try Crypto.stretchPassword(password, salt: salt, config: config)
        let symmetric = Crypto.randomBytes(Crypto.symmetricKeyLength)
        let wrappedSymmetric = try Crypto.secretBox(symmetric, key: hash)
        let wrappedSecret = try Crypto.secretBox(pair.secretKey, key: hash)
        let user = NewUser(username: username, email: nil, publicKey: pair.publicKey, passwordSalt: salt,
                           passwordHashAlgorithm: config.algorithm.rawValue, passwordHashOperationsLimit: config.opsLimit,
                           passwordHashMemoryLimit: config.memLimit, wrappedSecretKey: wrappedSecret.cipherText,
                           wrappedSecretKeyNonce: wrappedSecret.nonce, wrappedSymmetricKey: wrappedSymmetric.cipherText,
                           wrappedSymmetricKeyNonce: wrappedSymmetric.nonce)
        let created = try await OscarAPI().createUser(user)
        return ReviewAccount(username: username, password: password, userID: created.id, keyPair: pair, symmetricKey: symmetric)
    }

    static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let stateURL = directory.appendingPathComponent("review-accounts.json")
        let accounts: ReviewAccounts
        if FileManager.default.fileExists(atPath: stateURL.path) {
            accounts = try JSONDecoder().decode(ReviewAccounts.self, from: Data(contentsOf: stateURL))
        } else {
            let reviewer = try await create(prefix: "flreview")
            // Save each generated account immediately so interrupted setup does not lose credentials.
            try writePrivate(JSONEncoder().encode(reviewer), to: directory.appendingPathComponent("reviewer-recovery.json"))
            let sample = try await create(prefix: "flsample")
            accounts = ReviewAccounts(reviewer: reviewer, sample: sample, boxID: Crypto.randomBytes(ZoodConstants.dropBoxIDLength))
            try writePrivate(JSONEncoder().encode(accounts), to: stateURL)
        }
        let reviewerAPI = try await authenticate(accounts.reviewer)
        let sampleAPI = try await authenticate(accounts.sample)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var reviewerBackup = Snapshot()
        reviewerBackup.users = [.init(userId: accounts.sample.userID, publicKey: accounts.sample.keyPair.publicKey, username: accounts.sample.username)]
        reviewerBackup.friends = [.init(userId: accounts.sample.userID, sendingBoxId: nil, receivingBoxId: accounts.boxID)]
        reviewerBackup.timestamp = now
        try await reviewerAPI.saveBackup(Crypto.secretBox(ZoodJSON.encoder.encode(reviewerBackup), key: accounts.reviewer.symmetricKey))
        var sampleBackup = Snapshot()
        sampleBackup.users = [.init(userId: accounts.reviewer.userID, publicKey: accounts.reviewer.keyPair.publicKey, username: accounts.reviewer.username)]
        sampleBackup.friends = [.init(userId: accounts.reviewer.userID, sendingBoxId: accounts.boxID, receivingBoxId: nil)]
        sampleBackup.timestamp = now
        try await sampleAPI.saveBackup(Crypto.secretBox(ZoodJSON.encoder.encode(sampleBackup), key: accounts.sample.symmetricKey))
        var location = UserComm(type: .locationInfo)
        // Explicit sample data: a public landmark, never a real person's live location.
        location.latitude = 37.8199
        location.longitude = -122.4783
        location.time = now
        location.accuracy = 25
        location.platform = .ios
        location.liveRequests = false
        try await sampleAPI.dropPackages([accounts.boxID: Crypto.box(location.jsonData(), receiverPublicKey: accounts.reviewer.keyPair.publicKey,
                                                                    senderSecretKey: accounts.sample.keyPair.secretKey)])
        // Verify a fresh challenge/login, restored backup, and decrypted location package using production APIs.
        let freshAPI = try await authenticate(accounts.reviewer)
        let backup = try await freshAPI.backup()
        let restored = try ZoodJSON.decoder.decode(Snapshot.self, from: Crypto.secretBoxOpen(backup.cipherText, nonce: backup.nonce,
                                                                                          key: accounts.reviewer.symmetricKey))
        guard restored.friends.first?.receivingBoxId == accounts.boxID,
              let package = try await freshAPI.pickUpPackage(boxID: accounts.boxID) else { throw OscarError.invalidResponse }
        let plain = try Crypto.boxOpen(package.cipherText, nonce: package.nonce, senderPublicKey: accounts.sample.keyPair.publicKey,
                                        receiverSecretKey: accounts.reviewer.keyPair.secretKey)
        let fix = try ZoodJSON.decoder.decode(UserComm.self, from: plain)
        guard fix.isValid, fix.latitude == location.latitude else { throw OscarError.invalidResponse }
        let deletionRecord = directory.appendingPathComponent("deletion-check.json")
        if !FileManager.default.fileExists(atPath: deletionRecord.path) {
            let disposable = try await create(prefix: "flremove")
            try writePrivate(JSONEncoder().encode(disposable), to: directory.appendingPathComponent("deletion-recovery.json"))
            let api = try await authenticate(disposable)
            try await api.saveBackup(Crypto.secretBox(ZoodJSON.encoder.encode(Snapshot()), key: disposable.symmetricKey))
            try await api.deleteAccount()
            do {
                _ = try await authenticate(disposable)
                throw NSError(domain: "ReviewVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: "Deleted account can still authenticate"])
            } catch let error as OscarError {
                guard error.code == OscarError.userNotFound else { throw error }
            }
            try writePrivate(Data("{\"accountDeletionVerified\":true}".utf8), to: deletionRecord)
        }
        let credentials = """
        # Private App Review credentials

        Verified against api.zood.xyz on \(Date().ISO8601Format()). No email, OTP, purchase, or 2FA is required.

        Reviewer username: \(accounts.reviewer.username)
        Reviewer password: \(accounts.reviewer.password)

        Companion username: \(accounts.sample.username)
        Companion password: \(accounts.sample.password)

        The reviewer account has one receiving-only sample friend at the Golden Gate Bridge. This is labeled sample data in the review notes; it is not a live person. The reviewer account does not share its own location with that friend by default.

        Use the companion account on a second device to test real sharing and Refresh. Both devices must stay online with the required location permissions and Live Requests enabled. Without a companion device running, the saved sample location remains available, but Refresh is unsupported.

        Enter the reviewer credentials only into App Store Connect's private review fields. Do not publish them or commit this folder. If a reviewer deletes the account, rerun setup with a new private state folder before the next submission. Rerunning with the same folder resets the sample fixtures; do not do that during an active review.
        """
        try writePrivate(Data(credentials.utf8), to: directory.appendingPathComponent("APP_REVIEW_CREDENTIALS.md"))
        print("Verified reviewer and companion logins, encrypted friend backup restoration, sample location decryption, and disposable-account deletion. Credentials saved privately.")
    }
}
