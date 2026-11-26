import SwiftUI
import MapKit

/// Sign in to an existing Zood account (shared with Android) or create a new one.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel

    private enum Mode: String, CaseIterable, Identifiable {
        case signIn = "Sign In"
        case signUp = "Create Account"
        var id: Self { self }
    }

    @State private var mode: Mode = .signIn
    @State private var username = ""
    @State private var nickname = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var email = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var usernameLookup: UsernameLookup?

    var body: some View {
        content
            .alert("Signed Out", isPresented: $model.signedOutElsewhere) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Your account was signed in on another device, so it was signed out here. Your friends and settings are in your account backup.")
            }
    }

    private var content: some View {
        CompatNavigationStack {
            Form {
                Section {
                    VStack(spacing: Spacing.small) {
                        Image(systemName: "location.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(Color.zoodBlue)
                        Text("Amidst")
                            .font(.title.bold())
                        Text("End-to-end encrypted location sharing for family and friends.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                Section {
                    TextField("Username", text: $username).submitLabel(.done)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if mode == .signUp && ZoodConstants.isValidUsername(normalizedUsername) {
                        UsernameLookupStatus(result: usernameLookup?.username == normalizedUsername ? usernameLookup?.result : nil,
                                             registration: true)
                    }
                    HStack {
                        Group {
                            if showPassword {
                                TextField("Password", text: $password)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            } else {
                                SecureField("Password", text: $password)
                            }
                        }
                        .textContentType(mode == .signUp ? .newPassword : .password)
                        // The keyboard covers the button on smaller phones, so Done submits too.
                        .submitLabel(.done)
                        .onSubmit { if canSubmit { submit() } }

                        // Eye button to reveal the password, like Android's password field.
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showPassword ? Text("Hide password") : Text("Show password"))
                    }
                    if mode == .signUp {
                        TextField("Nickname (optional)", text: $nickname).textContentType(.nickname).submitLabel(.done)
                        TextField("Email (optional)", text: $email).submitLabel(.done)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                    }
                } footer: {
                    if mode == .signUp {
                        Text("Usernames are 5–32 lowercase letters or numbers. Your password can't be recovered, so keep it somewhere safe.")
                    } else {
                        Text("Use the same username and password as Amidst on Android.")
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.zoodRed)
                    }
                }

                Section {
                    Button(action: submit) {
                        HStack {
                            Spacer()
                            if isWorking {
                                ProgressView()
                                Text(mode == .signUp ? "Creating account…" : "Signing in…")
                                    .padding(.leading, 6)
                            } else {
                                Text(mode.rawValue).bold()
                            }
                            Spacer()
                        }
                    }
                    .tint(mode == .signUp ? .zoodGreen : .zoodBlue)
                    .disabled(!canSubmit)
                }
                Section {
                    Text("Your location is shared only after you choose a friend or start a timed share. You can view friends without enabling your own location.")
                        .font(.footnote)
                    Link("Privacy Policy", destination: AppInformation.privacyPolicyURL)
                    Link("Support", destination: AppInformation.supportURL)
                }
            }
            .task(id: mode == .signUp ? normalizedUsername : nil) {
                let entered = normalizedUsername
                guard mode == .signUp, ZoodConstants.isValidUsername(entered) else { return }
                await UsernameLookup.check(entered, registration: true, model: model) { usernameLookup = $0 }
            }
            .disabled(isWorking)
            .compatOnChange(of: mode) { _ in errorMessage = nil }
            // An error like "That username is already taken" is about what was submitted; drop it once the person
            // starts fixing it (but not while a request is in flight).
            .compatOnChange(of: username) { _ in if !isWorking { errorMessage = nil } }
            .compatOnChange(of: password) { _ in if !isWorking { errorMessage = nil } }
        }
    }

    private var normalizedUsername: String {
        // A leading @ is fine to type (it's how usernames are shown); it's removed before anything is sent.
        Username.forLookup(username)
    }

    private var canSubmit: Bool {
        guard !isWorking, !normalizedUsername.isEmpty, !password.isEmpty else { return false }
        if mode == .signUp {
            return ZoodConstants.isValidUsername(normalizedUsername)
                && password.count >= ZoodConstants.minimumPasswordLength
                && !(usernameLookup?.username == normalizedUsername && usernameLookup?.result == .found)
        }
        return true
    }

    private func submit() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                if mode == .signUp {
                    try await model.signUp(username: normalizedUsername, password: password, email: email)
                    if Nickname.normalized(nickname) != nil { await model.setMyNickname(nickname) }
                } else {
                    try await model.logIn(username: normalizedUsername, password: password)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

/// A brief, skippable tour after sign-in. Location access is optional.
struct WelcomeTourView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection = 0
    let onFinish: () -> Void

    private let slides = [
        ("person.crop.circle.badge.plus", "Add Friends", "Find people by username or share an invite with people you trust."),
        ("location.fill", "Share Location", "See where friends are when they choose to share. You can change your own sharing for each friend."),
        ("lock.shield", "Private by Design", "Your shared locations are end-to-end encrypted. Only the people you share with can read them."),
        ("circle.lefthalf.filled", "Appearance", "Choose how the map and controls look on this iPhone."),
        ("location.circle", "Location Setup", "Choose how to share with new friends and respond to requests. You can change both settings later.")
    ]

    var body: some View {
        CompatNavigationStack {
            VStack(spacing: Spacing.large) {
                TabView(selection: $selection) {
                    ForEach(slides.indices, id: \.self) { index in
                        Group {
                            if index == slides.count - 1 {
                                Form {
                                    Section {
                                        slideIntro(index)
                                            .listRowBackground(Color.clear)
                                    }
                                    Section {
                                        DefaultSharingToggle()
                                        Toggle("Live Requests", isOn: $model.liveRequestsEnabled).tint(.zoodBlue)
                                    } footer: {
                                        Text(DefaultSharingToggle.explanation + " " + DefaultSharingToggle.liveExplanation)
                                    }
                                }
                            } else if index == slides.count - 2 {
                                Form {
                                    Section {
                                        slideIntro(index).listRowBackground(Color.clear)
                                        CentralParkAppearancePreview().listRowInsets(EdgeInsets())
                                        AppearancePicker()
                                    }
                                }
                            } else {
                                ScrollView { slideIntro(index).padding(Spacing.large) }
                            }
                        }
                        .padding(.bottom, 36)
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                VStack(spacing: Spacing.small) {
                    if selection < slides.count - 1 {
                        Button("Continue") {
                            withAnimation(reduceMotion ? nil : .easeInOut) { selection += 1 }
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        if model.location.authorization == .notDetermined {
                            Button("Continue with Location") {
                                model.location.requestPermission()
                                onFinish()
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Not Now", action: onFinish)
                        } else {
                            Button("Get Started", action: onFinish)
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .tint(.zoodBlue)
                .padding(.bottom, Spacing.large)
            }
            .navigationTitle("Welcome to Amidst")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip", action: onFinish)
                }
            }
        }
    }

    private func slideIntro(_ index: Int) -> some View {
        VStack(spacing: Spacing.medium) {
            Image(systemName: slides[index].0)
                .font(.system(size: 48))
                .foregroundStyle(Color.zoodBlue)
                .accessibilityHidden(true)
            Text(slides[index].1)
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text(slides[index].2)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(.vertical, Spacing.large)
    }
}

struct DefaultSharingToggle: View {
    @EnvironmentObject private var model: AppModel

    static let explanation = "Share when you choose Approve & Share or someone uses a one-time link you create with sharing on. You can turn off sharing on any friend’s card."
    static let liveExplanation = "Live Requests lets friends you already share with ask your phone for a fresh location. Location and background permissions are managed on this phone."

    var body: some View {
        Toggle(isOn: Binding(get: { model.sharesWithNewFriends }, set: { model.sharesWithNewFriends = $0 })) {
            Text("Share with New Friends")
        }
        .tint(.zoodGreen)
    }
}


enum AmidstAppearance: String, CaseIterable {
    case system, light, dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct AppearancePicker: View {
    @AppStorage("amidstAppearance") private var appearance: AmidstAppearance = .system

    var body: some View {
        Picker("Appearance", selection: $appearance) {
            Text("System").tag(AmidstAppearance.system)
            Text("Light").tag(AmidstAppearance.light)
            Text("Dark").tag(AmidstAppearance.dark)
        }
        .pickerStyle(.segmented)
    }
}

private struct CentralParkAppearancePreview: View {
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.778, longitude: -73.969),
        latitudinalMeters: 2_500, longitudinalMeters: 2_500
    )

    var body: some View {
        Map(coordinateRegion: $region, interactionModes: [])
            .frame(height: 174)
            .overlay(alignment: .topTrailing) {
                VStack(spacing: Spacing.small) {
                    previewButton("gearshape.fill")
                    previewButton("location.fill")
                }
                .padding(Spacing.medium)
            }
            .allowsHitTesting(false)
            .accessibilityLabel("Central Park map appearance preview")
    }

    private func previewButton(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.headline)
            .foregroundStyle(Color.floatingAccent)
            .frame(width: 42, height: 42)
            .floatingSurface(in: Circle())
            .accessibilityHidden(true)
    }
}
