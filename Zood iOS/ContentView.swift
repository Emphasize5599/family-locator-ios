import SwiftUI

/// The root screen: onboarding while signed out, the map once signed in. It also forwards the app moving to the
/// foreground or background to the model, which reconnects or pauses syncing to save battery.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            #if DEBUG
            if ScreenshotTour.isEnabled { ScreenshotTourView() }
            else { appContent }
            #else
            appContent
            #endif
        }
        .compatOnChange(of: scenePhase) { phase in
            switch phase {
            case .active: model.sceneDidBecomeActive()
            case .background: model.sceneDidEnterBackground()
            default: break
            }
        }
    }

    @ViewBuilder private var appContent: some View {
        switch model.phase {
        case .signedOut:
            OnboardingView()
        case .signedIn:
            MainView()
        }
    }
}
