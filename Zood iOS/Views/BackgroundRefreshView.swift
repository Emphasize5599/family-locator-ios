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
            if showsStatus {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(statusDescription).foregroundStyle(.secondary)
                }
            } else if status != .restricted && (lowPowerMode || status == .denied) {
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
                .padding(.horizontal, Spacing.large)
                .padding(.vertical, Spacing.small)
                .floatingSurface(in: RoundedRectangle(cornerRadius: 16))
                .alert("Background App Refresh", isPresented: $showingExplanation) {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(Self.helpText(status: status, lowPowerMode: lowPowerMode))
                }
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

    private var statusDescription: LocalizedStringKey {
        if status == .restricted { return "Restricted" }
        if lowPowerMode { return "Paused" }
        return status == .available ? "On" : "Off"
    }

    static func helpText(status: UIBackgroundRefreshStatus, lowPowerMode: Bool) -> String {
        if status == .restricted {
            return String(localized: "iOS has restricted Background App Refresh on this device.")
        }
        if lowPowerMode {
            return String(localized: "Low Power Mode pauses Background App Refresh. Turn off Low Power Mode in Settings > Battery to restore it.")
        }
        return String(localized: "Background App Refresh helps Amidst catch up when iOS gives it time in the background. Manage it in Settings > General > Background App Refresh.")
    }

    private var warningTitle: LocalizedStringKey {
        lowPowerMode ? "Low Power Mode pauses Background App Refresh" : "Background App Refresh is off"
    }

    private func refreshStatus() {
        status = UIApplication.shared.backgroundRefreshStatus
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}

struct BackgroundRefreshHelp: View {
    var body: some View {
        SettingsHelpLabel(title: "Background App Refresh", detail: BackgroundRefreshView.helpText(
            status: UIApplication.shared.backgroundRefreshStatus,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        ))
    }
}
