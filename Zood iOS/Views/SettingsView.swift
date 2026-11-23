import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage(FolderGrid.columnsKey) private var folderColumns = FolderGrid.defaultColumns
    @AppStorage(FolderGrid.rowsKey) private var folderRows = FolderGrid.defaultRows

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

                Section {
                    Stepper(value: $folderColumns, in: FolderGrid.columnRange) {
                        LabeledContentCompat("Folder Columns", value: "\(folderColumns)")
                    }
                    Stepper(value: $folderRows, in: FolderGrid.rowRange) {
                        LabeledContentCompat("Folder Rows", value: "\(folderRows)")
                    }
                } header: {
                    Text("Friend Bar")
                } footer: {
                    Text("Folders open as a \(folderColumns) × \(folderRows) grid; bigger folders scroll. Long-press anyone in the bar to move them, or hold them over someone to make a folder.")
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
                    // Open-Source Licenses lives inside Notices & Trademarks.
                    NavigationLink("Notices & Trademarks") { NoticesView() }
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
    /// A picked photo waiting for the picker to close before its Move and Scale screen opens.
    @State private var pickedPhoto: UIImage?
    @State private var framingPhoto: FramingPhoto?

    private struct FramingPhoto: Identifiable {
        let id = UUID()
        let image: UIImage
    }
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
                TextField("Nickname (optional)", text: $nickname).textContentType(.nickname).submitLabel(.done)
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
        // Pick a photo, then frame it in a circle (Move and Scale, like Contacts) before it's used.
        .sheet(isPresented: $showingPhotoPicker, onDismiss: {
            if let pickedPhoto { framingPhoto = FramingPhoto(image: pickedPhoto) }
            pickedPhoto = nil
        }) {
            ImagePicker { data in
                pickedPhoto = data.flatMap(UIImage.init(data:))
                showingPhotoPicker = false
            }
        }
        .fullScreenCover(item: $framingPhoto) { photo in
            AvatarCropView(image: photo.image, onChoose: { jpeg in
                framingPhoto = nil
                Task { await model.setMyAvatar(jpeg) }
            }, onCancel: { framingPhoto = nil })
        }
        .navigationTitle(model.credentials?.username ?? String(localized: "Account"))
        .navigationBarTitleDisplayMode(.inline)
        .alert("Log out?", isPresented: $confirmingLogOut) {
            Button("Cancel", role: .cancel) {}
            Button("Log Out", role: .destructive) {
                model.logOut()
                onLogOut()
            }
        } message: {
            Text("Your friends are backed up to your account and will come back when you sign in again.")
        }
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

/// A title with a trailing value, like `LabeledContent` (iOS 16+), back to iOS 15.
private struct LabeledContentCompat: View {
    let title: LocalizedStringKey
    let value: String

    init(_ title: LocalizedStringKey, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
