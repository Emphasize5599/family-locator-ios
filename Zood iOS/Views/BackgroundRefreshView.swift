import SwiftUI
import UIKit

/// Background App Refresh has no permission prompt; iOS exposes its status and the app's Settings page.
struct BackgroundRefreshView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    let showsStatus: Bool
    @State private var status = UIApplication.shared.backgroundRefreshStatus
    @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var showingExplanation = false

    init(showsStatus: Bool = false) {
        self.showsStatus = showsStatus
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            if status == .restricted {
                // Apple advises against warning users who cannot enable refresh themselves.
                if showsStatus {
                    Label("Background App Refresh is restricted by iOS.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if lowPowerMode || status == .denied {
                Button {
                    showingExplanation = true
                } label: {
                    HStack(spacing: Spacing.small) {
                        Image(systemName: lowPowerMode ? "battery.25" : "arrow.clockwise")
                        Text(warningTitle)
                            .multilineTextAlignment(.leading)
                        Image(systemName: "info.circle")
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.zoodOrange)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, showsStatus ? 0 : Spacing.large)
                .padding(.vertical, showsStatus ? 0 : Spacing.small)
                .floatingSurface(in: RoundedRectangle(cornerRadius: 16))
                .alert("Background App Refresh", isPresented: $showingExplanation) {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    if lowPowerMode {
                        Text("Low Power Mode temporarily turns off Background App Refresh. Turn off Low Power Mode in Settings > Battery to restore it. iOS does not offer a permission prompt for this setting.")
                    } else {
                        Text("Enable Background App Refresh for Family Locator in Settings. If it is unavailable there, go to Settings > General > Background App Refresh and enable it for the system and this app. This helps background updates, but does not guarantee that iOS will keep the app running. Keep Location access set to Always and do not swipe the app closed.")
                    }
                }
            } else if showsStatus {
                Label("Background App Refresh is on", systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { refreshStatus() }
        .compatOnChange(of: scenePhase) { phase in
            if phase == .active { refreshStatus() }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: UIApplication.backgroundRefreshStatusDidChangeNotification) {
                refreshStatus()
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: .NSProcessInfoPowerStateDidChange) {
                refreshStatus()
            }
        }
    }

    private var warningTitle: LocalizedStringKey {
        lowPowerMode ? "Low Power Mode pauses Background App Refresh" : "Background App Refresh is off"
    }

    private func refreshStatus() {
        status = UIApplication.shared.backgroundRefreshStatus
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}
