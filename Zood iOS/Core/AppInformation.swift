import Foundation

/// Public links the app shows (privacy policy, licenses, support). App Review requires the privacy policy and a
/// way to contact the developer to be reachable from inside the app.
enum AppInformation {
    static let privacyPolicyURL = URL(string: "https://github.com/Emphasize5599/family-locator-ios/blob/main/Docs/PRIVACY.md?view=policy")!
    static let licensesURL = URL(string: "https://github.com/Emphasize5599/family-locator-ios/blob/main/Docs/LICENSES.md")!
    /// Support, contact and problem reports go to the project's public GitHub Issues page (also the App Store Support URL).
    /// The list opens without a GitHub account; filing a new issue needs one.
    static let issuesURL = URL(string: "https://github.com/Emphasize5599/family-locator-ios/issues")!
    static let supportURL = issuesURL
}
