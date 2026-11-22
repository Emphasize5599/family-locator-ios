import Combine
import CoreLocation
import Foundation
import UIKit

/// Requester-side status of a "request location update" for one friend.
enum UpdateRequestStatus: Equatable {
    case sent(Date)
    case responded(UpdateRequestAction, Date)
    case noResponse(Date)

    /// Mirrors george's UpdateStatusTracker: stale statuses stop being shown after two minutes.
    var isStale: Bool {
        let date: Date
        switch self {
        case .sent(let d), .responded(_, let d), .noResponse(let d): date = d
        }
        return Date().timeIntervalSince(date) > 120
    }
}

/// Whether a friend can currently be asked for a fresh location, from our side's point of view.
enum RequestCapability: Equatable {
    case supported
    /// They don't share their location with us, so there's nothing to request.
    case notSharing
    /// Their phone told us it isn't holding a live connection (an iPhone, or the Android fork, with Live Requests off).
    case unsupported(Platform?)
}

/// `ObservableObject` rather than `@Observable` so the app can run on iOS 15.
@MainActor
final class AppModel: ObservableObject {
    enum Phase { case signedOut, signedIn }

    @Published private(set) var phase: Phase
    @Published private(set) var credentials: Credentials?
    @Published private(set) var local = LocalData()
    @Published private(set) var isConnected = false
    @Published private(set) var requestStatuses: [Data: UpdateRequestStatus] = [:]

    let location = LocationService()

    /// User setting: keep a live connection so family can ping this phone.
    @Published var liveRequestsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(liveRequestsEnabled, forKey: Self.liveKey)
            applyLiveMode()
            Task { await shareCurrentLocation() }
        }
    }

    private var socket: OscarSocket?
    private var processedMessageIDs: Set<Int64> = []
    private var backupTask: Task<Void, Never>?
    private var isForeground = true
    private static let liveKey = "liveRequestsEnabled"

    /// Kept out of the published `local` data: it changes on every upload, and republishing everything for it made
    /// open menus and sheets redraw constantly.
    private var lastLocationUpload: Date? {
        get { UserDefaults.standard.object(forKey: "lastLocationUpload") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastLocationUpload") }
    }

    init() {
        UserDefaults.standard.register(defaults: [Self.liveKey: true])
        liveRequestsEnabled = UserDefaults.standard.bool(forKey: Self.liveKey)
        // iOS relaunches us in the background after a significant location change; don't assume we're on screen.
        isForeground = UIApplication.shared.applicationState != .background
        location.setForeground(isForeground)
        if let saved = CredentialStore.load() {
            credentials = saved
            local = LocalDataStore.load()
            phase = .signedIn
        } else {
            phase = .signedOut
        }
        location.onShareableLocation = { [weak self] loc in
            Task { await self?.upload(location: loc) }
        }
        // Views read permission state through the model, so forward LocationService changes.
        location.onStateChange = { [weak self] in
            self?.objectWillChange.send()
            Task { await self?.shareCurrentLocation() }
        }
        if phase == .signedIn { startSession() }
    }

    var api: OscarAPI { OscarAPI(accessToken: credentials?.accessToken) }

    var friends: [Friend] {
        local.friends.values.sorted { $0.user.username < $1.user.username }
    }

    /// The live flag we advertise. Only true if the setting is on *and* iOS will actually let us stay alive.
    var advertisesLiveRequests: Bool {
        // Staying awake in the background needs CLBackgroundActivitySession (iOS 17+). Older iPhones get suspended
        // while stationary, so they honestly report that they can't answer Refresh.
        guard LocationService.supportsBackgroundSession else { return false }
        return liveRequestsEnabled && location.hasAlwaysPermission && location.liveArmed
    }

    /// Whether this iPhone's iOS version can support Live Requests at all.
    var deviceSupportsLiveRequests: Bool { LocationService.supportsBackgroundSession }

    // MARK: - Sign up / log in / log out

    func signUp(username: String, password: String, email: String?) async throws {
        let username = username.trimmingCharacters(in: .whitespaces).lowercased()
        let newUser: NewUser = try await Task.detached(priority: .userInitiated) {
            let keyPair = try Crypto.generateKeyPair()
            let config = PasswordHashConfig.signUpDefault
            let salt = Crypto.randomBytes(PasswordHashConfig.saltLength)
            let passwordHash = try Crypto.stretchPassword(password, salt: salt, config: config)
            let symmetricKey = Crypto.randomBytes(Crypto.symmetricKeyLength)
            let wrappedSymmetric = try Crypto.secretBox(symmetricKey, key: passwordHash)
            let wrappedSecret = try Crypto.secretBox(keyPair.secretKey, key: passwordHash)
            return NewUser(username: username, email: email?.isEmpty == true ? nil : email,
                           publicKey: keyPair.publicKey, passwordSalt: salt,
                           passwordHashAlgorithm: config.algorithm.rawValue,
                           passwordHashOperationsLimit: config.opsLimit, passwordHashMemoryLimit: config.memLimit,
                           wrappedSecretKey: wrappedSecret.cipherText, wrappedSecretKeyNonce: wrappedSecret.nonce,
                           wrappedSymmetricKey: wrappedSymmetric.cipherText, wrappedSymmetricKeyNonce: wrappedSymmetric.nonce)
        }.value
        _ = try await OscarAPI().createUser(newUser)
        try await logIn(username: username, password: password)
    }

    func logIn(username: String, password: String) async throws {
        let username = username.trimmingCharacters(in: .whitespaces).lowercased()
        let anon = OscarAPI()
        let challenge = try await anon.authChallenge(username: username)
        guard let algorithm = PasswordHashConfig.Algorithm(rawValue: challenge.user.passwordHashAlgorithm) else {
            throw LoginError.unsupportedAccount
        }
        let config = PasswordHashConfig(algorithm: algorithm,
                                        opsLimit: challenge.user.passwordHashOperationsLimit,
                                        memLimit: challenge.user.passwordHashMemoryLimit)
        let salt = challenge.user.passwordSalt
        let passwordHash = try await Task.detached(priority: .userInitiated) {
            try Crypto.stretchPassword(password, salt: salt, config: config)
        }.value
        let secretKey: Data
        do {
            secretKey = try Crypto.secretBoxOpen(challenge.user.wrappedSecretKey,
                                                 nonce: challenge.user.wrappedSecretKeyNonce, key: passwordHash)
        } catch {
            throw LoginError.incorrectPassword
        }

        let serverKey = try await anon.serverPublicKey().publicKey
        let finished = FinishedAuthChallenge(
            challenge: try Crypto.box(challenge.challenge, receiverPublicKey: serverKey, senderSecretKey: secretKey),
            creationDate: try Crypto.box(challenge.creationDate, receiverPublicKey: serverKey, senderSecretKey: secretKey))
        let login = try await anon.completeAuthChallenge(username: username, finished)
        let symmetricKey = try Crypto.secretBoxOpen(login.wrappedSymmetricKey, nonce: login.wrappedSymmetricKeyNonce,
                                                    key: passwordHash)

        let creds = Credentials(username: username, userID: login.id, accessToken: login.accessToken,
                                keyPair: KeyPair(publicKey: challenge.user.publicKey, secretKey: secretKey),
                                symmetricKey: symmetricKey, passwordSalt: salt)

        // Restore friends from the encrypted server-side backup (shared format with Android).
        var restored = LocalData()
        let authed = OscarAPI(accessToken: login.accessToken)
        do {
            let encrypted = try await authed.backup()
            let json = try Crypto.secretBoxOpen(encrypted.cipherText, nonce: encrypted.nonce, key: symmetricKey)
            let snapshot = try ZoodJSON.decoder.decode(Snapshot.self, from: json)
            restored = Self.localData(from: snapshot)
        } catch let error as OscarError where error.code == OscarError.backupNotFound {
            // Brand-new account.
        }

        try CredentialStore.save(creds)
        credentials = creds
        local = restored
        LocalDataStore.save(local)
        phase = .signedIn
        startSession()

        // Like Android: ask every friend for their avatar after a fresh login.
        for friend in friends {
            try? await send(UserComm(type: .avatarRequest), to: friend.user, urgent: false, transient: false)
        }
    }

    enum LoginError: LocalizedError {
        case incorrectPassword, unsupportedAccount
        var errorDescription: String? {
            switch self {
            case .incorrectPassword: return "Incorrect password."
            case .unsupportedAccount: return "This account uses a password format this app doesn't support."
            }
        }
    }

    func logOut() {
        socket?.stop()
        socket = nil
        location.stopAll()
        CredentialStore.delete()
        LocalDataStore.delete()
        credentials = nil
        local = LocalData()
        requestStatuses = [:]
        processedMessageIDs = []
        phase = .signedOut
    }

    // MARK: - Session lifecycle

    private func startSession() {
        guard let credentials else { return }
        let socket = OscarSocket(api: OscarAPI(accessToken: credentials.accessToken)) { [weak self] event in
            self?.handle(event)
        }
        self.socket = socket
        for friend in local.friends.values {
            if let box = friend.receivingBoxID { socket.watch(box) }
        }
        socket.start()
        location.startBaseline()
        applyLiveMode()
        Task { await refresh() }
    }

    private func applyLiveMode() {
        location.setLive(phase == .signedIn && liveRequestsEnabled)
    }

    func sceneDidBecomeActive() {
        isForeground = true
        location.setForeground(true)
        guard phase == .signedIn else { return }
        socket?.start()
        applyLiveMode()
        Task { await refresh() }
    }

    func sceneDidEnterBackground() {
        isForeground = false
        location.setForeground(false)
        // Without live mode iOS will suspend us shortly; the socket goes with it and that's expected.
    }

    /// Pull anything we missed while disconnected.
    func refresh() async {
        guard phase == .signedIn else { return }
        if let messages = try? await api.messages() {
            for message in messages { await process(message) }
        }
        for friend in local.friends.values {
            guard let box = friend.receivingBoxID,
                  let pkg = try? await api.pickUpPackage(boxID: box) else { continue }
            await processPackage(pkg, from: friend.user)
        }
    }

    private func handle(_ event: SocketEvent) {
        switch event {
        case .connected:
            isConnected = true
            Task { await refresh() }
        case .disconnected:
            isConnected = false
        case .package(let boxID, let pkg):
            guard let friend = local.friends.values.first(where: { $0.receivingBoxID == boxID }) else { return }
            Task { await processPackage(pkg, from: friend.user) }
        case .message(let message):
            Task { await process(message) }
        case .invalidToken:
            logOut()
        }
    }

    // MARK: - Incoming

    private func process(_ message: InboxMessage) async {
        if message.id != 0 {
            guard processedMessageIDs.insert(message.id).inserted else { return }
        }
        defer {
            if message.id != 0 { Task { try? await api.deleteMessage(id: message.id) } }
        }
        guard let credentials, message.senderId.count == ZoodConstants.userIDLength else { return }

        // Messages from our own account are for the web client's device browser and Android's "scream" feature,
        // neither of which this app supports.
        if message.senderId == credentials.userID { return }
        guard let sender = await user(for: message.senderId),
              let plain = try? Crypto.boxOpen(message.cipherText, nonce: message.nonce,
                                              senderPublicKey: sender.publicKey,
                                              receiverSecretKey: credentials.keyPair.secretKey),
              let comm = try? ZoodJSON.decoder.decode(UserComm.self, from: plain),
              comm.isValid else { return }
        await handle(comm, from: sender)
    }

    private func processPackage(_ pkg: EncryptedData, from user: ZoodUser) async {
        guard let credentials,
              let plain = try? Crypto.boxOpen(pkg.cipherText, nonce: pkg.nonce, senderPublicKey: user.publicKey,
                                              receiverSecretKey: credentials.keyPair.secretKey),
              let comm = try? ZoodJSON.decoder.decode(UserComm.self, from: plain),
              comm.isValid else { return }
        await handle(comm, from: user)
    }

    private func handle(_ comm: UserComm, from user: ZoodUser) async {
        switch comm.type {
        case .locationInfo:
            updateFriend(user.userID) { friend in
                let newTime = Date(timeIntervalSince1970: Double(comm.time ?? 0) / 1000)
                if let existing = friend.location, existing.time > newTime { return }
                friend.location = FriendLocation(
                    latitude: comm.latitude ?? 0, longitude: comm.longitude ?? 0, time: newTime,
                    accuracy: comm.accuracy.map(Double.init), speed: comm.speed.map(Double.init),
                    bearing: comm.bearing.map(Double.init), movement: comm.movement,
                    batteryLevel: comm.batteryLevel, batteryCharging: comm.batteryCharging)
                Self.recordDevice(from: comm, into: &friend)
            }
        case .locationSharingGrant:
            guard let box = comm.dropBox else { return }
            upsertFriend(user) { $0.receivingBoxID = box }
            socket?.watch(box)
            scheduleBackup()
            if let pkg = try? await api.pickUpPackage(boxID: box) { await processPackage(pkg, from: user) }
        case .locationSharingRevocation:
            updateFriend(user.userID) { friend in
                friend.receivingBoxID = nil
                friend.location = nil
            }
            scheduleBackup()
        case .locationUpdateRequest:
            await answerLocationRequest(from: user)
        case .locationUpdateRequestReceived:
            guard let action = comm.locationUpdateRequestAction else { return }
            updateFriend(user.userID) { Self.recordDevice(from: comm, into: &$0) }
            requestStatuses[user.userID] = .responded(action, Date())
        case .avatarRequest:
            guard let avatar = local.myAvatar, local.friends[user.userID]?.weShare == true else { return }
            var update = UserComm(type: .avatarUpdate)
            update.avatar = avatar
            try? await send(update, to: user, urgent: false, transient: false)
        case .avatarUpdate:
            updateFriend(user.userID) { $0.avatar = comm.avatar }
        default:
            break
        }
    }

    private static func recordDevice(from comm: UserComm, into friend: inout Friend) {
        guard comm.platform != nil || comm.liveRequests != nil else { return }
        friend.device = FriendDevice(platform: comm.platform, liveRequests: comm.liveRequests, reportedAt: Date())
    }

    /// Answers a friend's "request location update". Same contract as george's handleLocationUpdateRequest.
    private func answerLocationRequest(from user: ZoodUser) async {
        guard local.friends[user.userID]?.weShare == true else { return }
        guard location.hasAnyPermission else {
            try? await sendRequestResponse(.finished, to: user)
            return
        }
        if !isForeground, let last = lastLocationUpload, Date().timeIntervalSince(last) < 120 {
            try? await sendRequestResponse(.tooSoon, to: user)
            return
        }
        try? await sendRequestResponse(.starting, to: user)
        if let fix = await location.freshFix() {
            await upload(location: fix)
        }
        try? await sendRequestResponse(.finished, to: user)
    }

    private func sendRequestResponse(_ action: UpdateRequestAction, to user: ZoodUser) async throws {
        var comm = UserComm(type: .locationUpdateRequestReceived)
        comm.locationUpdateRequestAction = action
        comm.platform = .ios
        comm.liveRequests = advertisesLiveRequests
        try await send(comm, to: user, urgent: true, transient: true)
    }

    // MARK: - Outgoing

    private func send(_ comm: UserComm, to user: ZoodUser, urgent: Bool, transient: Bool) async throws {
        guard let credentials else { return }
        let encrypted = try Crypto.box(try comm.jsonData(), receiverPublicKey: user.publicKey,
                                       senderSecretKey: credentials.keyPair.secretKey)
        try await api.sendMessage(to: user.userID, OutboundMessage(cipherText: encrypted.cipherText, nonce: encrypted.nonce,
                                                                  urgent: urgent, transient: transient))
    }

    func upload(location loc: CLLocation) async {
        guard let credentials else { return }
        var comm = UserComm(type: .locationInfo)
        comm.latitude = loc.coordinate.latitude
        comm.longitude = loc.coordinate.longitude
        comm.time = Int64(loc.timestamp.timeIntervalSince1970 * 1000)
        if loc.horizontalAccuracy >= 0 { comm.accuracy = Float(loc.horizontalAccuracy) }
        if loc.speed >= 0 { comm.speed = Float(loc.speed) }
        if loc.course > 0 { comm.bearing = Float(loc.course) }
        comm.batteryLevel = Battery.level
        comm.batteryCharging = Battery.isCharging
        comm.platform = .ios
        comm.liveRequests = advertisesLiveRequests
        guard let json = try? comm.jsonData() else { return }

        var packages: [Data: EncryptedData] = [:]
        for friend in local.friends.values {
            guard let box = friend.sendingBoxID,
                  let pkg = try? Crypto.box(json, receiverPublicKey: friend.user.publicKey,
                                            senderSecretKey: credentials.keyPair.secretKey) else { continue }
            packages[box] = pkg
        }
        guard !packages.isEmpty else { return }
        do {
            try await api.dropPackages(packages)
            lastLocationUpload = Date()
        } catch let error as OscarError where error.code == OscarError.invalidAccessToken {
            logOut()
        } catch {
            // Network hiccup; the next location update will try again.
        }
    }

    /// Re-share the latest location now (e.g. after the live setting changed) so friends see the new flag.
    func shareCurrentLocation() async {
        if let loc = location.lastLocation { await upload(location: loc) }
    }

    // MARK: - Friends

    func addFriend(username: String) async throws {
        let username = username.trimmingCharacters(in: .whitespaces).lowercased()
        guard username != credentials?.username else { throw FriendError.cantAddSelf }
        let result = try await api.searchUser(username: username)
        let user = ZoodUser(userID: result.id, username: result.username, publicKey: result.publicKey)
        local.users[user.userID] = user
        try await startSharing(with: user)
    }

    enum FriendError: LocalizedError {
        case cantAddSelf
        var errorDescription: String? { "You can't add yourself." }
    }

    func startSharing(with user: ZoodUser) async throws {
        // Re-send the existing box if we already have one, exactly like FriendshipManager does.
        let box = local.friends[user.userID]?.sendingBoxID ?? Crypto.randomBytes(ZoodConstants.dropBoxIDLength)
        var grant = UserComm(type: .locationSharingGrant)
        grant.dropBox = box
        try await send(grant, to: user, urgent: false, transient: false)
        upsertFriend(user) { $0.sendingBoxID = box }
        scheduleBackup()
        if let avatar = local.myAvatar {
            var update = UserComm(type: .avatarUpdate)
            update.avatar = avatar
            try? await send(update, to: user, urgent: false, transient: false)
        }
        await shareCurrentLocation()
    }

    func stopSharing(with friend: Friend) async {
        updateFriend(friend.id) { $0.sendingBoxID = nil }
        scheduleBackup()
        try? await send(UserComm(type: .locationSharingRevocation), to: friend.user, urgent: false, transient: false)
    }

    func removeFriend(_ friend: Friend) async {
        if friend.weShare { await stopSharing(with: friend) }
        local.friends[friend.id] = nil
        LocalDataStore.save(local)
        scheduleBackup()
    }

    func requestLocationUpdate(from friend: Friend) async {
        requestStatuses[friend.id] = .sent(Date())
        do {
            try await send(UserComm(type: .locationUpdateRequest), to: friend.user, urgent: true, transient: true)
        } catch {
            requestStatuses[friend.id] = .noResponse(Date())
            return
        }
        // Transient requests are only delivered to phones with a live connection. Give them 30 s to answer.
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        if case .sent = requestStatuses[friend.id] {
            requestStatuses[friend.id] = .noResponse(Date())
        }
    }

    func requestCapability(for friend: Friend) -> RequestCapability {
        guard friend.theyShare else { return .notSharing }
        // Same rule as the Android fork: only an explicit "false" is unsupported. Stock Zood never reports.
        if friend.device?.liveRequests == false { return .unsupported(friend.device?.platform) }
        return .supported
    }

    func setMyAvatar(_ jpeg: Data) async {
        local.myAvatar = jpeg
        LocalDataStore.save(local)
        scheduleBackup()
        var update = UserComm(type: .avatarUpdate)
        update.avatar = jpeg
        for friend in friends where friend.weShare {
            try? await send(update, to: friend.user, urgent: false, transient: false)
        }
    }

    // MARK: - Local data helpers

    private func user(for id: Data) async -> ZoodUser? {
        if let known = local.users[id] { return known }
        guard let info = try? await api.user(id: id) else { return nil }
        let user = ZoodUser(userID: id, username: info.username, publicKey: info.publicKey)
        local.users[id] = user
        LocalDataStore.save(local)
        scheduleBackup()
        return user
    }

    private func upsertFriend(_ user: ZoodUser, _ change: (inout Friend) -> Void) {
        local.users[user.userID] = user
        var friend = local.friends[user.userID] ?? Friend(user: user)
        change(&friend)
        local.friends[user.userID] = friend
        LocalDataStore.save(local)
    }

    private func updateFriend(_ id: Data, _ change: (inout Friend) -> Void) {
        guard var friend = local.friends[id] else { return }
        change(&friend)
        local.friends[id] = friend
        LocalDataStore.save(local)
    }

    // MARK: - Backup

    private func scheduleBackup() {
        backupTask?.cancel()
        backupTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await saveBackup()
        }
    }

    private func saveBackup() async {
        guard let credentials else { return }
        var snapshot = Snapshot()
        snapshot.users = local.users.values.map { .init(userId: $0.userID, publicKey: $0.publicKey, username: $0.username) }
        snapshot.friends = local.friends.values.map {
            .init(userId: $0.user.userID, sendingBoxId: $0.sendingBoxID, receivingBoxId: $0.receivingBoxID)
        }
        snapshot.avatar = local.myAvatar
        snapshot.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        guard let json = try? ZoodJSON.encoder.encode(snapshot),
              let encrypted = try? Crypto.secretBox(json, key: credentials.symmetricKey) else { return }
        try? await api.saveBackup(encrypted)
    }

    private static func localData(from snapshot: Snapshot) -> LocalData {
        var data = LocalData()
        for u in snapshot.users {
            data.users[u.userId] = ZoodUser(userID: u.userId, username: u.username, publicKey: u.publicKey)
        }
        for f in snapshot.friends {
            guard let user = data.users[f.userId] else { continue }
            data.friends[f.userId] = Friend(user: user, sendingBoxID: f.sendingBoxId, receivingBoxID: f.receivingBoxId)
        }
        data.myAvatar = snapshot.avatar
        return data
    }
}
