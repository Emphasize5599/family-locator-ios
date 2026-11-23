import SwiftUI

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

    var body: some View {
        CompatNavigationStack {
            Form {
                Section {
                    VStack(spacing: Spacing.small) {
                        Image(systemName: "location.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(Color.zoodBlue)
                        Text("Family Locator")
                            .font(.title.bold())
                        Text("End-to-end encrypted location sharing, compatible with Zood Location.")
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
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
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
                        // The keyboard covers the button on smaller phones, so Return submits too.
                        .submitLabel(.go)
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
                        TextField("Nickname (optional)", text: $nickname).textContentType(.nickname)
                        TextField("Email (optional)", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                    }
                } footer: {
                    if mode == .signUp {
                        Text("Usernames are 5–32 lowercase letters or numbers. Your password can't be recovered, so keep it somewhere safe.")
                    } else {
                        Text("Use the same username and password as the Zood app on Android.")
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
                    .disabled(!canSubmit)
                }
                Section {
                    Text("Your location is shared only after you choose a friend or start a timed share. You can view friends without enabling your own location.")
                        .font(.footnote)
                    Link("Privacy Policy", destination: AppInformation.privacyPolicyURL)
                    Link("Support", destination: AppInformation.supportURL)
                }
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
        username.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private var canSubmit: Bool {
        guard !isWorking, !normalizedUsername.isEmpty, !password.isEmpty else { return false }
        if mode == .signUp {
            return ZoodConstants.isValidUsername(normalizedUsername) && password.count >= ZoodConstants.minimumPasswordLength
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
