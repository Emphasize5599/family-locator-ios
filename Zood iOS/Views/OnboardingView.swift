import SwiftUI
import MapKit

/// Sign in to an existing Zood account (shared with Android) or create a new one.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel

    enum Mode: String, CaseIterable, Identifiable {
        case signIn = "Sign In"
        case signUp = "Create Account"
        var id: Self { self }
    }

    @State private var mode: Mode
    @State private var username = ""
    @State private var nickname = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var email = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var usernameLookup: UsernameLookup?
    private let onBack: () -> Void

    init(mode: Mode, onBack: @escaping () -> Void) {
        _mode = State(initialValue: mode)
        self.onBack = onBack
    }

    var body: some View {
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
                    .buttonStyle(.borderedProminent)
                    .tint(mode == .signUp ? .zoodGreen : .zoodBlue)
                    .listRowBackground(Color.clear)
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onBack) {
                        Label("Back", systemImage: "chevron.left")
                            .labelStyle(.iconOnly)
                    }
                }
            }
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

/// Introduces Amidst and previews device appearance before asking for an account.
struct WelcomeTourView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection = 0
    @State private var authMode: OnboardingView.Mode?

    var body: some View {
        content
            .alert("Signed Out", isPresented: $model.signedOutElsewhere) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Your account was signed in on another device, so it was signed out here. Your friends and settings are in your account backup.")
            }
    }

    @ViewBuilder private var content: some View {
        if let authMode {
            OnboardingView(mode: authMode) { self.authMode = nil }
        } else {
            CompatNavigationStack {
                VStack(spacing: Spacing.large) {
                    TabView(selection: $selection) {
                        ScrollView {
                            OnboardingIntro(
                                symbol: "location.circle.fill",
                                title: "Stay close, wherever you are",
                                detail: "See at a glance whether your people are still on the road or safely home. Share your location with family and friends you choose."
                            )
                            .padding(.horizontal, Spacing.large)
                        }
                        .padding(.bottom, 36)
                        .tag(0)

                        ScrollView {
                            OnboardingIntro(
                                symbol: "lock.shield",
                                title: "Your location is yours",
                                detail: "Your phone encrypts the locations you share with friends before sending them. Only the people you share with hold the keys to read them. Amidst and the server can’t decrypt them."
                            )
                            .padding(.horizontal, Spacing.large)
                            VStack(spacing: Spacing.small) {
                                Text("Anyone can audit the source code.")
                                    .foregroundStyle(.secondary)
                                Link("Amidst App Source Code", destination: AppInformation.sourceURL)
                                Link("Zood Server Source Code", destination: AppInformation.serverSourceURL)
                            }
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Spacing.large)
                        }
                        .padding(.bottom, 36)
                        .tag(1)

                        Form {
                            Section {
                                OnboardingIntro(
                                    symbol: "circle.lefthalf.filled",
                                    title: "Appearance",
                                    detail: "Choose how the map and controls look on this iPhone."
                                )
                                .listRowBackground(Color.clear)
                                CentralParkAppearancePreview().listRowInsets(EdgeInsets())
                                AppearancePicker()
                            }
                        }
                        .padding(.bottom, 36)
                        .tag(2)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .always))
                    .indexViewStyle(.page(backgroundDisplayMode: .always))

                    VStack(spacing: Spacing.small) {
                        if selection < 2 {
                            Button("Continue") {
                                withAnimation(reduceMotion ? nil : .easeInOut) { selection += 1 }
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button("Create Account") { authMode = .signUp }
                                .buttonStyle(.borderedProminent)
                        }

                        Button("I Already Have an Account") { authMode = .signIn }
                    }
                    .tint(.zoodBlue)
                    .padding(.bottom, Spacing.large)
                }
                .navigationTitle("Welcome to Amidst")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

/// Account-backed preferences are available once the user signs in.
struct LocationSetupView: View {
    @EnvironmentObject private var model: AppModel
    let onFinish: () -> Void

    var body: some View {
        CompatNavigationStack {
            Form {
                Section {
                    OnboardingIntro(
                        symbol: "location.circle",
                        title: "Location Setup",
                        detail: "Choose how to share with new friends and respond to requests. You can change both settings later."
                    )
                    .listRowBackground(Color.clear)
                }

                Section {
                    DefaultSharingToggle()
                    Toggle("Live Requests", isOn: $model.liveRequestsEnabled).tint(.zoodBlue)
                } footer: {
                    Text(DefaultSharingToggle.explanation + " " + DefaultSharingToggle.liveExplanation)
                }

                Section {
                    Button {
                        if model.location.authorization == .notDetermined {
                            model.location.requestPermission()
                        }
                        onFinish()
                    } label: {
                        Text("Continue").frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.zoodBlue)
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct OnboardingIntro: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        VStack(spacing: Spacing.medium) {
            Image(systemName: symbol)
                .font(.system(size: 48))
                .foregroundStyle(Color.zoodBlue)
                .accessibilityHidden(true)
            Text(title)
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text(detail)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var currentScheme

    var body: some View {
        Picker("Appearance", selection: Binding(get: { appearance }, set: changeAppearance)) {
            Text("System").tag(AmidstAppearance.system)
            Text("Light").tag(AmidstAppearance.light)
            Text("Dark").tag(AmidstAppearance.dark)
        }
        .pickerStyle(.segmented)
    }

    private func changeAppearance(_ newAppearance: AmidstAppearance) {
        guard newAppearance != appearance else { return }
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?.keyWindow
        let systemScheme = window.flatMap { ColorScheme($0.windowScene?.traitCollection.userInterfaceStyle ?? .unspecified) }
        let targetScheme = newAppearance.colorScheme ?? systemScheme
        guard !reduceMotion, targetScheme != currentScheme,
              let window, let snapshot = window.snapshotView(afterScreenUpdates: false) else {
            appearance = newAppearance
            return
        }

        snapshot.frame = window.bounds
        snapshot.isUserInteractionEnabled = false
        snapshot.accessibilityElementsHidden = true
        window.addSubview(snapshot)
        appearance = newAppearance
        DispatchQueue.main.async {
            UIView.animate(withDuration: 0.28, animations: {
                snapshot.alpha = 0
            }, completion: { _ in snapshot.removeFromSuperview() })
        }
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
