import SwiftUI

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
