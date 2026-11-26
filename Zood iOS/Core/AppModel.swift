import Combine
import Contacts
import CoreLocation
import Foundation
import ImageIO
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
    /// A friend link that was opened (see `FriendLink`), waiting for the map screen to show it.
    /// Kept here rather than in a view so a link opened while signed out is still handled right after sign-in.
    @Published var pendingFriendLink: PendingFriendLink?
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
    private struct InviteRedemption {
        let userID: Data
        let accessToken: String
        var accepted: Bool?
    }
    private var inviteRedemptions: [Data: InviteRedemption] = [:]
    private var blockRemovalSends: [Data: Task<Void, Error>] = [:]
    private var timedShareExpiry: Task<Void, Never>?

    let location = LocationService()
    private var restoringContactPhotos = false

    @Published var accountPreferences = AccountPreferences() {
        didSet {
            guard accountPreferences != oldValue, let account = credentials?.userID,
                  !ScreenshotTour.isEnabled else { return }
            if let data = try? JSONEncoder().encode(accountPreferences) {
                UserDefaults.standard.set(data, forKey: Self.preferencesKey(account))
            }
            if oldValue.liveRequestsEnabled != accountPreferences.liveRequestsEnabled {
                applyLiveMode()
                if phase == .signedIn { Task { await shareCurrentLocation() } }
            }
            if phase == .signedIn { scheduleBackup() }
        }
    }

    var sharesWithNewFriends: Bool {
        get { accountPreferences.shareWithNewFriends ?? true }
        set { accountPreferences.shareWithNewFriends = newValue }
    }

    var liveRequestsEnabled: Bool {
        get { accountPreferences.liveRequestsEnabled ?? true }
        set { accountPreferences.liveRequestsEnabled = newValue }
    }

    private static func preferencesKey(_ account: Data) -> String {
        "accountPreferences." + account.base64EncodedString()
    }

    private func loadPreferences(for account: Data, from backup: AccountPreferences? = nil) {
        let defaults = UserDefaults.standard
        let id = account.base64EncodedString()
        let saved = defaults.data(forKey: Self.preferencesKey(account))
            .flatMap { try? JSONDecoder().decode(AccountPreferences.self, from: $0) }
        var preferences = backup ?? saved ?? AccountPreferences()
        preferences.shareWithNewFriends = preferences.shareWithNewFriends ?? saved?.shareWithNewFriends
            ?? defaults.object(forKey: "shareWithNewFriends." + id) as? Bool ?? true
        preferences.liveRequestsEnabled = preferences.liveRequestsEnabled ?? saved?.liveRequestsEnabled
            ?? defaults.object(forKey: "liveRequestsEnabled") as? Bool ?? true
        preferences.folderColumns = preferences.folderColumns ?? saved?.folderColumns
            ?? defaults.object(forKey: FolderGrid.columnsKey) as? Int ?? FolderGrid.defaultColumns
        preferences.folderRows = preferences.folderRows ?? saved?.folderRows
            ?? defaults.object(forKey: FolderGrid.rowsKey) as? Int ?? FolderGrid.defaultRows
        preferences.completedOnboarding = preferences.completedOnboarding ?? saved?.completedOnboarding
            ?? defaults.object(forKey: "completedWelcomeTour") as? Bool ?? false
        accountPreferences = preferences
    }

    private var socket: OscarSocket?
    private var processedMessageIDs: Set<Int64> = []
    private var backupTask: Task<Void, Never>?
    private var isForeground = true

    /// Kept out of the published `local` data: it changes on every upload, and republishing everything for it made
    /// open menus and sheets redraw constantly.
    private var lastLocationUpload: Date? {
        get { UserDefaults.standard.object(forKey: "lastLocationUpload") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastLocationUpload") }
    }

    /// Restores the signed-in account from the Keychain (or starts signed out) and starts syncing.
    /// Blocked people are filtered out on load so a block can never be undone by stale data on disk.
    init() {
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
            loadPreferences(for: saved.userID)
            local.friends = local.friends.filter { safety.blocked[$0.key] == nil }
        } else {
            phase = .signedOut
        }
        location.onShareableLocation = { [weak self] loc in
            Task { await self?.upload(location: loc) }
        }
        location.onBackgroundWake = { [weak self] in
            guard let self, liveRequestsEnabled else { return }
            socket?.recoverIfStale()
        }
        // Views read permission state through the model, so forward LocationService changes.
        location.onStateChange = { [weak self] in
            self?.objectWillChange.send()
            Task { await self?.restoreLinkedContactPhotos() }
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
    /// Debug only: fills the model with fictional people for a screenshot tour scene, so screenshots never show
    /// real family data.
    func configureTourScene(_ scene: String) {
        guard ScreenshotTour.isEnabled else { return }
        safety = SafetyState()
        var fixture = ScreenshotTour.friend
        if scene == "friend-short-name" {
            fixture.nickname = "Dad"
        }
        if scene == "friend-two-line-name" || scene == "friend-nickname" {
            fixture.sharedNickname = "Alex Reed"
        }
        if scene == "friend-long-name" {
            // Also shows the activity icons: walking, heading northeast.
            fixture.location?.movement = "walking"
            fixture.location?.bearing = 45
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
        if let scenario = StoreTourScene(rawValue: scene) {
            let friends = scenario.friends()
            local.friends = Dictionary(uniqueKeysWithValues: friends.map { ($0.id, $0) })
            if scenario == .westminster {
                folders = [FriendFolder(name: "Family", members: Array(friends.prefix(2).map(\.id)))]
            }
            if scenario == .requests {
                let requester = ZoodUser(userID: Data(repeating: 44, count: 16), username: "luciaortiz",
                                         publicKey: Data(repeating: 44, count: 32))
                safety.pending[requester.id] = PendingRequest(user: requester,
                    boxID: Data(repeating: 45, count: 16), nickname: "Lucia Ortiz")
            }
            return
        }
        if ["map-many-friends", "friend-overlap", "friend-nickname-scroll"].contains(scene) || scene.hasPrefix("map-folders") {
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
            let name = scene.hasSuffix("long") ? "Grandparents, aunts and uncles in Texas"
                : scene.hasSuffix("medium") ? "Grandparents and cousins" : "Family"
            folders = [FriendFolder(name: name, members: [20, 21, 22].map { Data(repeating: UInt8($0), count: 16) })]
        }
        if scene != "requests-empty" {
            safety.pending[ScreenshotTour.requester.id] = PendingRequest(
                user: ScreenshotTour.requester,
                boxID: scene == "requests" ? Data() : Data(repeating: 7, count: 16), nickname: "Taylor",
                avatar: ScreenshotTour.framingTestPhoto(tall: true))
        }
        if scene != "blocked-empty" { safety.blocked[ScreenshotTour.blocked.id] = ScreenshotTour.blocked }
    }

    func simulateBridgeDrive(_ scenario: StoreTourScene) async {
        guard let progress = scenario.bridgeProgress, let friendID = friends.first?.id else { return }
        let start = Date.now
        let remaining = (1 - progress) * 150
        while ScreenshotTour.scene == scenario.rawValue {
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            let now = Date.now
            let elapsed = now.timeIntervalSince(start)
            local.friends[friendID]?.location = scenario.bridgeLocation(elapsed: elapsed, now: now)
            if elapsed >= remaining { return }
        }
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

    /// Creates a new account. Keys are generated and the password is stretched off the main thread (it takes about
    /// a second on purpose); only public keys and password-encrypted secrets go to the server, then we sign in
    /// exactly as a returning user would.
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

    /// Signs in with the Zood challenge protocol: the password unlocks our secret key locally, the server checks we
    /// hold that key, and the encrypted backup brings back friends, blocks and folders. The password never leaves
    /// the phone. Signing in also makes this the account's active device (see DeviceSession).
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
        var restoredInvites: [InviteRecord] = []
        var restoredPreferences: AccountPreferences?
        let authed = OscarAPI(accessToken: login.accessToken)
        do {
            let encrypted = try await authed.backup()
            let json = try Crypto.secretBoxOpen(encrypted.cipherText, nonce: encrypted.nonce, key: symmetricKey)
            let snapshot = try ZoodJSON.decoder.decode(Snapshot.self, from: json)
            restored = Self.localData(from: snapshot)
            restoredInvites = snapshot.invites ?? []
            restoredPreferences = snapshot.preferences
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
        loadPreferences(for: creds.userID, from: restoredPreferences)
        safety = SafetyStore.load(for: creds.userID)
        let mergedInvites = InviteLedger.merge(local: safety.invites ?? [], remote: restoredInvites)
        if mergedInvites != (safety.invites ?? []) {
            var next = safety
            next.invites = mergedInvites
            // Keep the merge in memory even if the Keychain write fails, so the backup that follows cannot revive a used link.
            if (try? saveSafety(next)) == nil { safety = next }
        }
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

    /// Permanently deletes the account on the server (required by App Review guideline 5.1.1(v)) and then wipes
    /// everything this iPhone kept for it.
    func deleteAccount() async throws {
        try await api.deleteAccount()
        if let id = credentials?.userID {
            UserDefaults.standard.removeObject(forKey: Self.preferencesKey(id))
            UserDefaults.standard.removeObject(forKey: "shareWithNewFriends." + id.base64EncodedString())
            SafetyStore.delete(for: id)
            ContactLinkStore.delete(for: id)
            FriendFolderStore.delete(for: id)
        }
        logOut()
    }

    /// Stops all syncing and location work and erases this account's data from the phone, so the next person to
    /// sign in on this iPhone sees none of it.
    func logOut() {
        RefreshDelegate.cancel()
        backupTask?.cancel()
        backupTask = nil
        stopTimedShare()
        inboxPoll?.cancel()
        inboxPoll = nil
        inboxSync?.cancel()
        inboxSync = nil
        inboxSyncID = nil
        inboxChanged = false
        for send in blockRemovalSends.values { send.cancel() }
        blockRemovalSends.removeAll()
        socket?.stop()
        socket = nil
        location.stopAll()
        CredentialStore.delete()
        LocalDataStore.delete()
        credentials = nil
        accountPreferences = AccountPreferences()
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

    /// Starts everything a signed-in account needs: the live socket (watching each friend's drop box), inbox
    /// polling, location sharing, and a first catch-up refresh.
    private func startSession() {
        guard let credentials else { return }
        if !UserDefaults.standard.bool(forKey: Self.thumbnailBackupKey(for: credentials.userID)),
           local.friends.values.contains(where: { $0.avatar != nil || $0.linkedContact?.photo != nil || $0.avatarOverride != nil }) {
            scheduleBackup()
        }
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
        Task { await restoreLinkedContactPhotos() }
        Task {
            await refresh()
            await checkStillActiveDevice()
        }
    }

    /// Live Requests keeps location (and so the app) running in the background so family can ask for a fresh
    /// location. It only applies while signed in and when the user has it turned on.
    private func applyLiveMode() {
        location.setLive(phase == .signedIn && liveRequestsEnabled)
    }

    /// The app came to the foreground: recover a stale socket, catch up on
    /// anything missed, and check we weren't signed in on another phone meanwhile.
    func sceneDidBecomeActive() {
        guard !ScreenshotTour.isEnabled else { return }
        let returningFromBackground = !isForeground
        isForeground = true
        if timedShare?.isExpired == true { stopTimedShare() }
        location.setForeground(true)
        guard phase == .signedIn else { return }
        Task { await restoreLinkedContactPhotos() }
        if returningFromBackground { socket?.recoverIfStale() }
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

    /// One device per account: if the account signed in elsewhere, sign out here and tell the user why.
    private func signOutBecauseSupersededElsewhere() {
        logOut()
        signedOutElsewhere = true
    }

    /// Stops foreground-only work (inbox polling) to save battery once the app leaves the screen.
    func sceneDidEnterBackground() {
        isForeground = false
        inboxPoll?.cancel()
        inboxPoll = nil
        location.setForeground(false)
        if phase == .signedIn, !ScreenshotTour.isEnabled { RefreshDelegate.schedule() }
        // Without live mode iOS will suspend us shortly; the socket goes with it and that's expected.
    }

    /// While the app is open, checks the inbox every 10 seconds as a safety net in case a socket push was missed.
    private func startInboxPolling() {
        guard isForeground, inboxPoll == nil else { return }
        inboxPoll = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                guard let self, self.isForeground else { return }
                _ = await self.syncInbox()
                await self.flushBlockRemovals()
            }
        }
    }

    /// Read durable messages in server ID order. WebSocket notifications trigger this immediately.
    private func syncInbox(cancelWithCaller: Bool = false) async -> Bool {
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
        if cancelWithCaller {
            return await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        }
        return await task.value
    }

    func backgroundCatchUp() async -> Bool {
        guard !Task.isCancelled, !ScreenshotTour.isEnabled, let token = credentials?.accessToken else { return false }
        RefreshDelegate.schedule()
        let inboxSucceeded = await syncInbox(cancelWithCaller: true)
        for friend in friends {
            guard !Task.isCancelled, credentials?.accessToken == token else { return false }
            if let box = friend.receivingBoxID { await fetchPackage(from: friend.user, box: box) }
        }
        return inboxSucceeded && !Task.isCancelled && credentials?.accessToken == token
    }

    /// Catch up on both inbox messages and friends' last published locations.
    func refresh() async {
        guard !ScreenshotTour.isEnabled, let token = credentials?.accessToken else { return }
        _ = await syncInbox()
        await flushBlockRemovals()
        guard credentials?.accessToken == token else { return }
        // A previous build may already have consumed the grant and put it in Pending Requests.
        for request in safety.visibleRequests where request.includesLocation {
            guard credentials?.accessToken == token else { return }
            if local.friends[request.id]?.acceptsLocationWithoutNewRequest == true {
                do { try await approveRequest(request) }
                catch { safetyError = error.localizedDescription }
            }
        }
        for friend in local.friends.values {
            guard let box = friend.receivingBoxID,
                  let pkg = try? await api.pickUpPackage(boxID: box) else { continue }
            guard credentials?.accessToken == token else { return }
            if local.friends[friend.id]?.receivingBoxID == box {
                await processPackage(pkg, from: friend.user)
            }
        }
    }

    /// Reacts to the live socket: a reconnect triggers a catch-up, a package is a friend's new location, a message
    /// triggers an inbox sync, and an invalid token means the session ended (signed out elsewhere or deleted).
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
              message.senderId != credentials.userID else { return true }
        let blockedSender = safety.blocked[message.senderId]
        if blockedSender != nil, safety.pending[message.senderId] == nil { return true }
        let sender: ZoodUser
        do {
            if let blockedSender {
                sender = blockedSender
            } else {
                guard let knownUser = try await user(for: message.senderId) else { return false }
                sender = knownUser
            }
            guard self.credentials?.accessToken == token else { return false }
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

    /// Picks up the latest location a friend left in their drop box, e.g. right after they start sharing with us.
    private func fetchPackage(from user: ZoodUser, box: Data) async {
        guard let token = credentials?.accessToken,
              let package = try? await api.pickUpPackage(boxID: box),
              credentials?.accessToken == token,
              local.friends[user.userID]?.receivingBoxID == box else { return }
        await processPackage(package, from: user)
    }

    /// Decrypts a friend's dropped package and applies it. Anything that doesn't decrypt or validate is ignored.
    private func processPackage(_ pkg: EncryptedData, from user: ZoodUser) async {
        guard let credentials,
              let plain = try? Crypto.boxOpen(pkg.cipherText, nonce: pkg.nonce, senderPublicKey: user.publicKey,
                                              receiverSecretKey: credentials.keyPair.secretKey),
              let comm = try? ZoodJSON.decoder.decode(UserComm.self, from: plain),
              comm.isValid else { return }
        try? await handle(comm, from: user)
    }

    /// Applies one decrypted message from another user. Messages from blocked people are dropped (except a
    /// revocation, which may clear their pending request); every other type updates friends, requests or replies.
    private func handle(_ comm: UserComm, from user: ZoodUser) async throws {
        if safety.blocked[user.userID] != nil {
            if comm.type == .locationSharingRevocation, let request = safety.pending[user.userID] {
                try denyRequest(request)
            }
            return
        }
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
            var completedRefresh = false
            if let friend = local.friends[user.userID], let status = requestStatuses[user.userID] {
                let time = Date(timeIntervalSince1970: Double(comm.time ?? 0) / 1000)
                let nextStatus = status.receivingLocation(at: time, previousTime: friend.location?.time)
                completedRefresh = nextStatus != status
                requestStatuses[user.userID] = nextStatus
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
                    if !completedRefresh, Self.isNearDuplicate(incoming, of: existing), !Self.deviceChanged(comm, friend) { return }
                }
                friend.location = incoming
                Self.recordDevice(from: comm, into: &friend, reportedAt: min(newTime, Date()))
            }
            if let friend = local.friends[user.userID], friend.device?.liveRequests == false {
                Task { await refreshDeviceStatusIfNeeded(friend) }
            }
        case .inviteRedemption:
            try await handleInviteRedemption(comm, from: user)
        case .friendRequest:
            if comm.inviteToken != nil {
                try await acceptOneTimeInvite(comm, from: user)
                return
            }
            guard local.friends[user.userID] == nil else { return }
            var next = safety
            if let existing = next.pending[user.userID], existing.includesLocation { return }
            next.pending[user.userID] = PendingRequest(user: user, boxID: Data(),
                                                       nickname: Nickname.normalized(comm.nickname),
                                                       avatar: Self.requestAvatar(comm.avatar))
            try saveSafety(next)
        case .locationSharingGrant:
            if comm.inviteToken != nil {
                try await acceptOneTimeInvite(comm, from: user)
                return
            }
            guard let box = comm.dropBox else { return }
            let existing = local.friends[user.userID]
            let pending = safety.pending[user.userID]
            if pending?.requiresFreshOffer == true, pending?.boxID == box { return }
            let offeredAt = comm.time ?? 0
            if let cutoff = pending?.freshOfferAfter, offeredAt > 0, offeredAt <= cutoff { return }
            // Older clients send no timestamp or zero. Their new box needs ordinary approval.
            let approved = pending?.requiresFreshOffer == true && pending?.approved == true && offeredAt > 0
            // A first grant can update a friendship that was explicitly created without location.
            let established = existing?.acceptsLocationWithoutNewRequest == true
            guard approved || established || existing?.theyShare == true || comm.repliesToSharingOffer(on: existing?.sendingBoxID) else {
                var next = safety
                next.pending[user.userID] = PendingRequest(user: user, boxID: box, nickname: Nickname.normalized(comm.nickname),
                                                           avatar: Self.requestAvatar(comm.avatar) ?? pending?.avatar)
                try saveSafety(next)
                return
            }
            if let pending = safety.pending[user.userID] { try denyRequest(pending) }
            upsertFriend(user) {
                if established { $0.establishedWithoutLocation = true }
                $0.receivingBoxID = box
                if let nickname = comm.nickname { $0.sharedNickname = Nickname.normalized(nickname) }
                if let avatar = Self.requestAvatar(comm.avatar) ?? pending?.avatar { $0.avatar = avatar }
            }
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
            let requestDate: Date
            switch requestStatuses[user.userID] {
            case .sent(let date), .responded(.starting, let date): requestDate = date
            default: return
            }
            switch action {
            case .starting:
                requestStatuses[user.userID] = .responded(.starting, requestDate)
            case .tooSoon:
                requestStatuses[user.userID] = .responded(.tooSoon, Date())
            case .finished:
                // An acknowledgement alone doesn't establish that a fresh fix was uploaded.
                if let box = local.friends[user.userID]?.receivingBoxID {
                    await fetchPackage(from: user, box: box)
                }
            }
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
            guard let avatar = Self.requestAvatar(comm.avatar) else { return }
            if var request = safety.pending[user.userID] {
                request.avatar = avatar
                var next = safety
                next.pending[user.userID] = request
                try saveSafety(next)
            }
            if let friend = local.friends[user.userID], friend.avatar != avatar {
                updateFriend(user.userID) { $0.avatar = avatar }
                scheduleBackup()
            }
        default:
            break
        }
    }

    /// Only accepts a profile photo that is a real image of a sane size (at most 128 KB and 1024 px), so a stranger's
    /// request can't be used to push a huge or malformed file onto this phone.
    private static func requestAvatar(_ data: Data?) -> Data? {
        guard let data, data.count <= 128 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...1024).contains(width), (1...1024).contains(height) else { return nil }
        return data
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

    /// True when a message reports a different platform or Live Requests setting than we have on record, which must
    /// update the friend card even if the location itself didn't move.
    private static func deviceChanged(_ comm: UserComm, _ friend: Friend) -> Bool {
        guard comm.platform != nil || comm.liveRequests != nil else { return false }
        return comm.platform.map { $0 != friend.device?.platform } == true
            || comm.liveRequests.map { $0 != friend.device?.liveRequests } == true
    }

    /// Remembers a friend's platform and Live Requests setting, ignoring reports older than what we already know.
    private static func recordDevice(from comm: UserComm, into friend: inout Friend, reportedAt: Date = Date()) {
        guard comm.platform != nil || comm.liveRequests != nil,
              friend.device.map({ reportedAt >= $0.reportedAt }) ?? true else { return }
        friend.device = FriendDevice(platform: comm.platform ?? friend.device?.platform,
                                     liveRequests: comm.liveRequests ?? friend.device?.liveRequests,
                                     reportedAt: reportedAt)
    }

    /// Answers a friend's "request location update". Same contract as george's handleLocationUpdateRequest.
    private func answerLocationRequest(from user: ZoodUser) async {
        guard let token = credentials?.accessToken, canAnswerLocationRequest(from: user.userID) else { return }
        if !isForeground, let last = lastLocationUpload, Date().timeIntervalSince(last) < 120 {
            try? await sendRequestResponse(.tooSoon, to: user)
            return
        }
        try? await sendRequestResponse(.starting, to: user)
        guard let fix = await location.freshFix(), fix.timestamp.timeIntervalSinceNow >= -30,
              credentials?.accessToken == token, canAnswerLocationRequest(from: user.userID),
              await upload(location: fix, requestedBy: user.userID),
              credentials?.accessToken == token, canAnswerLocationRequest(from: user.userID) else { return }
        try? await sendRequestResponse(.finished, to: user)
    }

    private func canAnswerLocationRequest(from id: Data) -> Bool {
        local.friends[id]?.weShare == true && location.hasAnyPermission
            && (isForeground || (liveRequestsEnabled && location.hasAlwaysPermission))
    }

    /// Tells a friend how their "refresh location" request is going (starting, finished, too soon), with our Live
    /// Requests setting so their card stays accurate.
    private func sendRequestResponse(_ action: UpdateRequestAction, to user: ZoodUser) async throws {
        var comm = UserComm(type: .locationUpdateRequestReceived)
        comm.locationUpdateRequestAction = action
        comm.platform = .ios
        comm.liveRequests = advertisesLiveRequests
        try await send(comm, to: user, urgent: true, transient: true)
    }

    // MARK: - Outgoing

    /// Encrypts a message for one user and posts it to their inbox. Always includes our shared nickname so friends
    /// see name changes promptly. `urgent` asks the server to deliver right away; `transient` messages aren't
    /// stored if the recipient is offline (used for live requests, which are pointless later).
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

    /// Shares one location fix with everyone we share with (and an active timed-share link). Each friend gets their
    /// own encrypted copy in their drop box, so the server never sees the location.
    @discardableResult
    func upload(location loc: CLLocation, requestedBy requester: Data? = nil) async -> Bool {
        guard let credentials else { return false }
        var comm = UserComm(type: .locationInfo)
        comm.latitude = loc.coordinate.latitude
        comm.longitude = loc.coordinate.longitude
        comm.time = Int64(loc.timestamp.timeIntervalSince1970 * 1000)
        if loc.horizontalAccuracy >= 0 { comm.accuracy = Float(loc.horizontalAccuracy) }
        if loc.speed >= 0 { comm.speed = Float(loc.speed) }
        if loc.course > 0 { comm.bearing = Float(loc.course) }
        comm.movement = await MotionActivity.shared.currentMovement()
        comm.batteryLevel = Battery.level
        comm.batteryCharging = Battery.isCharging
        comm.platform = .ios
        comm.liveRequests = advertisesLiveRequests
        // Empty is an explicit reset. Omitting the field means an older client and preserves the cached name.
        comm.nickname = local.myNickname ?? ""
        guard self.credentials?.accessToken == credentials.accessToken,
              let json = try? comm.jsonData() else { return false }
        if let requester, !canAnswerLocationRequest(from: requester) { return false }

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
        guard !packages.isEmpty else { return false }
        if let requester {
            guard let box = local.friends[requester]?.sendingBoxID, packages[box] != nil else { return false }
        }
        do {
            try await api.dropPackages(packages)
            guard self.credentials?.accessToken == credentials.accessToken else { return false }
            lastLocationUpload = Date()
            return true
        } catch let error as OscarError where error.code == OscarError.invalidAccessToken {
            if self.credentials?.accessToken == credentials.accessToken { logOut() }
        } catch {
            // Network hiccup; the next location update will try again.
        }
        return false
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

    /// Starts tracking a timed share and schedules it to stop on time.
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

    /// Checks whether a username is taken (sign-up) or exists (adding a friend). Before sign-in, search isn't
    /// allowed, so starting a sign-in challenge is used as the existence check.
    func usernameExists(_ username: String, registration: Bool) async throws -> Bool {
        do {
            if registration {
                // Search requires authentication. Starting a challenge only checks the account exists.
                _ = try await OscarAPI().authChallenge(username: username)
            } else {
                _ = try await api.searchUser(username: username)
            }
            return true
        } catch let error as OscarError where error.code == OscarError.userNotFound {
            return false
        }
    }

    /// An incoming friend request from this username, if one is waiting for approval.
    /// Accepts a friend link the app was opened with. Invalid links are ignored; nothing is sent until the user
    /// confirms in Add Friend. A valid `t` is a one-time invite; a bad token falls back to a normal request.
    func open(_ url: URL) {
        guard let target = FriendLink.target(from: url) else { return }
        pendingFriendLink = PendingFriendLink(username: target.username, inviteToken: target.inviteToken)
    }

    /// Mints a fresh one-time invite link and stores it before returning, so a link is never shared unless this phone can redeem it.
    func issueInviteLink(sharingOnRedemption: Bool) throws -> URL? {
        guard let credentials else { return nil }
        let token = Crypto.randomBytes(InviteLedger.tokenLength)
        var next = safety
        next.invites = InviteLedger.issued(token, into: next.invites ?? [], shareOnRedemption: sharingOnRedemption && sharesWithNewFriends)
        do { try saveSafety(next) } catch { throw FriendError.inviteUnavailable }
        scheduleBackup()
        return FriendLink.url(for: credentials.username, token: token)
    }

    func pendingRequest(username: String) -> PendingRequest? {
        let username = Username.forLookup(username)
        return safety.visibleRequests.first { $0.user.username == username }
    }

    /// A nil result means the incoming request was approved or they already share with us.
    func prepareAddFriend(username: String, isInvite: Bool = false) async throws -> ZoodUser? {
        let username = Username.forLookup(username)
        guard username != credentials.map({ Username.forLookup($0.username) }) else { throw FriendError.cantAddSelf }
        if !isInvite, let request = pendingRequest(username: username) {
            try await approveRequest(request)
            return nil
        }
        guard await syncInbox() else { throw FriendError.inboxUnavailable }
        if !isInvite, let request = pendingRequest(username: username) {
            try await approveRequest(request)
            return nil
        }
        let result = try await api.searchUser(username: username)
        let user = ZoodUser(userID: result.id, username: result.username, publicKey: result.publicKey)
        guard user.userID != credentials?.userID else { throw FriendError.cantAddSelf }
        guard safety.blocked[user.userID] == nil else { throw FriendError.blocked }
        if isInvite { return user }
        return try await acceptIncomingIfPresent(user) ? nil : user
    }

    /// Adds a friend after the user confirms. With `sharing` we offer our location right away; without it we send a
    /// plain friend request, so people can connect without sharing (for example, to be visible in each other's lists first).
    /// `inviteToken` is the one-time token from their link: the request carries it so their phone connects us immediately.
    func confirmAddFriend(with user: ZoodUser, sharing: Bool, inviteToken: Data? = nil) async throws {
        guard user.userID != credentials?.userID else { throw FriendError.cantAddSelf }
        guard await syncInbox() else { throw FriendError.inboxUnavailable }
        if let inviteToken {
            try await sendInviteAcceptance(to: user, sharing: sharing, token: inviteToken)
            return
        }
        if try await acceptIncomingIfPresent(user) { return }
        if sharing {
            try await startSharing(with: user)
            return
        }
        guard safety.blocked[user.userID] == nil else { throw FriendError.blocked }
        guard let token = credentials?.accessToken, local.friends[user.userID] == nil else { return }
        var request = UserComm(type: .friendRequest)
        request.avatar = Self.requestAvatar(local.myAvatar)
        try await send(request, to: user, urgent: false, transient: false)
        guard credentials?.accessToken == token, safety.blocked[user.userID] == nil else { return }
        upsertFriend(user) { $0.establishedWithoutLocation = true }
        scheduleBackup()
    }

    /// Wait for the inviter to confirm before adding a friend or enabling the recipient's share.
    private func sendInviteAcceptance(to user: ZoodUser, sharing: Bool, token: Data) async throws {
        guard safety.blocked[user.userID] == nil else { throw FriendError.blocked }
        guard let access = credentials?.accessToken else { throw FriendError.inviteUnconfirmed }
        guard inviteRedemptions[token] == nil else { throw FriendError.inviteUnconfirmed }
        inviteRedemptions[token] = InviteRedemption(userID: user.userID, accessToken: access)
        defer { inviteRedemptions[token] = nil }

        var request = UserComm(type: .inviteRedemption)
        request.avatar = Self.requestAvatar(local.myAvatar)
        request.inviteToken = token
        try await send(request, to: user, urgent: true, transient: false)

        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard credentials?.accessToken == access else { throw FriendError.inviteUnconfirmed }
            if let accepted = inviteRedemptions[token]?.accepted {
                guard accepted else { throw FriendError.inviteExpired }
                guard safety.blocked[user.userID] == nil else { throw FriendError.blocked }
                if sharing { try await startSharing(with: user) }
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw FriendError.inviteUnconfirmed
    }

    private func handleInviteRedemption(_ comm: UserComm, from user: ZoodUser) async throws {
        guard let token = comm.inviteToken else { return }
        if let accepted = comm.inviteAccepted {
            guard let attempt = inviteRedemptions[token], attempt.userID == user.userID,
                  attempt.accessToken == credentials?.accessToken else { return }
            if accepted, safety.blocked[user.userID] == nil {
                // The inviter’s return grant can follow this reply immediately.
                upsertFriend(user) { $0.establishedWithoutLocation = true }
                scheduleBackup()
            }
            inviteRedemptions[token]?.accepted = accepted
            return
        }
        let record = safety.invites?.first { $0.token == token }
        let accepted: Bool
        if record?.invalidatedFor?.contains(user.userID) == true {
            accepted = false
        } else if record?.usedBy == user.userID {
            // A retry can recover a lost reply, but cannot restore a friendship that was removed.
            accepted = local.friends[user.userID] != nil
        } else {
            accepted = try await acceptOneTimeInvite(comm, from: user)
        }
        var reply = UserComm(type: .inviteRedemption)
        reply.inviteToken = token
        reply.inviteAccepted = accepted
        let access = credentials?.accessToken
        try await send(reply, to: user, urgent: true, transient: false)
        if accepted, record?.usedBy == nil, access != nil, credentials?.accessToken == access {
            await shareAfterRedeeming(token, with: user)
        }
    }

    private func shareAfterRedeeming(_ token: Data, with user: ZoodUser) async {
        guard sharesWithNewFriends,
              let record = safety.invites?.first(where: { $0.token == token }),
              record.shareOnRedemption == true, record.usedBy == user.userID,
              record.invalidatedFor?.contains(user.userID) != true,
              let friend = local.friends[user.userID], !friend.weShare else { return }
        do { try await startSharing(with: user, requiresExistingFriend: true) }
        catch { safetyError = error.localizedDescription }
    }

    /// Redeems a one-time invite. An unknown or already-used token is ignored and does not become a request.
    /// The friend is added without our outgoing sharing. A grant only fills the receiving box.
    @discardableResult
    private func acceptOneTimeInvite(_ comm: UserComm, from user: ZoodUser) async throws -> Bool {
        guard let token = comm.inviteToken, token.count == InviteLedger.tokenLength else { return false }
        var records = safety.invites ?? []
        guard InviteLedger.authorize(token, sender: user.userID, records: &records) else { return false }
        var next = safety
        next.invites = records
        next.pending[user.userID] = nil
        try saveSafety(next)
        let box = comm.type == .locationSharingGrant ? comm.dropBox : nil
        let existed = local.friends[user.userID] != nil
        if box != nil || !existed {
            upsertFriend(user) { friend in
                friend.establishedWithoutLocation = true
                if let box { friend.receivingBoxID = box }
                if let nickname = comm.nickname { friend.sharedNickname = Nickname.normalized(nickname) }
                if let avatar = Self.requestAvatar(comm.avatar) { friend.avatar = avatar }
            }
        }
        scheduleBackup()
        if let box {
            socket?.watch(box)
            Task { await fetchPackage(from: user, box: box) }
        }
        if !existed {
            Task { try? await send(UserComm(type: .avatarRequest), to: user, urgent: false, transient: false) }
        }
        return true
    }

    /// If they already asked to connect with us, adding them just approves that request instead of sending a
    /// duplicate. Returns true when nothing more is needed.
    private func acceptIncomingIfPresent(_ user: ZoodUser) async throws -> Bool {
        if let request = safety.pending[user.userID], safety.blocked[user.userID] == nil {
            try await approveRequest(request)
            return true
        }
        return local.friends[user.userID]?.theyShare == true
    }

    enum FriendError: LocalizedError {
        case cantAddSelf, blocked, inboxUnavailable, inviteUnavailable, inviteExpired, inviteUnconfirmed
        var errorDescription: String? {
            switch self {
            case .cantAddSelf: return "You can't add yourself."
            case .blocked: return "Unblock this person in Settings before sharing with them."
            case .inboxUnavailable: return "Couldn’t check for incoming requests. Try again."
            case .inviteUnavailable: return "Couldn’t create an invite link. Try again."
            case .inviteExpired: return "This invite has expired for you. Ask the inviter for a new link."
            case .inviteUnconfirmed: return "Couldn’t confirm this invite. Ask the inviter to open an updated Amidst app, then try again."
            }
        }
    }

    /// Starts sharing our location with someone: creates (or reuses) a private drop box and sends them its ID.
    /// Reusing the existing box keeps friendships stable across retries, matching the Android client.
    func startSharing(with user: ZoodUser, requiresExistingFriend: Bool = false) async throws {
        guard user.userID != credentials?.userID else { throw FriendError.cantAddSelf }
        guard safety.blocked[user.userID] == nil else { throw FriendError.blocked }
        // Re-send the existing box if we already have one, exactly like FriendshipManager does.
        let access = credentials?.accessToken
        let box = local.friends[user.userID]?.sendingBoxID ?? Crypto.randomBytes(ZoodConstants.dropBoxIDLength)
        var grant = UserComm(type: .locationSharingGrant)
        grant.dropBox = box
        grant.replyToBox = local.friends[user.userID]?.receivingBoxID
        grant.time = Int64(Date().timeIntervalSince1970 * 1_000)
        try await send(grant, to: user, urgent: false, transient: false)
        guard access != nil, credentials?.accessToken == access else { return }
        if requiresExistingFriend, local.friends[user.userID] == nil { return }
        guard safety.blocked[user.userID] == nil else {
            try? await send(UserComm(type: .locationSharingRevocation), to: user, urgent: false, transient: false)
            throw FriendError.blocked
        }
        upsertFriend(user) {
            if $0.acceptsLocationWithoutNewRequest { $0.establishedWithoutLocation = true }
            $0.sendingBoxID = box
        }
        scheduleBackup()
        if let avatar = local.myAvatar {
            var update = UserComm(type: .avatarUpdate)
            update.avatar = avatar
            try? await send(update, to: user, urgent: false, transient: false)
        }
        await shareCurrentLocation()
    }

    /// Stops sharing our location with a friend but keeps the friendship.
    func stopSharing(with friend: Friend) async {
        updateFriend(friend.id) { $0.sendingBoxID = nil }
        scheduleBackup()
        try? await send(UserComm(type: .locationSharingRevocation), to: friend.user, urgent: false, transient: false)
    }

    /// Removes a friend on both sides: their app drops us too (the `friendRemoved` flag), then we forget them here.
    func removeFriend(_ friend: Friend) async throws {
        guard let account = credentials?.userID, local.friends[friend.id] != nil else { return }
        if let invites = safety.invites {
            var next = safety
            next.invites = InviteLedger.invalidate(friend.id, in: invites)
            try saveSafety(next)
            scheduleBackup()
        }
        try await sendFriendRemoval(to: friend.user)
        guard credentials?.userID == account else { return }
        try forgetFriend(friend.id)
    }

    /// Sends the two-way removal message. Older clients see an ordinary revocation and still stop receiving locations.
    private func sendFriendRemoval(to user: ZoodUser) async throws {
        var removal = UserComm(type: .locationSharingRevocation)
        removal.friendRemoved = true
        do {
            try await send(removal, to: user, urgent: false, transient: false)
        } catch let error as OscarError where error.code == OscarError.userNotFound {
            // A deleted account no longer has an inbox or friendship to clean up.
        }
    }

    /// Retries removal messages for blocks made while offline, so a blocked person is removed from the other phone
    /// as soon as we have a connection.
    private func flushBlockRemovals() async {
        guard let token = credentials?.accessToken else { return }
        for (id, sent) in safety.sentBlockRemovals ?? [:] where !sent {
            guard credentials?.accessToken == token else { return }
            if let user = safety.blocked[id] { try? await deliverBlockRemoval(to: user) }
        }
    }

    /// Sends the removal for one blocked person at most once, recording success in the Keychain so it survives restarts.
    /// Concurrent callers share the same send instead of sending duplicates.
    private func deliverBlockRemoval(to user: ZoodUser) async throws {
        let id = user.userID
        guard let token = credentials?.accessToken, safety.blocked[id] != nil,
              safety.sentBlockRemovals?[id] != true else { return }
        if let existing = blockRemovalSends[id] { return try await existing.value }
        let send = Task {
            defer {
                if credentials?.accessToken == token { blockRemovalSends[id] = nil }
            }
            guard !Task.isCancelled, credentials?.accessToken == token else { return }
            try await sendFriendRemoval(to: user)
            guard credentials?.accessToken == token, safety.blocked[id] != nil else { return }
            var next = safety
            var removals = next.sentBlockRemovals ?? [:]
            removals[id] = true
            next.sentBlockRemovals = removals
            try saveSafety(next)
        }
        blockRemovalSends[id] = send
        try await send.value
    }

    /// Deletes everything we know about a friend on this phone (location, names, folder spot) so re-adding them later
    /// starts fresh. `keepRequest` preserves a pending request when blocking, so unblocking can restore it.
    private func forgetFriend(_ id: Data, keepRequest: Bool = false) throws {
        if !keepRequest, safety.pending[id] != nil {
            var next = safety
            next.pending[id] = nil
            try saveSafety(next)
        }
        // Their last location, nickname and linked contact live on the friend record and go with it.
        local.friends[id] = nil
        requestStatuses[id] = nil
        LocalDataStore.save(local)
        dropFromBar(id)
        scheduleBackup()
    }

    /// Persists blocks and pending requests before updating the screen, so a block is never shown as done unless it
    /// was actually saved.
    private func saveSafety(_ state: SafetyState) throws {
        if ScreenshotTour.isEnabled {
            safety = state
            return
        }
        guard let id = credentials?.userID else { return }
        try SafetyStore.save(state, for: id)
        safety = state
    }

    /// Declines an incoming request; the sender isn't notified.
    func denyRequest(_ request: PendingRequest) throws {
        var next = safety
        next.pending[request.id] = nil
        try saveSafety(next)
    }

    /// Accepts an incoming request: they become a friend and, if they offered their location, we start receiving it.
    /// A request kept from before a block needs a fresh offer from them, so approving only marks it approved.
    func approveRequest(_ request: PendingRequest, shareBack: Bool = false) async throws {
        guard safety.blocked[request.id] == nil,
              var current = safety.pending[request.id], current.boxID == request.boxID else { return }
        if current.requiresFreshOffer == true {
            current.approved = true
            var next = safety
            next.pending[request.id] = current
            try saveSafety(next)
            return
        }
        try denyRequest(request)
        local.users[request.id] = request.user
        upsertFriend(request.user) {
            if !current.includesLocation || $0.acceptsLocationWithoutNewRequest { $0.establishedWithoutLocation = true }
            if current.includesLocation { $0.receivingBoxID = current.boxID }
            $0.sharedNickname = request.nickname
            $0.avatar = current.avatar ?? $0.avatar
        }
        scheduleBackup()
        if current.includesLocation {
            socket?.watch(current.boxID)
            Task { await fetchPackage(from: current.user, box: current.boxID) }
        }
        Task { try? await send(UserComm(type: .avatarRequest), to: request.user, urgent: false, transient: false) }
        if shareBack, sharesWithNewFriends, local.friends[request.id]?.weShare == false {
            try await startSharing(with: request.user, requiresExistingFriend: true)
        }
    }

    /// Blocks someone: saves the block first (so nothing from them gets through even offline), removes the friendship
    /// on this phone, and tells their phone to drop us. Their pending request is kept so unblocking can restore it.
    func blockUser(_ user: ZoodUser) async throws {
        var next = safety
        let id = user.userID
        guard next.blocked[id] == nil else { return }
        let friend = local.friends[id]
        if let friend {
            if let invites = next.invites { next.invites = InviteLedger.invalidate(id, in: invites) }
            next.pending[id] = PendingRequest(user: user, boxID: friend.receivingBoxID ?? next.pending[id]?.boxID ?? Data(),
                                              nickname: friend.sharedNickname ?? next.pending[id]?.nickname,
                                              requiresFreshOffer: true,
                                              freshOfferAfter: Int64(Date().timeIntervalSince1970 * 1_000))
        } else {
            next.pending[id]?.approved = nil
        }
        next.blocked[id] = user
        var removals = next.sentBlockRemovals ?? [:]
        // An unapproved incoming offer can stay intact. Only an existing friendship needs full removal.
        removals[id] = friend == nil
        next.sentBlockRemovals = removals
        // Persist the block before awaiting network work, so arriving grants cannot re-add them.
        try saveSafety(next)
        try forgetFriend(id, keepRequest: true)
        // Enforce the block locally even offline. Unblock retries the full removal before clearing it.
        try? await deliverBlockRemoval(to: user)
    }

    /// Unblocks someone after making sure the removal reached their phone, so they can't still be receiving our location.
    func unblockUser(_ user: ZoodUser) async throws {
        guard safety.blocked[user.userID] != nil else { return }
        if !ScreenshotTour.isEnabled {
            guard let token = credentials?.accessToken else { return }
            // Also repairs blocks made by clients that sent a one-way revocation or sent nothing.
            try await deliverBlockRemoval(to: user)
            guard credentials?.accessToken == token else { return }
        }
        var next = safety
        next.blocked[user.userID] = nil
        next.sentBlockRemovals?[user.userID] = nil
        try saveSafety(next)
        scheduleBackup()
    }

    /// Asks a friend's phone for a fresh location (Refresh). If nothing answers within 30 seconds the card says so,
    /// because transient requests only reach phones that are online right now.
    func requestLocationUpdate(from friend: Friend) async {
        let sentAt = Date()
        let id = friend.id
        requestStatuses[id] = .sent(sentAt)
        let deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            guard let self, let status = requestStatuses[id],
                  status == .sent(sentAt) || status == .responded(.starting, sentAt) else { return }
            requestStatuses[id] = .noResponse(Date())
        }
        do {
            try await send(UserComm(type: .locationUpdateRequest), to: friend.user, urgent: true, transient: true)
        } catch {
            deadline.cancel()
            if requestStatuses[id] == .sent(sentAt) || requestStatuses[id] == .responded(.starting, sentAt) {
                requestStatuses[id] = .noResponse(Date())
            }
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

    /// A direct negative reply is temporary. An old flag can trigger a probe but can't disable manual refresh.
    func requestCapability(for friend: Friend) -> RequestCapability {
        guard friend.theyShare else { return .notSharing }
        if friend.device?.liveRequests == false,
           let expiration = unavailableUntil[friend.id], expiration > Date() {
            return .unsupported(friend.device?.platform)
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
            if var mine = links[id] {
                if mine.photo == nil, let restored = local.friends[id]?.linkedContact,
                   mine.identifier == restored.identifier, mine.name == restored.name, let photo = restored.photo {
                    mine.photo = photo
                    links[id] = mine
                    changed = true
                }
                local.friends[id]?.linkedContact = mine
            } else if let restored = local.friends[id]?.linkedContact {
                links[id] = restored
                changed = true
            }
        }
        if changed, !ScreenshotTour.isEnabled { ContactLinkStore.save(links, for: account) }
    }

    /// Ask only when a linked card needs its local thumbnail, after the location permission flow.
    func restoreLinkedContactPhotos() async {
        guard !ScreenshotTour.isEnabled, !restoringContactPhotos, let account = credentials?.userID,
              UIApplication.shared.applicationState == .active,
              location.authorization != .notDetermined else { return }
        let missing = friends.filter {
            $0.linkedContact?.photo == nil && $0.linkedContact?.identifier.isEmpty == false
        }.map(\.id)
        guard !missing.isEmpty else { return }
        restoringContactPhotos = true
        defer { restoringContactPhotos = false }
        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            _ = try? await CNContactStore().requestAccess(for: .contacts)
        }
        guard Self.canReadContacts else { return }
        for id in missing {
            guard credentials?.userID == account else { break }
            _ = await restoreContactPhoto(for: id, requestPermission: false)
        }
    }

    private static var canReadContacts: Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized { return true }
        if #available(iOS 18, *) { return status == .limited }
        return false
    }

    /// Rehydrates only the already-linked card's thumbnail using the saved Contacts identifier.
    func restoreContactPhoto(for id: Data, requestPermission: Bool = true) async -> Bool {
        guard !ScreenshotTour.isEnabled, let account = credentials?.userID,
              let link = local.friends[id]?.linkedContact, !link.identifier.isEmpty else { return false }
        if requestPermission, CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            _ = try? await CNContactStore().requestAccess(for: .contacts)
        }
        guard Self.canReadContacts, credentials?.userID == account else { return false }
        let identifier = link.identifier
        let photo = await Task.detached(priority: .utility) {
            try? CNContactStore().unifiedContact(withIdentifier: identifier,
                keysToFetch: [CNContactThumbnailImageDataKey as CNKeyDescriptor]).thumbnailImageData
        }.value
        guard let photo, credentials?.userID == account,
              var restored = local.friends[id]?.linkedContact,
              restored.identifier == identifier else { return false }
        if restored.photo != nil { return true }
        restored.photo = photo
        var links = ContactLinkStore.load(for: account)
        links[id] = restored
        ContactLinkStore.save(links, for: account)
        updateFriend(id) { $0.linkedContact = restored }
        scheduleBackup()
        return true
    }

    /// Links a friend to one of the user's contacts (or unlinks). The friend takes the contact's name, and the link is
    /// kept on this iPhone and in the encrypted backup, never sent to the friend.
    func setLinkedContact(_ contact: LinkedContact?, usePhoto: Bool = true, for id: Data) {
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
            if let contact {
                if usePhoto {
                    friend.avatarOverride = nil
                } else if friend.avatarOverride == nil, friend.useLinkedContactPhoto != false {
                    // Keep the displayed picture even when it came from the previously linked contact.
                    friend.avatarOverride = previous?.photo
                }
                friend.useLinkedContactPhoto = usePhoto
                friend.nickname = Nickname.normalized(contact.name)
            } else {
                friend.useLinkedContactPhoto = nil
                if let previous, friend.nickname == Nickname.normalized(previous.name) {
                    friend.nickname = nil
                }
            }
            friend.linkedContact = contact
        }
        scheduleBackup()
    }

    /// A private photo choice; the friend's own shared avatar is retained as a fallback.
    func setFriendPhoto(_ photo: Data? = nil, useContact: Bool = false, for id: Data) {
        updateFriend(id) {
            $0.avatarOverride = photo
            $0.useLinkedContactPhoto = useContact
        }
        scheduleBackup()
    }

    /// A private name for a friend, visible only to this account.
    func setFriendNickname(_ value: String, for id: Data) {
        updateFriend(id) { $0.nickname = Nickname.normalized(value) }
        scheduleBackup()
    }

    /// Changes the name friends see for us and sends it to every friend right away.
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

    /// Changes our profile photo and sends it to the friends we share with.
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

    /// Looks up a user's public profile, cached so each new sender costs one request.
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

    /// Creates the friend record if needed, applies a change and saves.
    private func upsertFriend(_ user: ZoodUser, _ change: (inout Friend) -> Void) {
        local.users[user.userID] = user
        var friend = local.friends[user.userID] ?? Friend(user: user)
        change(&friend)
        local.friends[user.userID] = friend
        LocalDataStore.save(local)
    }

    /// Applies a change to an existing friend and saves (no-op for unknown friends).
    private func updateFriend(_ id: Data, _ change: (inout Friend) -> Void) {
        guard var friend = local.friends[id] else { return }
        change(&friend)
        // Writing back an identical value still republishes and redraws everything, so don't.
        guard friend != local.friends[id] else { return }
        local.friends[id] = friend
        LocalDataStore.save(local)
    }

    // MARK: - Backup

    /// Debounces backups: many changes in a row produce one upload 3 seconds after the last one.
    private func scheduleBackup() {
        guard !ScreenshotTour.isEnabled else { return }
        backupTask?.cancel()
        backupTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await saveBackup()
        }
    }

    /// Uploads the end-to-end encrypted backup. Skipped (and signs out) if another device now owns the account,
    /// so an old phone can't overwrite the newer device's data.
    private func saveBackup() async {
        guard let credentials else { return }
        // Never overwrite the backup of an account that's now active on another device; sign out instead.
        let remote = await remoteSnapshot()
        guard self.credentials?.accessToken == credentials.accessToken else { return }
        if DeviceSession.isSuperseded(by: remote?.activeDevice, account: credentials.userID) {
            signOutBecauseSupersededElsewhere()
            return
        }
        var snapshot = Snapshot()
        snapshot.preferences = accountPreferences
        snapshot.activeDevice = DeviceSession.record(for: credentials.userID, remote: remote?.activeDevice)
        snapshot.users = local.users.values.map { .init(userId: $0.userID, publicKey: $0.publicKey, username: $0.username) }
        var sharedPhotoBytes = BackupAvatar.totalBytes
        var privatePhotoBytes = BackupAvatar.totalBytes
        snapshot.friends = local.friends.values.sorted { $0.user.username < $1.user.username }.map {
            let override = BackupAvatar.take($0.avatarOverride, from: &privatePhotoBytes)
            return .init(userId: $0.user.userID, sendingBoxId: $0.sendingBoxID, receivingBoxId: $0.receivingBoxID,
                  nickname: $0.nickname, sharedNickname: $0.sharedNickname,
                  avatarThumbnail: BackupAvatar.take($0.avatar, from: &sharedPhotoBytes),
                  linkedContactName: $0.linkedContact?.name,
                  linkedContactId: $0.linkedContact?.identifier,
                  linkedContactPlatform: $0.linkedContact == nil ? nil : "ios",
                  linkedContactPhoto: BackupAvatar.take($0.linkedContact?.photo, from: &privatePhotoBytes),
                  useLinkedContactPhoto: $0.useLinkedContactPhoto,
                  avatarOverride: override,
                  establishedWithoutLocation: $0.acceptsLocationWithoutNewRequest)
        }
        // Blocks, folders and the bar's order ride along in the same end-to-end encrypted backup, so they come
        // back after signing in again.
        snapshot.blocked = safety.blocked.values.map { .init(userId: $0.userID, publicKey: $0.publicKey, username: $0.username) }
        if let invites = safety.invites, !invites.isEmpty { snapshot.invites = invites }
        snapshot.folders = folders.map { .init(id: $0.id.uuidString, name: $0.name, members: $0.members) }
        snapshot.barOrder = barOrder.map(\.backupValue)
        snapshot.nickname = local.myNickname
        snapshot.avatar = local.myAvatar
        snapshot.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        guard let json = try? ZoodJSON.encoder.encode(snapshot),
              let encrypted = try? Crypto.secretBox(json, key: credentials.symmetricKey) else { return }
        do {
            try await api.saveBackup(encrypted)
            UserDefaults.standard.set(true, forKey: Self.thumbnailBackupKey(for: credentials.userID))
        } catch {
            // Leave the upgrade pending so another launch can retry.
        }
    }

    private static func thumbnailBackupKey(for account: Data) -> String {
        "avatarThumbnailBackup.v2." + account.base64EncodedString()
    }

    /// Restores pictures and contact names independently of platform-specific Contacts identifiers.
    private static func localData(from snapshot: Snapshot) -> LocalData {
        var data = LocalData()
        for u in snapshot.users {
            data.users[u.userId] = ZoodUser(userID: u.userId, username: u.username, publicKey: u.publicKey)
        }
        var sharedPhotoBytes = BackupAvatar.totalBytes
        var privatePhotoBytes = BackupAvatar.totalBytes
        for f in snapshot.friends {
            guard let user = data.users[f.userId] else { continue }
            var friend = Friend(user: user, sendingBoxID: f.sendingBoxId, receivingBoxID: f.receivingBoxId,
                                nickname: Nickname.normalized(f.nickname), sharedNickname: Nickname.normalized(f.sharedNickname),
                                establishedWithoutLocation: f.establishedWithoutLocation)
            friend.avatar = BackupAvatar.take(f.avatarThumbnail, from: &sharedPhotoBytes, restoring: true)
            friend.avatarOverride = BackupAvatar.take(f.avatarOverride, from: &privatePhotoBytes, restoring: true)
            friend.useLinkedContactPhoto = f.useLinkedContactPhoto
            if let name = f.linkedContactName, !name.isEmpty {
                // An Android lookup URI means nothing to iOS Contacts, so keep only the name from there.
                friend.linkedContact = LinkedContact(identifier: f.linkedContactPlatform == "ios" ? (f.linkedContactId ?? "") : "",
                                                     name: name, photo: BackupAvatar.take(f.linkedContactPhoto, from: &privatePhotoBytes, restoring: true))
            }
            data.friends[f.userId] = friend
        }
        data.myNickname = Nickname.normalized(snapshot.nickname)
        data.myAvatar = snapshot.avatar
        return data
    }
}
