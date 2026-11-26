import SwiftUI

/// Settings: profile, Live Requests and location permission status, privacy and support links, and the account
/// (blocked users, log out, delete account).
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage("amidstAppearance") private var appearance: AmidstAppearance = .system
    private var folderColumns: Int { model.accountPreferences.folderColumns ?? FolderGrid.defaultColumns }
    private var folderRows: Int { model.accountPreferences.folderRows ?? FolderGrid.defaultRows }

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
                            // Your nickname (if you've set one) with your @username under it.
                            VStack(alignment: .leading, spacing: Spacing.hairline) {
                                if let nickname = model.local.myNickname {
                                    Text(nickname).font(.headline)
                                    Text("@\(model.credentials?.username ?? "")").font(.subheadline).foregroundStyle(.secondary)
                                } else {
                                    Text("@\(model.credentials?.username ?? "")").font(.headline)
                                }
                            }
                        }
                    }
                }

                Section {
                    HStack {
                        SettingsHelpLabel(title: "Share with New Friends", detail: DefaultSharingToggle.explanation)
                        Spacer(minLength: 0)
                        DefaultSharingToggle().labelsHidden()
                    }
                    HStack {
                        SettingsHelpLabel(title: "Live Requests", detail: liveRequestsHelp)
                        Spacer(minLength: 0)
                        Toggle("Live Requests", isOn: $model.liveRequestsEnabled).labelsHidden().tint(.zoodBlue)
                    }
                } header: {
                    Text("Location Sharing").settingsHeaderStyle()
                }

                Section {
                    BackgroundRefreshView(showsStatus: true)
                } header: {
                    BackgroundRefreshHelp().settingsHeaderStyle()
                }

                Section {
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
                } header: {
                    SettingsHelpLabel(title: "Location Access",
                                      detail: "Choose Always in iPhone Settings to share while Amidst is in the background. You can see friends who share with you even with your own location turned off.")
                        .settingsHeaderStyle()
                }

                Section {
                    AppearancePicker()
                } header: {
                    SettingsHelpLabel(title: "Appearance", detail: "System follows the iPhone’s appearance. Light and Dark apply only to Amidst on this device.")
                        .settingsHeaderStyle()
                }

                Section {
                    HStack {
                        SettingsHelpLabel(title: "Folder Columns", detail: "Sets how many people appear across an open folder. Long-press a person in the friend bar and drag them onto another to create a folder.")
                        Spacer(minLength: 0)
                        Text("\(folderColumns)").foregroundStyle(.secondary).monospacedDigit().accessibilityHidden(true)
                        Stepper("Folder Columns", value: Binding(get: { folderColumns }, set: { model.accountPreferences.folderColumns = $0 }), in: FolderGrid.columnRange)
                            .labelsHidden()
                            .accessibilityValue("\(folderColumns)")
                    }
                    HStack {
                        SettingsHelpLabel(title: "Folder Rows", detail: "Sets how many rows are visible in an open folder. Scroll to see additional people.")
                        Spacer(minLength: 0)
                        Text("\(folderRows)").foregroundStyle(.secondary).monospacedDigit().accessibilityHidden(true)
                        Stepper("Folder Rows", value: Binding(get: { folderRows }, set: { model.accountPreferences.folderRows = $0 }), in: FolderGrid.rowRange)
                            .labelsHidden()
                            .accessibilityValue("\(folderRows)")
                    }
                } header: {
                    Text("Friend Bar").settingsHeaderStyle()
                }

                Section {
                    Link("Contact & Support (Public)", destination: AppInformation.issuesURL)
                    Link("Report a Problem", destination: AppInformation.issuesURL)
                    Link("Privacy Policy", destination: AppInformation.privacyPolicyURL)
                } header: {
                    Text("Privacy & Support").settingsHeaderStyle()
                }

                .id("support")

                Section {
                    // Open-Source Licenses lives inside Notices & Trademarks.
                    NavigationLink("Notices & Trademarks") { NoticesView() }
                    // The Zood relationship and other rights notices are in Notices & Trademarks.
                    Link("Source Code (AGPL-3.0)", destination: AppInformation.sourceURL)
                } header: {
                    Text("About").settingsHeaderStyle()
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
        // A sheet resolves its own color-scheme preference independently of the presenting map.
        .preferredColorScheme(appearance.colorScheme)
        .compatFullHeightSheet()
    }

    private var liveRequestsHelp: String {
        if !model.deviceSupportsLiveRequests {
            return String(localized: "Live Requests requires iOS 17 or later. Your location can still update as you move.")
        }
        return DefaultSharingToggle.liveExplanation + " " + String(localized: "Allow Always location access and leave Amidst running to receive requests in the background.")
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

extension View {
    func settingsHeaderStyle() -> some View {
        self
            .textCase(nil)
            .font(.subheadline.bold())
            .foregroundStyle(.primary)
            .accessibilityAddTraits(.isHeader)
            .listRowInsets(EdgeInsets())
    }
}

struct SettingsHelpLabel: View {
    let title: LocalizedStringKey
    let detail: String
    @State private var showingHelp = false

    var body: some View {
        HStack(spacing: Spacing.tight) {
            Text(title).fixedSize(horizontal: false, vertical: true)
            if #available(iOS 16.4, *) {
                helpButton.popover(isPresented: $showingHelp, arrowEdge: .bottom) {
                    explanation.presentationCompactAdaptation(.popover)
                }
            } else {
                helpButton.popover(isPresented: $showingHelp) {
                    explanation
                }
            }
        }
    }

    private var helpButton: some View {
        Button {
            showingHelp.toggle()
        } label: {
            Image(systemName: showingHelp ? "questionmark.circle.fill" : "questionmark.circle")
                .font(.footnote)
                .foregroundStyle(Color.zoodBlueDark)
                .padding(8)
                .contentShape(Rectangle())
                .padding(-8)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("About \(Text(title))"))
    }

    private var explanation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                Text(detail).font(.subheadline)
            }
            .textCase(nil)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.large)
        }
        .frame(idealWidth: 300, idealHeight: 220, maxHeight: 320)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Account submenu: change photo, nickname, blocked users, log out and account deletion, entered from the profile tile in Settings.
struct AccountView: View {
    @EnvironmentObject private var model: AppModel
    /// Closes Settings after logging out.
    let onLogOut: () -> Void
    @State private var confirmingLogOut = false
    @State private var showingDeleteAccount = false
    @State private var showingPhotoPicker = false
    /// A picked photo waiting for the picker to close before its Move and Scale screen opens.
    @State private var pickedPhoto: UIImage?
    @State private var framingPhoto: FramingPhoto?

    private struct FramingPhoto: Identifiable {
        let id = UUID()
        let image: UIImage
    }
    @State private var nicknameDraft: String?

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
                HStack {
                    if nicknameDraft != nil {
                        InlineNameField(label: String(localized: "Nickname"),
                                        text: Binding(get: { nicknameDraft ?? "" }, set: { nicknameDraft = $0 }),
                                        onSave: saveNickname, onCancel: { nicknameDraft = nil })
                    } else {
                        Button { beginNicknameEdit() } label: {
                            HStack {
                                Label("Nickname", systemImage: "person.text.rectangle")
                                Spacer()
                                Text(model.local.myNickname ?? String(localized: "Not Set"))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                    PanelIconButton(systemName: "pencil.circle", tint: UIColor(Color.zoodBlueDark),
                                    accessibilityLabel: String(localized: "Edit Nickname"), action: beginNicknameEdit)
                        .frame(width: 44, height: 44)
                }
                if nicknameDraft != nil {
                    InlineNameActions(onSave: saveNickname, onCancel: { nicknameDraft = nil })
                }
            } footer: {
                Text("Updates for friends using your shared name. Names they've set for you stay unchanged.")
            }
            Section {
                NavigationLink("Blocked Users") { BlockedUsersView().environmentObject(model) }
            }
            Section {
                Button { confirmingLogOut = true } label: {
                    Text("Log Out")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .tint(.zoodBlue)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Button { showingDeleteAccount = true } label: {
                    Text("Delete Account")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .tint(.zoodRed)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .background(
                    NavigationLink(isActive: $showingDeleteAccount) {
                        DeleteAccountView().environmentObject(model)
                    } label: { EmptyView() }
                    .hidden()
                )
            }
        }
        .onAppear {
            if ScreenshotTour.scene == "profile-nickname" { nicknameDraft = model.local.myNickname ?? "Family" }
        }
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
        .navigationTitle(model.local.myNickname ?? model.credentials.map { "@\($0.username)" } ?? String(localized: "Account"))
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

    private func saveNickname() {
        guard let nicknameDraft else { return }
        self.nicknameDraft = nil
        Task { await model.setMyNickname(nicknameDraft) }
    }

    private func beginNicknameEdit() {
        if nicknameDraft == nil { nicknameDraft = model.local.myNickname ?? "" }
    }

}

/// Third-party rights notices: trademarks the app shows or names, and attribution for artwork and code.
/// Full license texts live in the Open-Source Licenses page.
struct NoticesView: View {
    var body: some View {
        List {
            Section("Amidst") {
                notice("Amidst is free software under the GNU Affero General Public License, version 3. It's an independent app built on the open Zood Location protocol and servers. Zood is a trademark of Tangled Wires, LLC; Amidst isn't affiliated with or endorsed by Tangled Wires.")
            }
            Section("Apple") {
                notice("Apple, iPhone and Apple Maps are trademarks of Apple Inc., registered in the U.S. and other countries and regions. Map data and imagery are provided by Apple Maps; see the Legal link on the map.")
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
