import Combine
import CoreLocation
import Foundation
import UIKit

/// Requester-side status of a "request location update" for one friend.
enum UpdateRequestStatus: Equatable {
    case sent(Date)
    case responded(UpdateRequestAction, Date)
    case noResponse(Date)

    /// A newer fix satisfies a pending refresh even when it was sent independently of the request.
    func receivingLocation(at time: Date, previousTime: Date?) -> Self {
        if let previousTime, time <= previousTime { return self }
        switch self {
        case .sent, .responded(.starting, _):
            return .responded(.finished, Date())
        default:
            return self
        }
    }

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
    /// Their last report said they couldn't answer, and we're asking their phone again before saying so.
    case checking
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
    @Published private(set) var safety = SafetyState()
    @Published var safetyError: String?
    @Published private(set) var requestStatuses: [Data: UpdateRequestStatus] = [:]
    /// Friend-bar folders (see FriendFolders.swift). Saved on this iPhone per account.
    @Published private(set) var folders: [FriendFolder] = []
    /// The order of the friend bar after Add and Requests (see `barItems`). Saved on this iPhone per account.
    @Published private(set) var barOrder: [BarItemID] = []
    /// Set when this iPhone signed itself out because the account was signed in on another device.
    @Published var signedOutElsewhere = false
    /// The running timed share, if any (see `TimedShare`).
    @Published private(set) var timedShare: TimedShare?
    /// Friends whose phones we're asking "can you answer location requests?" before showing Unsupported.
    @Published private(set) var probingDevices: Set<Data> = []
    private var lastProbe: [Data: Date] = [:]
    @Published private var unavailableUntil: [Data: Date] = [:]
    private var inboxPoll: Task<Void, Never>?
    private var inboxSync: Task<Bool, Never>?
    private var inboxSyncID: UUID?
    private var inboxChanged = false
    private var timedShareExpiry: Task<Void, Never>?

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
        #if DEBUG
        if ScreenshotTour.isEnabled {
            phase = .signedIn
            credentials = ScreenshotTour.credentials
            local.friends[ScreenshotTour.friend.id] = ScreenshotTour.friend
            local.users[ScreenshotTour.friend.id] = ScreenshotTour.friend.user
            configureTourScene(ScreenshotTour.scene ?? "map")
            isConnected = true
            return
        }
        #endif
        // iOS relaunches us in the background after a significant location change; don't assume we're on screen.
        isForeground = UIApplication.shared.applicationState != .background
        location.setForeground(isForeground)
        if let saved = CredentialStore.load() {
            credentials = saved
            local = LocalDataStore.load()
            safety = SafetyStore.load(for: saved.userID)
            phase = .signedIn
            local.friends = local.friends.filter { safety.blocked[$0.key] == nil }
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
        if phase == .signedIn {
            // Contact links are kept outside LocalData (device-only), so attach them once the model exists.
            if let account = credentials?.userID {
                applyContactLinks(for: account)
                folders = FriendFolderStore.load(for: account)
                barOrder = FriendFolderStore.loadOrder(for: account)
            }
            startSession()
            // Resume a timed share that was running when the app was last closed, unless it has expired.
            if let share = TimedShareStore.load() { activate(share) }
        }
    }

    #if DEBUG
    func configureTourScene(_ scene: String) {
        guard ScreenshotTour.isEnabled else { return }
        safety = SafetyState()
        var fixture = ScreenshotTour.friend
        if scene == "friend-short-name" {
            fixture.nickname = "Dad"
        }
        if scene == "friend-long-name" {
            fixture.nickname = "Alex Golden Gate Family"
        }
        local.friends = [fixture.id: fixture]  // start each scene from the same fixture set
        requestStatuses = [:]
        // Your own shared nickname, so Settings shows it with @username underneath.
        local.myNickname = scene == "settings-nickname" ? "Family Demo" : nil
        if scene == "friend-unsupported" {
            // Their phone has said it can't answer Refresh, and we've already re-checked.
            local.friends[fixture.id]?.device?.liveRequests = false
            local.friends[fixture.id]?.device?.platform = .ios  // also shows the Apple logo
            lastProbe[fixture.id] = Date()
            unavailableUntil[fixture.id] = .distantFuture
        }
        if scene == "friend-updated" {
            // A Refresh that just succeeded: the green check, then the regular "Updated …" time.
            // Dated a few seconds ahead so the check is still showing once the scene has loaded.
            requestStatuses[fixture.id] = .responded(.finished, Date().addingTimeInterval(5))
        }
        folders = []
        barOrder = []
        if ["map-many-friends", "friend-overlap", "map-folders", "map-folders-open"].contains(scene) {
            // Enough friends to make the friend bar scroll, for checking its rounded-corner clipping.
            for (index, name) in ["Bailey", "Casey", "Devon", "Emerson", "Finley", "Harper"].enumerated() {
                var extra = fixture
                let seed = UInt8(20 + index)
                extra.user = ZoodUser(userID: Data(repeating: seed, count: 16), username: name.lowercased() + "demo",
                                      publicKey: Data(repeating: seed, count: 32))
                extra.nickname = name
                local.friends[extra.id] = extra
            }
        }
        if scene == "friend-contact-photo" {
            // Framing check: non-square photos that skip the linking step's square crop, to prove every
            // renderer fills and crops. Correct framing shows a round yellow circle and no red or green.
            local.friends[fixture.id]?.linkedContact = LinkedContact(identifier: "", name: "Alex Rivera",
                                                                     photo: ScreenshotTour.framingTestPhoto(tall: true))
            local.friends[fixture.id]?.nickname = "Alex Rivera"
            var wide = fixture
            wide.user = ZoodUser(userID: Data(repeating: 30, count: 16), username: "widedemo", publicKey: Data(repeating: 30, count: 32))
            wide.nickname = "Wide Photo"
            wide.linkedContact = LinkedContact(identifier: "", name: "Wide Photo", photo: ScreenshotTour.framingTestPhoto(tall: false))
            wide.location?.latitude += 0.004  // a little apart, so both map pins are visible
            wide.location?.longitude += 0.003
            local.friends[wide.id] = wide
        }
        if scene.hasPrefix("map-folders") {
            // A "Family" folder of Bailey, Casey and Devon (the extra friends above).
            folders = [FriendFolder(name: "Family", members: [20, 21, 22].map { Data(repeating: UInt8($0), count: 16) })]
        }
        if scene != "requests-empty" {
            safety.pending[ScreenshotTour.requester.id] = PendingRequest(user: ScreenshotTour.requester, boxID: Data(repeating: 7, count: 16), nickname: "Taylor")
        }
        if scene != "blocked-empty" { safety.blocked[ScreenshotTour.blocked.id] = ScreenshotTour.blocked }
    }
    #endif

    var api: OscarAPI { OscarAPI(accessToken: credentials?.accessToken) }

    var friends: [Friend] {
        local.friends.values.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// The live flag we advertise. Only true if the setting is on *and* iOS will actually let us stay alive.
    var advertisesLiveRequests: Bool {
        // Staying awake in the background needs CLBackgroundActivitySession (iOS 17+). Older iPhones get suspended
        // while stationary, so they honestly report that they can't answer Refresh.
        if isForeground && location.hasAnyPermission { return true }
        return LocationService.supportsBackgroundSession && liveRequestsEnabled
            && location.hasAlwaysPermission && location.liveArmed
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
        let username = Username.forLookup(username)
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
        var restoredBlocks: [ZoodUser] = []
        var restoredFolders: [FriendFolder] = []
        var restoredOrder: [BarItemID] = []
        let authed = OscarAPI(accessToken: login.accessToken)
        do {
            let encrypted = try await authed.backup()
            let json = try Crypto.secretBoxOpen(encrypted.cipherText, nonce: encrypted.nonce, key: symmetricKey)
            let snapshot = try ZoodJSON.decoder.decode(Snapshot.self, from: json)
            restored = Self.localData(from: snapshot)
            restoredBlocks = (snapshot.blocked ?? []).map { ZoodUser(userID: $0.userId, username: $0.username, publicKey: $0.publicKey) }
            restoredFolders = (snapshot.folders ?? []).compactMap { folder in
                UUID(uuidString: folder.id).map { FriendFolder(id: $0, name: folder.name, members: folder.members) }
            }
            restoredOrder = (snapshot.barOrder ?? []).compactMap(BarItemID.init(backupValue:))
        } catch let error as OscarError where error.code == OscarError.backupNotFound {
            // Brand-new account.
        }

        try CredentialStore.save(creds)
        credentials = creds
        safety = SafetyStore.load(for: creds.userID)
        // Blocks from the backup join any already on this iPhone; a block is never undone by a restore.
        if restoredBlocks.contains(where: { safety.blocked[$0.userID] == nil }) {
            var next = safety
            for user in restoredBlocks { next.blocked[user.userID] = user }
            try? saveSafety(next)
        }
        restored.friends = restored.friends.filter { safety.blocked[$0.key] == nil }
        local = restored
        // This is now the account's active device; any other signed-in device signs itself out.
        DeviceSession.claim(creds.userID)
        applyContactLinks(for: creds.userID)
        // This iPhone's own arrangement wins; otherwise the backup's comes back.
        folders = FriendFolderStore.load(for: creds.userID)
        barOrder = FriendFolderStore.loadOrder(for: creds.userID)
        if folders.isEmpty, !restoredFolders.isEmpty { setFolders(restoredFolders) }
        if barOrder.isEmpty, !restoredOrder.isEmpty { setBarOrder(restoredOrder) }
        scheduleBackup()  // records the claim right away
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

    func deleteAccount() async throws {
        try await api.deleteAccount()
        if let id = credentials?.userID {
            SafetyStore.delete(for: id)
            ContactLinkStore.delete(for: id)
            FriendFolderStore.delete(for: id)
        }
        logOut()
    }

    func logOut() {
        backupTask?.cancel()
        backupTask = nil
        stopTimedShare()
        inboxPoll?.cancel()
        inboxPoll = nil
        inboxSync?.cancel()
        inboxSync = nil
        inboxSyncID = nil
        inboxChanged = false
        socket?.stop()
        socket = nil
        location.stopAll()
        CredentialStore.delete()
        LocalDataStore.delete()
        credentials = nil
        local = LocalData()
        safety = SafetyState()
        safetyError = nil
        requestStatuses = [:]
        folders = []
        barOrder = []
        probingDevices = []
        lastProbe = [:]
        unavailableUntil = [:]
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
        startInboxPolling()
        location.startBaseline()
        applyLiveMode()
        Task {
            await refresh()
            await checkStillActiveDevice()
        }
    }

    private func applyLiveMode() {
        location.setLive(phase == .signedIn && liveRequestsEnabled)
    }

    func sceneDidBecomeActive() {
        guard !ScreenshotTour.isEnabled else { return }
        let returningFromBackground = !isForeground
        isForeground = true
        if timedShare?.isExpired == true { stopTimedShare() }
        location.setForeground(true)
        guard phase == .signedIn else { return }
        if returningFromBackground { socket?.stop() }
        socket?.start()
        startInboxPolling()
        applyLiveMode()
        Task {
            await refresh()
            await checkStillActiveDevice()
        }
    }

    /// Downloads and decrypts the account's backup. Nil if there isn't one or it can't be read.
    private func remoteSnapshot() async -> Snapshot? {
        guard let credentials,
              let encrypted = try? await api.backup(),
              let json = try? Crypto.secretBoxOpen(encrypted.cipherText, nonce: encrypted.nonce, key: credentials.symmetricKey) else { return nil }
        return try? ZoodJSON.decoder.decode(Snapshot.self, from: json)
    }

    /// Signed in on another phone since we were last open? Then sign out here (see DeviceSession).
    func checkStillActiveDevice() async {
        guard let account = credentials?.userID, !ScreenshotTour.isEnabled else { return }
        if let remote = await remoteSnapshot(), DeviceSession.isSuperseded(by: remote.activeDevice, account: account) {
            signOutBecauseSupersededElsewhere()
        }
    }

    private func signOutBecauseSupersededElsewhere() {
        logOut()
        signedOutElsewhere = true
    }

    func sceneDidEnterBackground() {
        isForeground = false
        inboxPoll?.cancel()
        inboxPoll = nil
        location.setForeground(false)
        // Without live mode iOS will suspend us shortly; the socket goes with it and that's expected.
    }

    private func startInboxPolling() {
        guard isForeground, inboxPoll == nil else { return }
        inboxPoll = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                guard let self, self.isForeground else { return }
                _ = await self.syncInbox()
            }
        }
    }

    /// Read durable messages in server ID order. WebSocket notifications trigger this immediately.
    private func syncInbox() async -> Bool {
        guard !ScreenshotTour.isEnabled, let token = credentials?.accessToken else { return false }
        if let inboxSync { return await inboxSync.value }
        let connection = api
        let id = UUID()
        inboxSyncID = id
        let task = Task { [weak self] in
            guard let self else { return false }
            defer {
                if self.inboxSyncID == id {
                    self.inboxSync = nil
                    self.inboxSyncID = nil
                }
            }
            repeat {
                self.inboxChanged = false
                guard let messages = try? await connection.messages() else { return false }
                var retrySenders: Set<Data> = []
                for message in messages.sorted(by: { $0.id < $1.id }) {
                    guard !Task.isCancelled, self.credentials?.accessToken == token else { return false }
                    guard !retrySenders.contains(message.senderId) else { continue }
                    guard await self.process(message, token: token) else {
                        retrySenders.insert(message.senderId)
                        continue
                    }
                    if message.id > 0, (try? await connection.deleteMessage(id: message.id)) != nil,
                       self.credentials?.accessToken == token {
                        self.processedMessageIDs.remove(message.id)
                    }
                }
                if !self.inboxChanged {
                    return retrySenders.isEmpty && !Task.isCancelled && self.credentials?.accessToken == token
                }
            } while !Task.isCancelled && self.credentials?.accessToken == token
            return false
        }
        inboxSync = task
        return await task.value
    }

    /// Catch up on both inbox messages and friends' last published locations.
    func refresh() async {
        guard !ScreenshotTour.isEnabled, let token = credentials?.accessToken else { return }
        _ = await syncInbox()
        guard credentials?.accessToken == token else { return }
        for friend in local.friends.values {
            guard let box = friend.receivingBoxID,
                  let pkg = try? await api.pickUpPackage(boxID: box) else { continue }
            guard credentials?.accessToken == token else { return }
            if local.friends[friend.id]?.receivingBoxID == box {
                await processPackage(pkg, from: friend.user)
            }
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
            if message.id > 0 {
                inboxChanged = true
                Task { _ = await syncInbox() }
            } else if let token = credentials?.accessToken {
                Task { _ = await process(message, token: token) }
            }
        case .invalidToken:
            logOut()
        }
    }

    // MARK: - Incoming

    /// Returns false if a durable message should stay in the inbox for a later attempt.
    private func process(_ message: InboxMessage, token: String) async -> Bool {
        guard let credentials, credentials.accessToken == token else { return false }
        if processedMessageIDs.contains(message.id) { return true }
        guard message.senderId.count == ZoodConstants.userIDLength,
              message.senderId != credentials.userID, safety.blocked[message.senderId] == nil else { return true }
        let sender: ZoodUser
        do {
            guard let knownUser = try await user(for: message.senderId),
                  self.credentials?.accessToken == token else { return false }
            sender = knownUser
        } catch let error as OscarError where error.code == OscarError.userNotFound {
            return true
        } catch {
            return false
        }
        guard let plain = try? Crypto.boxOpen(message.cipherText, nonce: message.nonce,
                                              senderPublicKey: sender.publicKey,
                                              receiverSecretKey: credentials.keyPair.secretKey),
              let comm = try? ZoodJSON.decoder.decode(UserComm.self, from: plain),
              comm.isValid else { return true }
        do {
            try await handle(comm, from: sender)
            if message.id > 0, self.credentials?.accessToken == token {
                processedMessageIDs.insert(message.id)
            }
            return self.credentials?.accessToken == token
        } catch {
            safetyError = error.localizedDescription
            return false
        }
    }

    private func fetchPackage(from user: ZoodUser, box: Data) async {
        guard let token = credentials?.accessToken,
              let package = try? await api.pickUpPackage(boxID: box),
              credentials?.accessToken == token,
              local.friends[user.userID]?.receivingBoxID == box else { return }
        await processPackage(package, from: user)
    }

    private func processPackage(_ pkg: EncryptedData, from user: ZoodUser) async {
        guard let credentials,
              let plain = try? Crypto.boxOpen(pkg.cipherText, nonce: pkg.nonce, senderPublicKey: user.publicKey,
                                              receiverSecretKey: credentials.keyPair.secretKey),
              let comm = try? ZoodJSON.decoder.decode(UserComm.self, from: plain),
              comm.isValid else { return }
        try? await handle(comm, from: user)
    }

    private func handle(_ comm: UserComm, from user: ZoodUser) async throws {
        guard safety.blocked[user.userID] == nil else { return }
        // A friend's profile may change while the map is open. Refresh only the shared name:
        // a name chosen by this account remains private and must never be overwritten remotely.
        if let nickname = comm.nickname, let friend = local.friends[user.userID],
           friend.sharedNickname != Nickname.normalized(nickname) {
            updateFriend(user.userID) { $0.sharedNickname = Nickname.normalized(nickname) }
            scheduleBackup()
        }
        switch comm.type {
        case .nicknameUpdate:
            break
        case .locationInfo:
            guard local.friends[user.userID]?.theyShare == true else { return }
            if let friend = local.friends[user.userID], let status = requestStatuses[user.userID] {
                let time = Date(timeIntervalSince1970: Double(comm.time ?? 0) / 1000)
                requestStatuses[user.userID] = status.receivingLocation(at: time, previousTime: friend.location?.time)
            }
            updateFriend(user.userID) { friend in
                let newTime = Date(timeIntervalSince1970: Double(comm.time ?? 0) / 1000)
                let incoming = FriendLocation(
                    latitude: comm.latitude ?? 0, longitude: comm.longitude ?? 0, time: newTime,
                    accuracy: comm.accuracy.map(Double.init), speed: comm.speed.map(Double.init),
                    bearing: comm.bearing.map(Double.init), movement: comm.movement,
                    batteryLevel: comm.batteryLevel, batteryCharging: comm.batteryCharging)
                if let existing = friend.location {
                    if existing.time > newTime { return }
                    // Android sends a fix about every second while its map is open. Ignore ones that change nothing
                    // you could see, or every open sheet and menu redraws constantly.
                    if Self.isNearDuplicate(incoming, of: existing), !Self.deviceChanged(comm, friend) { return }
                }
                friend.location = incoming
                Self.recordDevice(from: comm, into: &friend, reportedAt: min(newTime, Date()))
            }
            if let friend = local.friends[user.userID], friend.device?.liveRequests == false {
                Task { await refreshDeviceStatusIfNeeded(friend) }
            }
        case .locationSharingGrant:
            guard let box = comm.dropBox else { return }
            // Existing approved senders can rotate their box. Everyone else needs consent.
            guard local.friends[user.userID]?.theyShare == true else {
                var next = safety
                next.pending[user.userID] = PendingRequest(user: user, boxID: box, nickname: Nickname.normalized(comm.nickname))
                try saveSafety(next)
                return
            }
            upsertFriend(user) { $0.receivingBoxID = box }
            socket?.watch(box)
            scheduleBackup()
            Task { await fetchPackage(from: user, box: box) }
        case .locationSharingRevocation:
            if comm.friendRemoved == true {
                try forgetFriend(user.userID)
                return
            }
            if safety.pending[user.userID] != nil {
                var next = safety
                next.pending[user.userID] = nil
                try saveSafety(next)
            }
            updateFriend(user.userID) { friend in
                friend.receivingBoxID = nil
                friend.location = nil
            }
            scheduleBackup()
        case .locationUpdateRequest:
            Task { await answerLocationRequest(from: user) }
        case .locationUpdateRequestReceived:
            guard let action = comm.locationUpdateRequestAction else { return }
            updateFriend(user.userID) { Self.recordDevice(from: comm, into: &$0) }
            // A delayed acknowledgement must not replace success after a newer location arrived.
            if case .responded(.finished, _) = requestStatuses[user.userID] { return }
            requestStatuses[user.userID] = .responded(action, Date())
        case .deviceStatusRequest:
            // Only answer people we share with (same rule as location requests).
            guard local.friends[user.userID]?.weShare == true else { return }
            var reply = UserComm(type: .deviceStatus)
            reply.platform = .ios
            reply.liveRequests = advertisesLiveRequests
            try? await send(reply, to: user, urgent: true, transient: true)
        case .deviceStatus:
            guard local.friends[user.userID]?.theyShare == true else { return }
            updateFriend(user.userID) { Self.recordDevice(from: comm, into: &$0) }
            probingDevices.remove(user.userID)
            if comm.liveRequests == false {
                let expiration = Date().addingTimeInterval(30)
                unavailableUntil[user.userID] = expiration
                Task {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    if unavailableUntil[user.userID] == expiration { unavailableUntil[user.userID] = nil }
                }
            } else if comm.liveRequests == true {
                unavailableUntil[user.userID] = nil
            }
        case .avatarRequest:
            guard let friend = local.friends[user.userID] else { return }
            var profile = UserComm(type: .nicknameUpdate)
            profile.nickname = local.myNickname ?? ""
            try? await send(profile, to: user, urgent: false, transient: false)
            guard friend.weShare, let avatar = local.myAvatar else { return }
            var update = UserComm(type: .avatarUpdate)
            update.avatar = avatar
            try? await send(update, to: user, urgent: false, transient: false)
        case .avatarUpdate:
            updateFriend(user.userID) { $0.avatar = comm.avatar }
        default:
            break
        }
    }

    /// Under 5 m away, same battery/movement, and under a minute newer: nothing on screen would change.
    private static func isNearDuplicate(_ new: FriendLocation, of old: FriendLocation) -> Bool {
        let moved = CLLocation(latitude: new.latitude, longitude: new.longitude)
            .distance(from: CLLocation(latitude: old.latitude, longitude: old.longitude))
        return moved < 5
            && new.time.timeIntervalSince(old.time) < 60
            && new.batteryLevel == old.batteryLevel
            && new.batteryCharging == old.batteryCharging
            && new.movement == old.movement
    }

    private static func deviceChanged(_ comm: UserComm, _ friend: Friend) -> Bool {
        guard comm.platform != nil || comm.liveRequests != nil else { return false }
        return comm.platform.map { $0 != friend.device?.platform } == true
            || comm.liveRequests.map { $0 != friend.device?.liveRequests } == true
    }

    private static func recordDevice(from comm: UserComm, into friend: inout Friend, reportedAt: Date = Date()) {
        guard comm.platform != nil || comm.liveRequests != nil,
              friend.device.map({ reportedAt >= $0.reportedAt }) ?? true else { return }
        friend.device = FriendDevice(platform: comm.platform ?? friend.device?.platform,
                                     liveRequests: comm.liveRequests ?? friend.device?.liveRequests,
                                     reportedAt: reportedAt)
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
        var comm = comm
        // Empty is an explicit reset. Omitting the field means an older client and preserves the cached name.
        comm.nickname = local.myNickname ?? ""
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
        // Empty is an explicit reset. Omitting the field means an older client and preserves the cached name.
        comm.nickname = local.myNickname ?? ""
        guard let json = try? comm.jsonData() else { return }

        var packages: [Data: EncryptedData] = [:]
        for friend in local.friends.values {
            guard let box = friend.sendingBoxID,
                  let pkg = try? Crypto.box(json, receiverPublicKey: friend.user.publicKey,
                                            senderSecretKey: credentials.keyPair.secretKey) else { continue }
            packages[box] = pkg
        }
        // Timed share: the same location, boxed to the throwaway key whose secret half is in the link.
        if let share = timedShare {
            if share.isExpired {
                stopTimedShare()
            } else if let pkg = try? Crypto.box(json, receiverPublicKey: share.keyPair.publicKey,
                                                senderSecretKey: credentials.keyPair.secretKey) {
                packages[share.boxID] = pkg
            }
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

    // MARK: - Timed share

    /// Link to give someone who doesn't have the app. Only valid while a share is running.
    var timedShareURL: URL? {
        guard let share = timedShare, let credentials else { return nil }
        return share.url(username: credentials.username, userID: credentials.userID)
    }

    /// Starts sharing with a fresh throwaway key and drop box. Requires location access.
    func startTimedShare() throws {
        guard phase == .signedIn else { return }
        let now = Date()
        let share = TimedShare(keyPair: try Crypto.generateKeyPair(),
                               boxID: Crypto.randomBytes(ZoodConstants.dropBoxIDLength),
                               expiresAt: now.addingTimeInterval(TimedShare.initialDuration),
                               countdownStart: now)
        TimedShareStore.save(share)
        activate(share)
        // Get the viewer a precise location right away instead of waiting for the next update.
        Task { if let fix = await location.freshFix() { await upload(location: fix) } }
    }

    /// Ends the share. The link stops getting updates; the throwaway key is discarded.
    func stopTimedShare() {
        timedShareExpiry?.cancel()
        timedShareExpiry = nil
        TimedShareStore.delete()
        timedShare = nil
        location.setTimedSharing(false)
    }

    /// + / − buttons, with Android's step sizes. − at 1 minute or less turns the share off.
    func adjustTimedShare(longer: Bool) {
        guard let share = timedShare else { return }
        let remaining = share.remaining()
        let newRemaining = longer ? TimedShare.increased(remaining) : TimedShare.decreased(remaining)
        guard let newRemaining else {
            stopTimedShare()
            return
        }
        let now = Date()
        var updated = share
        updated.expiresAt = now.addingTimeInterval(newRemaining)
        updated.countdownStart = now   // ring refills, like Android
        TimedShareStore.save(updated)
        activate(updated)
    }

    private func activate(_ share: TimedShare) {
        timedShare = share
        location.setTimedSharing(true)
        // Stop on time. If the app is suspended past this, the next upload notices it's expired and stops then.
        timedShareExpiry?.cancel()
        timedShareExpiry = Task { [weak self] in
            let wait = share.remaining()
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, let self, self.timedShare == share else { return }
            self.stopTimedShare()
        }
    }

    // MARK: - Friends

    func pendingRequest(username: String) -> PendingRequest? {
        let username = Username.forLookup(username)
        return safety.pending.values.first { $0.user.username == username && safety.blocked[$0.id] == nil }
    }

    /// A nil result means the incoming request was approved or they already share with us.
    func prepareAddFriend(username: String) async throws -> ZoodUser? {
        let username = Username.forLookup(username)
        guard username != credentials?.username else { throw FriendError.cantAddSelf }
        if let request = pendingRequest(username: username) {
            try await approveRequest(request)
            return nil
        }
        guard await syncInbox() else { throw FriendError.inboxUnavailable }
        if let request = pendingRequest(username: username) {
            try await approveRequest(request)
            return nil
        }
        let result = try await api.searchUser(username: username)
        let user = ZoodUser(userID: result.id, username: result.username, publicKey: result.publicKey)
        guard safety.blocked[user.userID] == nil else { throw FriendError.blocked }
        return try await acceptIncomingIfPresent(user) ? nil : user
    }

    func confirmAddFriendSharing(with user: ZoodUser) async throws {
        guard await syncInbox() else { throw FriendError.inboxUnavailable }
        if try await acceptIncomingIfPresent(user) { return }
        try await startSharing(with: user)
    }

    private func acceptIncomingIfPresent(_ user: ZoodUser) async throws -> Bool {
        if let request = safety.pending[user.userID], safety.blocked[user.userID] == nil {
            try await approveRequest(request)
            return true
        }
        return local.friends[user.userID]?.theyShare == true
    }

    enum FriendError: LocalizedError {
        case cantAddSelf, blocked, inboxUnavailable
        var errorDescription: String? {
            switch self {
            case .cantAddSelf: return "You can't add yourself."
            case .blocked: return "Unblock this person in Settings before sharing with them."
            case .inboxUnavailable: return "Couldn’t check for incoming requests. Try again."
            }
        }
    }

    func startSharing(with user: ZoodUser) async throws {
        guard safety.blocked[user.userID] == nil else { throw FriendError.blocked }
        // Re-send the existing box if we already have one, exactly like FriendshipManager does.
        let box = local.friends[user.userID]?.sendingBoxID ?? Crypto.randomBytes(ZoodConstants.dropBoxIDLength)
        var grant = UserComm(type: .locationSharingGrant)
        grant.dropBox = box
        try await send(grant, to: user, urgent: false, transient: false)
        guard safety.blocked[user.userID] == nil else {
            try? await send(UserComm(type: .locationSharingRevocation), to: user, urgent: false, transient: false)
            throw FriendError.blocked
        }
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

    func removeFriend(_ friend: Friend) async throws {
        guard let account = credentials?.userID, local.friends[friend.id] != nil else { return }
        var removal = UserComm(type: .locationSharingRevocation)
        removal.friendRemoved = true
        try await send(removal, to: friend.user, urgent: false, transient: false)
        guard credentials?.userID == account else { return }
        try forgetFriend(friend.id)
    }

    private func forgetFriend(_ id: Data) throws {
        if safety.pending[id] != nil {
            var next = safety
            next.pending[id] = nil
            try saveSafety(next)
        }
        local.friends[id] = nil
        requestStatuses[id] = nil
        LocalDataStore.save(local)
        scheduleBackup()
    }

    private func saveSafety(_ state: SafetyState) throws {
        if ScreenshotTour.isEnabled {
            safety = state
            return
        }
        guard let id = credentials?.userID else { return }
        try SafetyStore.save(state, for: id)
        safety = state
    }

    func denyRequest(_ request: PendingRequest) throws {
        var next = safety
        next.pending[request.id] = nil
        try saveSafety(next)
    }

    func approveRequest(_ request: PendingRequest) async throws {
        guard safety.blocked[request.id] == nil,
              safety.pending[request.id]?.boxID == request.boxID else { return }
        try denyRequest(request)
        local.users[request.id] = request.user
        upsertFriend(request.user) {
            $0.receivingBoxID = request.boxID
            $0.sharedNickname = request.nickname
        }
        socket?.watch(request.boxID)
        scheduleBackup()
        Task { await fetchPackage(from: request.user, box: request.boxID) }
        Task { try? await send(UserComm(type: .avatarRequest), to: request.user, urgent: false, transient: false) }
    }

    func blockUser(_ user: ZoodUser) async throws {
        var next = safety
        next.pending[user.userID] = nil
        next.blocked[user.userID] = user
        // Persist the block before awaiting network work, so arriving grants cannot re-add them.
        try saveSafety(next)
        let friend = local.friends[user.userID]
        local.friends[user.userID] = nil
        requestStatuses[user.userID] = nil
        LocalDataStore.save(local)
        scheduleBackup()
        if friend?.weShare == true {
            try? await send(UserComm(type: .locationSharingRevocation), to: user, urgent: false, transient: false)
        }
    }

    func unblockUser(_ user: ZoodUser) throws {
        var next = safety
        next.blocked[user.userID] = nil
        try saveSafety(next)
        scheduleBackup()
    }

    func requestLocationUpdate(from friend: Friend) async {
        let sentAt = Date()
        requestStatuses[friend.id] = .sent(sentAt)
        do {
            try await send(UserComm(type: .locationUpdateRequest), to: friend.user, urgent: true, transient: true)
        } catch {
            if requestStatuses[friend.id] == .sent(sentAt) {
                requestStatuses[friend.id] = .noResponse(Date())
            }
            return
        }
        // Transient requests are only delivered to phones with a live connection. Give them 30 s to answer.
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        if requestStatuses[friend.id] == .sent(sentAt) {
            requestStatuses[friend.id] = .noResponse(Date())
        }
    }

    /// Before saying a friend's phone can't answer requests, make sure that's still true: their last report may be
    /// stale (e.g. they reopened the app but haven't moved, so no new location carried the updated flag).
    /// Only a direct reply can confirm unavailability. A timeout leaves manual Refresh available.
    func refreshDeviceStatusIfNeeded(_ friend: Friend) async {
        guard !ScreenshotTour.isEnabled else { return }
        guard friend.theyShare, friend.device?.liveRequests == false, !probingDevices.contains(friend.id) else { return }
        if let last = lastProbe[friend.id], Date().timeIntervalSince(last) < 60 { return }
        lastProbe[friend.id] = Date()
        probingDevices.insert(friend.id)
        defer { probingDevices.remove(friend.id) }

        let probe = Task { try? await send(UserComm(type: .deviceStatusRequest), to: friend.user, urgent: true, transient: true) }
        defer { probe.cancel() }
        for _ in 0..<12 {
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                lastProbe.removeValue(forKey: friend.id)
                return
            }
            if !probingDevices.contains(friend.id) { return }
        }
    }

    func requestCapability(for friend: Friend) -> RequestCapability {
        guard friend.theyShare else { return .notSharing }
        // Cached reports can trigger a probe. Only a recent direct reply can suppress Refresh.
        if friend.device?.liveRequests == false {
            if probingDevices.contains(friend.id) { return .checking }
            if let expiration = unavailableUntil[friend.id], expiration > Date() {
                return .unsupported(friend.device?.platform)
            }
        }
        return .supported
    }

    /// Replaces the friend-bar folders and saves them for this account (not in the screenshot tour).
    func setFolders(_ next: [FriendFolder]) {
        folders = next
        guard let account = credentials?.userID, !ScreenshotTour.isEnabled else { return }
        FriendFolderStore.save(next, for: account)
        scheduleBackup()
    }

    /// Replaces the friend bar's order and saves it for this account (not in the screenshot tour).
    func setBarOrder(_ next: [BarItemID]) {
        barOrder = next
        guard let account = credentials?.userID, !ScreenshotTour.isEnabled else { return }
        FriendFolderStore.saveOrder(next, for: account)
        scheduleBackup()
    }

    /// Combines this iPhone's contact links with any restored from the backup. A link made on this phone
    /// wins; a restored one fills the gap and is saved here so it sticks.
    private func applyContactLinks(for account: Data) {
        var links = ContactLinkStore.load(for: account)
        var changed = false
        for id in local.friends.keys {
            if let mine = links[id] {
                local.friends[id]?.linkedContact = mine
            } else if let restored = local.friends[id]?.linkedContact {
                links[id] = restored
                changed = true
            }
        }
        if changed, !ScreenshotTour.isEnabled { ContactLinkStore.save(links, for: account) }
    }

    func setLinkedContact(_ contact: LinkedContact?, for id: Data) {
        guard let account = credentials?.userID, local.friends[id] != nil else { return }
        // Saved on this iPhone and, like nicknames, in the end-to-end encrypted backup. It's never sent to
        // the friend or readable by the server.
        if !ScreenshotTour.isEnabled {
            var links = ContactLinkStore.load(for: account)
            links[id] = contact
            ContactLinkStore.save(links, for: account)
        }
        updateFriend(id) { friend in
            let previous = friend.linkedContact
            friend.linkedContact = contact
            if let contact {
                // Linking a contact names the friend after them (first and last name).
                friend.nickname = Nickname.normalized(contact.name)
            } else if let previous, friend.nickname == Nickname.normalized(previous.name) {
                // Unlinking undoes that, unless the nickname was changed since.
                friend.nickname = nil
            }
        }
        scheduleBackup()
    }

    func setFriendNickname(_ value: String, for id: Data) {
        updateFriend(id) { $0.nickname = Nickname.normalized(value) }
        scheduleBackup()
    }

    func setMyNickname(_ value: String) async {
        local.myNickname = Nickname.normalized(value)
        LocalDataStore.save(local)
        scheduleBackup()
        var update = UserComm(type: .nicknameUpdate)
        update.nickname = local.myNickname ?? ""
        // Names belong to the friendship, even when location sharing is one-way.
        for friend in friends {
            try? await send(update, to: friend.user, urgent: false, transient: false)
        }
        await shareCurrentLocation()
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

    private func user(for id: Data) async throws -> ZoodUser? {
        if let known = local.users[id] { return known }
        guard let token = credentials?.accessToken else { return nil }
        let info = try await api.user(id: id)
        guard credentials?.accessToken == token else { return nil }
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
        // Writing back an identical value still republishes and redraws everything, so don't.
        guard friend != local.friends[id] else { return }
        local.friends[id] = friend
        LocalDataStore.save(local)
    }

    // MARK: - Backup

    private func scheduleBackup() {
        guard !ScreenshotTour.isEnabled else { return }
        backupTask?.cancel()
        backupTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await saveBackup()
        }
    }

    private func saveBackup() async {
        guard let credentials else { return }
        // Never overwrite the backup of an account that's now active on another device; sign out instead.
        let remote = await remoteSnapshot()
        if DeviceSession.isSuperseded(by: remote?.activeDevice, account: credentials.userID) {
            signOutBecauseSupersededElsewhere()
            return
        }
        var snapshot = Snapshot()
        snapshot.activeDevice = DeviceSession.record(for: credentials.userID, remote: remote?.activeDevice)
        snapshot.users = local.users.values.map { .init(userId: $0.userID, publicKey: $0.publicKey, username: $0.username) }
        snapshot.friends = local.friends.values.map {
            .init(userId: $0.user.userID, sendingBoxId: $0.sendingBoxID, receivingBoxId: $0.receivingBoxID,
                  nickname: $0.nickname, sharedNickname: $0.sharedNickname,
                  linkedContactName: $0.linkedContact?.name,
                  linkedContactId: $0.linkedContact?.identifier,
                  linkedContactPlatform: $0.linkedContact == nil ? nil : "ios")
        }
        // Blocks, folders and the bar's order ride along in the same end-to-end encrypted backup, so they come
        // back after signing in again.
        snapshot.blocked = safety.blocked.values.map { .init(userId: $0.userID, publicKey: $0.publicKey, username: $0.username) }
        snapshot.folders = folders.map { .init(id: $0.id.uuidString, name: $0.name, members: $0.members) }
        snapshot.barOrder = barOrder.map(\.backupValue)
        snapshot.nickname = local.myNickname
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
            var friend = Friend(user: user, sendingBoxID: f.sendingBoxId, receivingBoxID: f.receivingBoxId, nickname: Nickname.normalized(f.nickname), sharedNickname: Nickname.normalized(f.sharedNickname))
            if let name = f.linkedContactName, !name.isEmpty {
                // An Android lookup URI means nothing to iOS Contacts, so keep only the name from there.
                friend.linkedContact = LinkedContact(identifier: f.linkedContactPlatform == "ios" ? (f.linkedContactId ?? "") : "",
                                                     name: name)
            }
            data.friends[f.userId] = friend
        }
        data.myNickname = Nickname.normalized(snapshot.nickname)
        data.myAvatar = snapshot.avatar
        return data
    }
}
