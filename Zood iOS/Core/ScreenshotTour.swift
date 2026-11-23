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
    #endif
}

#if DEBUG
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
            .dynamicTypeSize(request.largeText ? .accessibility5 : .large)
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
                .dynamicTypeSize(request.largeText ? .accessibility5 : .large)
                .id(request.token)
                .onAppear { sheetAppeared = true }
        }
        .task(id: request.token) {
            showingSheet = false
            sheetAppeared = false
            do { try await Task.sleep(nanoseconds: 450_000_000) } catch { return }
            let needsSheet = !["map", "map-many-friends", "friend", "friend-long-name", "onboarding"].contains(scene)
            showingSheet = needsSheet
            if needsSheet {
                for _ in 0..<50 {
                    if sheetAppeared { break }
                    do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                }
                guard sheetAppeared else { return }
            }
            do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return }
            let ready = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("tour-ready.txt")
            try? request.token.write(to: ready, atomically: true, encoding: .utf8)
        }
    }

    @ViewBuilder private var sheetContent: some View {
            switch scene {
            case "add-friend": AddFriendView()
            case "friend-nickname": FriendNicknameView(friend: ScreenshotTour.friend)
            case "account": CompatNavigationStack { AccountView(onLogOut: {}) }
            case "requests", "requests-empty": RequestsView()
            case "safety-number": SafetyNumberView(friend: ScreenshotTour.friend)
            case "timed-share": TimedShareView()
            case "settings", "settings-support": SettingsView()
            case "blocked-users", "blocked-empty": CompatNavigationStack { BlockedUsersView() }
            case "delete-account": CompatNavigationStack { DeleteAccountView() }
            default: EmptyView()
            }
    }
}
#endif
