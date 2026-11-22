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
        #if DEBUG
        // Layout checks on fresh simulators: SIMCTL_CHILD_ZOOD_LAYOUT_CHECK=timedshare shows the timed sharing sheet
        // even when signed out.
        .sheet(isPresented: .constant(ProcessInfo.processInfo.environment["ZOOD_LAYOUT_CHECK"] == "timedshare")) {
            TimedShareView().environmentObject(model)
        }
        #endif
        .compatOnChange(of: scenePhase) { phase in
            switch phase {
            case .active: model.sceneDidBecomeActive()
            case .background: model.sceneDidEnterBackground()
            default: break
            }
        }
    }
}
