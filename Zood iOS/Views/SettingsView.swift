import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var showingPhotoPicker = false

    var body: some View {
        CompatNavigationStack {
            ScrollViewReader { proxy in
            Form {
                Section {
                    // The tile opens the Account page; Change Photo is its own blue-text button inside it.
                    NavigationLink {
                        AccountView(onLogOut: { dismiss() }).environmentObject(model)
                    } label: {
                        HStack(spacing: 14) {
                            AvatarView(username: model.credentials?.username ?? "?", imageData: model.local.myAvatar, size: 56)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("@\(model.credentials?.username ?? "")").font(.headline)
                                Button("Change Photo") { showingPhotoPicker = true }
                                    .font(.subheadline)
                                    .buttonStyle(.borderless)
                                    .frame(minHeight: 44)
                            }
                        }
                    }
                }

                Section {
                    Toggle(isOn: $model.liveRequestsEnabled) {
                        Label("Live Requests", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .tint(.zoodBlue)
                    if !model.deviceSupportsLiveRequests {
                        Label("Live Requests needs iOS 17 or later. Your location still updates as you move.", systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if model.liveRequestsEnabled && !model.location.hasAlwaysPermission {
                        Button {
                            openURL(URL(string: UIApplication.openSettingsURLString)!)
                        } label: {
                            Label("Allow location access \"Always\" for Live Requests to work", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.zoodOrange)
                        }
                    }
                } header: {
                    Text("Location Requests")
                } footer: {
                    Text("Keeps a low-power connection open in the background so family can tap Refresh to get your current location. Uses a bit more battery. Don't swipe the app closed, or requests will stop until you open it again.")
                }

                Section("Background App Refresh") {
                    BackgroundRefreshView(showsStatus: true)
                }

                Section("Location Access") {
                    HStack {
                        Text("Permission")
                        Spacer()
                        Text(permissionDescription).foregroundStyle(.secondary)
                    }
                    if !model.location.hasAlwaysPermission {
                        Button("Open Settings") {
                            openURL(URL(string: UIApplication.openSettingsURLString)!)
                        }
                    }
                }

                Section("Privacy & Support") {
                    Link(destination: AppInformation.issuesURL) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Contact & Support")
                            Text("GitHub Issues (public)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Link("Report a Problem", destination: AppInformation.issuesURL)
                    Link("Privacy Policy", destination: AppInformation.privacyPolicyURL)
                }

                .id("support")

                Section("About") {
                    Link("Open-Source Licenses", destination: AppInformation.licensesURL)
                    Link("Source Code (AGPL-3.0)", destination: URL(string: "https://github.com/Emphasize5599/family-locator-ios")!)
                    Text("Built on the open-source Zood Location protocol and servers. Not affiliated with Tangled Wires, LLC.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .task {
                #if DEBUG
                if ScreenshotTour.scene == "settings-support" {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    proxy.scrollTo("support", anchor: .top)
                }
                #endif
            }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingPhotoPicker) {
                ImagePicker { data in
                    showingPhotoPicker = false
                    guard let data, let jpeg = Self.avatarJPEG(from: data) else { return }
                    Task { await model.setMyAvatar(jpeg) }
                }
            }
        }
        .compatFullHeightSheet()
    }

    private var permissionDescription: String {
        switch model.location.authorization {
        case .authorizedAlways: return String(localized: "Always")
        case .authorizedWhenInUse: return String(localized: "While Using")
        case .denied, .restricted: return String(localized: "Off")
        default: return String(localized: "Not Set")
        }
    }

    /// Square-crops and downsizes to 256×256 JPEG, roughly what Android's avatar cropper produces.
    private static func avatarJPEG(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let side = min(image.size.width, image.size.height)
        let crop = CGRect(x: (image.size.width - side) / 2, y: (image.size.height - side) / 2, width: side, height: side)
        let target = CGSize(width: 256, height: 256)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(x: -crop.minX * target.width / side, y: -crop.minY * target.height / side,
                                  width: image.size.width * target.width / side,
                                  height: image.size.height * target.height / side))
        }
        return resized.jpegData(compressionQuality: 0.8)
    }
}

/// Account submenu: blocked users, log out and account deletion, entered from the profile tile in Settings.
struct AccountView: View {
    @EnvironmentObject private var model: AppModel
    /// Closes Settings after logging out.
    let onLogOut: () -> Void
    @State private var confirmingLogOut = false
    @State private var nickname = ""
    @State private var savingNickname = false

    var body: some View {
        Form {
            Section {
                TextField("Nickname (optional)", text: $nickname).textContentType(.nickname)
                Button(savingNickname ? "Saving…" : "Save Nickname") {
                    savingNickname = true
                    Task {
                        await model.setMyNickname(nickname)
                        savingNickname = false
                    }
                }
                .disabled(savingNickname || Nickname.normalized(nickname) == model.local.myNickname)
            } footer: {
                Text("Updates for friends using your shared name. Names they've set for you stay unchanged.")
            }
            Section {
                NavigationLink("Blocked Users") { BlockedUsersView().environmentObject(model) }
            }
            Section {
                Button("Log Out", role: .destructive) { confirmingLogOut = true }
                NavigationLink("Delete Account") {
                    DeleteAccountView().environmentObject(model)
                }
                .foregroundStyle(Color.zoodRed)
            }
        }
        .onAppear { nickname = model.local.myNickname ?? "" }
        .navigationTitle(model.credentials?.username ?? String(localized: "Account"))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Log out?", isPresented: $confirmingLogOut, titleVisibility: .visible) {
            Button("Log Out", role: .destructive) {
                model.logOut()
                onLogOut()
            }
        } message: {
            Text("Your friends are backed up to your account and will come back when you sign in again.")
        }
    }
}
