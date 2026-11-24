import SwiftUI

/// The largest Dynamic Type size the app follows. Sheets inherit it from the root view.
let maxTextSize = DynamicTypeSize.accessibility1

/// App entry point. Creates the single shared `AppModel` (all account state and syncing) and hands it to every screen.
@main struct MyApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .tint(.zoodBlue)
                // Text grows with the person's setting up to the first accessibility size. The largest
                // accessibility sizes pushed the map's floating cards and buttons on top of each other, and
                // App Review doesn't require supporting every size; Larger Text up to here still applies.
                .dynamicTypeSize(...maxTextSize)
        }
    }
}
