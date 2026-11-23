import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        CompatNavigationStack {
            ScrollViewReader { proxy in
            Form {
                Section {
                    // The tile is just who you are; Change Photo, nickname and the rest live inside Account.
                    NavigationLink {
                        AccountView(onLogOut: { dismiss() }).environmentObject(model)
                    } label: {
                        HStack(spacing: Spacing.medium) {
                            AvatarView(username: model.credentials?.username ?? "?", imageData: model.local.myAvatar, size: 56)
                            Text("@\(model.credentials?.username ?? "")").font(.headline)
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
                        VStack(alignment: .leading, spacing: Spacing.hairline) {
                            Text("Contact & Support")
                            Text("GitHub Issues (public)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Link("Report a Problem", destination: AppInformation.issuesURL)
                    Link("Privacy Policy", destination: AppInformation.privacyPolicyURL)
                }

                .id("support")

                Section("About") {
                    NavigationLink("Notices & Trademarks") { NoticesView() }
                    Link("Open-Source Licenses", destination: AppInformation.licensesURL)
                    // The Zood relationship and other rights notices are in Notices & Trademarks.
                    Link("Source Code (AGPL-3.0)", destination: URL(string: "https://github.com/Emphasize5599/family-locator-ios")!)
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
}

/// Account submenu: change photo, nickname, blocked users, log out and account deletion, entered from the profile tile in Settings.
struct AccountView: View {
    @EnvironmentObject private var model: AppModel
    /// Closes Settings after logging out.
    let onLogOut: () -> Void
    @State private var confirmingLogOut = false
    @State private var showingPhotoPicker = false
    @State private var nickname = ""
    @State private var savingNickname = false

    var body: some View {
        Form {
            Section {
                Button {
                    showingPhotoPicker = true
                } label: {
                    HStack(spacing: Spacing.medium) {
                        AvatarView(username: model.credentials?.username ?? "?", imageData: model.local.myAvatar, size: 44)
                        Text("Change Photo")
                    }
                }
            }
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
        .sheet(isPresented: $showingPhotoPicker) {
            ImagePicker { data in
                showingPhotoPicker = false
                guard let data, let jpeg = Self.avatarJPEG(from: data) else { return }
                Task { await model.setMyAvatar(jpeg) }
            }
        }
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

/// Third-party rights notices: trademarks the app shows or names, and attribution for artwork and code.
/// Full license texts live in the Open-Source Licenses page.
struct NoticesView: View {
    var body: some View {
        List {
            Section("Family Locator") {
                notice("Family Locator is free software under the GNU Affero General Public License, version 3. It's an independent app built on the open Zood Location protocol and servers. Zood is a trademark of Tangled Wires, LLC; Family Locator isn't affiliated with or endorsed by Tangled Wires.")
            }
            Section("Apple") {
                notice("Apple, the Apple logo, iPhone and Apple Maps are trademarks of Apple Inc., registered in the U.S. and other countries and regions. The Apple logo appears only to show that a friend uses an Apple device. Map data and imagery are provided by Apple Maps; see the Legal link on the map.")
            }
            Section("Google") {
                notice("Android is a trademark of Google LLC. The Android logo appears only to show that a friend uses an Android device. Where the Android robot appears, it is reproduced or modified from work created and shared by Google and used according to terms described in the Creative Commons 3.0 Attribution License.")
            }
            Section("Open-Source Software") {
                notice("Encryption uses libsodium by Frank Denis and contributors, under the ISC License.")
                Link("Open-Source Licenses", destination: AppInformation.licensesURL)
            }
        }
        .navigationTitle("Notices & Trademarks")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func notice(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.vertical, Spacing.tight)
    }
}
