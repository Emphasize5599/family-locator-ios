import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch model.phase {
            case .signedOut:
                OnboardingView()
            case .signedIn:
                MainView()
            }
        }
        .compatOnChange(of: scenePhase) { phase in
            switch phase {
            case .active: model.sceneDidBecomeActive()
            case .background: model.sceneDidEnterBackground()
            default: break
            }
        }
    }
}
