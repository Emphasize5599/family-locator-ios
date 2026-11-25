import SwiftUI
import BackgroundTasks

/// The largest Dynamic Type size the app follows. Sheets inherit it from the root view.
let maxTextSize = DynamicTypeSize.accessibility1

/// App entry point. Creates the single shared `AppModel` (all account state and syncing) and hands it to every screen.
@main struct MyApp: App {
    @UIApplicationDelegateAdaptor(RefreshDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(delegate.model)
                .tint(.zoodBlue)
                // Text grows with the person's setting up to the first accessibility size. The largest
                // accessibility sizes pushed the map's floating cards and buttons on top of each other, and
                // App Review doesn't require supporting every size; Larger Text up to here still applies.
                .dynamicTypeSize(...maxTextSize)
        }
    }
}

final class RefreshDelegate: NSObject, UIApplicationDelegate {
    static let identifier = "com.bensanzone.amidst.refresh"
    lazy var model = AppModel()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if !ScreenshotTour.isEnabled {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { [weak self] task in
                MainActor.assumeIsolated {
                    guard let self, let refresh = task as? BGAppRefreshTask else {
                        task.setTaskCompleted(success: false)
                        return
                    }
                    self.run(refresh)
                }
            }
        }
        return true
    }

    private func run(_ refresh: BGAppRefreshTask) {
        let work = Task {
            let success = await model.backgroundCatchUp()
            refresh.setTaskCompleted(success: success && !Task.isCancelled)
        }
        refresh.expirationHandler = { work.cancel() }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}
