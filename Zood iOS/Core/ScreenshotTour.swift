import SwiftUI

/// Only Debug builds accept tour launch flags. No live credentials or backend session is used.
enum ScreenshotTour {
    #if DEBUG
    static var sceneOverride: String?
    #endif
    static var scene: String? {
        #if DEBUG
        sceneOverride ?? ProcessInfo.processInfo.environment["ZOOD_SCREENSHOT_TOUR"]
        #else
        nil
        #endif
    }
    static var isEnabled: Bool { scene != nil }
    static var isStoreScene: Bool {
        #if DEBUG
        scene.flatMap(StoreTourScene.init(rawValue:)) != nil
        #else
        false
        #endif
    }

    #if DEBUG
    static let friend = Friend(
        user: ZoodUser(userID: Data(repeating: 2, count: 16), username: "alexdemo", publicKey: Data(repeating: 2, count: 32)),
        sendingBoxID: Data(repeating: 3, count: 16), receivingBoxID: Data(repeating: 4, count: 16),
        location: FriendLocation(latitude: 37.8199, longitude: -122.4783, time: Date(), accuracy: 25,
                                 movement: "stationary", batteryLevel: 82, batteryCharging: false),
        device: FriendDevice(platform: .android, liveRequests: true, reportedAt: Date()))
    static let requester = ZoodUser(userID: Data(repeating: 5, count: 16), username: "taylordemo", publicKey: Data(repeating: 5, count: 32))
    static let blocked = ZoodUser(userID: Data(repeating: 6, count: 16), username: "blockeddemo", publicKey: Data(repeating: 6, count: 32))
    static let credentials = Credentials(username: "familydemo", userID: Data(repeating: 1, count: 16), accessToken: "offline-demo",
        keyPair: KeyPair(publicKey: Data(repeating: 1, count: 32), secretKey: Data(repeating: 0, count: 32)),
        symmetricKey: Data(repeating: 0, count: 32), passwordSalt: Data(repeating: 0, count: 16))

    /// A deliberately non-square test photo: a blue square with a yellow circle, plus red/green bands outside
    /// it (above and below when tall, left and right when wide). Framed correctly, only the square shows.
    static func framingTestPhoto(tall: Bool) -> Data? {
        let square: CGFloat = 120, band: CGFloat = 90
        let size = tall ? CGSize(width: square, height: square + 2 * band) : CGSize(width: square + 2 * band, height: square)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemRed.setFill()
            context.fill(tall ? CGRect(x: 0, y: 0, width: square, height: band) : CGRect(x: 0, y: 0, width: band, height: square))
            UIColor.systemGreen.setFill()
            context.fill(tall ? CGRect(x: 0, y: band + square, width: square, height: band) : CGRect(x: band + square, y: 0, width: band, height: square))
            let middle = tall ? CGRect(x: 0, y: band, width: square, height: square) : CGRect(x: band, y: 0, width: square, height: square)
            UIColor.systemBlue.setFill()
            context.fill(middle)
            UIColor.systemYellow.setFill()
            UIBezierPath(ovalIn: middle.insetBy(dx: 15, dy: 15)).fill()
        }
        return image.pngData()
    }
    #endif
}

#if DEBUG
enum StoreTourScene: String {
    case bridgeSouth = "store-bridge-south"
    case bridgeMidspan = "store-bridge-midspan"
    case bridgeNorth = "store-bridge-north"
    case centralPark = "store-central-park"
    case westminster = "store-westminster"
    case griffithPark = "store-griffith-park"
    case requests = "store-requests"

    var bridgeProgress: Double? {
        switch self {
        case .bridgeSouth: 0.10
        case .bridgeMidspan: 0.49
        case .bridgeNorth: 0.86
        default: nil
        }
    }

    var opensFriend: Bool { bridgeProgress != nil || self == .griffithPark }

    func friends() -> [Friend] {
        switch self {
        case .bridgeSouth, .bridgeMidspan, .bridgeNorth:
            var maya = Self.person(40, "Maya", "mayarivera", 37.8079, -122.4755, "vehicle", 71)
            maya.location = bridgeLocation(elapsed: 0, now: .now)
            return [maya,
                    Self.person(41, "Nina", "ninareed", 37.8078, -122.4771, "walking", 84),
                    Self.person(42, "Sam", "samlee", 37.8310, -122.4811, "stationary", 56)]
        case .centralPark, .requests:
            return [Self.person(40, "Amelia", "ameliachen", 40.7735, -73.9706, "walking", 83),
                    Self.person(41, "Jonah", "jonahlee", 40.7750, -73.9725, "running", 62),
                    Self.person(42, "Sam", "samreed", 40.7714, -73.9748, "stationary", 47)]
        case .westminster:
            return [Self.person(40, "Ellie", "ellieshah", 51.5008, -0.1227, "walking", 72),
                    Self.person(41, "Jamie", "jamiepark", 51.5032, -0.1197, "stationary", 65),
                    Self.person(42, "Robin", "robinchen", 51.5017, -0.1255, "cycling", 91)]
        case .griffithPark:
            return [Self.person(40, "Avery", "averynavarro", 34.1183, -118.3003, "walking", 78),
                    Self.person(41, "Jordan", "jordanlee", 34.1197, -118.3016, "stationary", 55),
                    Self.person(42, "Riley", "rileypark", 34.1176, -118.2981, "walking", 92)]
        }
    }

    func bridgeLocation(elapsed: TimeInterval, now: Date) -> FriendLocation? {
        guard let bridgeProgress else { return nil }
        let progress = min(1, bridgeProgress + elapsed / 150)
        return FriendLocation(latitude: 37.8079 + 0.0227 * progress,
                              longitude: -122.4755 - 0.0040 * progress,
                              time: now, accuracy: 8, speed: 17, bearing: 352,
                              movement: "vehicle", batteryLevel: 71, batteryCharging: false)
    }

    private static func person(_ seed: UInt8, _ name: String, _ username: String,
                               _ latitude: Double, _ longitude: Double, _ movement: String, _ battery: Int) -> Friend {
        var friend = ScreenshotTour.friend
        friend.user = ZoodUser(userID: Data(repeating: seed, count: 16), username: username,
                               publicKey: Data(repeating: seed, count: 32))
        friend.nickname = name
        friend.sendingBoxID = seed == 42 ? nil : Data(repeating: seed + 10, count: 16)
        friend.receivingBoxID = Data(repeating: seed + 20, count: 16)
        friend.location = FriendLocation(latitude: latitude, longitude: longitude,
                                         time: .now.addingTimeInterval(-Double((seed - 40) * 25)),
                                         accuracy: 12, movement: movement, batteryLevel: battery, batteryCharging: false)
        friend.device?.platform = seed == 41 ? .android : .ios
        return friend
    }
}

struct TourCaptureRequest: Codable, Equatable {
    var scene: String
    var token: String
    var largeText: Bool
}

struct ScreenshotTourView: View {
    @EnvironmentObject private var model: AppModel
    @State private var request = TourCaptureRequest(scene: ScreenshotTour.scene ?? "map", token: "startup", largeText: false)

    var body: some View {
        ScreenshotTourSceneView(request: request)
            .dynamicTypeSize(request.largeText ? maxTextSize : .large)
            .allowsHitTesting(ProcessInfo.processInfo.environment["ZOOD_TOUR_INTERACTIVE"] == "1")
            .task {
                let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("tour-request.json")
                while !Task.isCancelled {
                    if let data = try? Data(contentsOf: file),
                       let next = try? JSONDecoder().decode(TourCaptureRequest.self, from: data), next != request {
                        ScreenshotTour.sceneOverride = next.scene
                        model.configureTourScene(next.scene)
                        request = next
                    }
                    do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                }
            }
    }
}

private struct ScreenshotTourSceneView: View {
    @EnvironmentObject private var model: AppModel
    let request: TourCaptureRequest
    @State private var showingSheet = false
    @State private var sheetAppeared = false
    private var scene: String { request.scene }

    var body: some View {
        ZStack {
            if scene == "onboarding" { OnboardingView() }
            else { MainView().id(request.token) }
        }
        .sheet(isPresented: $showingSheet) {
            sheetContent
                .dynamicTypeSize(request.largeText ? maxTextSize : .large)
                .id(request.token)
                .onAppear { sheetAppeared = true }
        }
        .task(id: request.token) {
            showingSheet = false
            sheetAppeared = false
            do { try await Task.sleep(nanoseconds: 450_000_000) } catch { return }
            let needsSheet = StoreTourScene(rawValue: scene).map { $0 == .requests } ??
                !["map", "map-many-friends", "map-folders", "map-folders-open", "map-folders-open-long", "map-folders-open-medium", "map-folders-open-rename", "friend-overlap", "friend", "friend-short-name", "friend-two-line-name", "friend-long-name", "friend-updated", "friend-unsupported", "friend-contact-photo", "friend-nickname", "friend-nickname-scroll", "onboarding"].contains(scene)
            showingSheet = needsSheet
            if needsSheet {
                for _ in 0..<50 {
                    if sheetAppeared { break }
                    do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                }
                guard sheetAppeared else { return }
            }
            // Give new cities time to load their Apple Maps tiles before a store capture.
            let delay: UInt64 = ScreenshotTour.isStoreScene ? 4_000_000_000 : 1_500_000_000
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            let ready = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("tour-ready.txt")
            try? request.token.write(to: ready, atomically: true, encoding: .utf8)
        }
        .task(id: request.token) {
            if let scenario = StoreTourScene(rawValue: scene) {
                await model.simulateBridgeDrive(scenario)
            }
        }
    }

    @ViewBuilder private var sheetContent: some View {
            switch scene {
            case "add-friend": AddFriendView()
            case "add-friend-share": AddFriendView(preview: ScreenshotTour.requester)
            case "account", "profile-nickname": CompatNavigationStack { AccountView(onLogOut: {}) }
            case "requests", "requests-empty", "store-requests": RequestsView()
            case "safety-number": SafetyNumberView(friend: ScreenshotTour.friend)
            case "timed-share": TimedShareView()
            case "settings", "settings-support", "settings-nickname": SettingsView()
            case "notices": CompatNavigationStack { NoticesView() }
            case "avatar-crop":
                if let data = ScreenshotTour.framingTestPhoto(tall: true), let image = UIImage(data: data) {
                    AvatarCropView(image: image, onChoose: { _ in }, onCancel: {})
                }
            case "blocked-users", "blocked-empty": CompatNavigationStack { BlockedUsersView() }
            case "delete-account": CompatNavigationStack { DeleteAccountView() }
            default: EmptyView()
            }
    }
}
#endif
