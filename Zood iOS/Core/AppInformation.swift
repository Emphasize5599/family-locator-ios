import Foundation

enum AppInformation {
    static let privacyPolicyURL = URL(string: "https://github.com/Emphasize5599/family-locator-ios/blob/main/Docs/PRIVACY.md?view=policy")!
    static let licensesURL = URL(string: "https://github.com/Emphasize5599/family-locator-ios/blob/main/Docs/LICENSES.md")!
    /// Support, contact and problem reports go to the project's public GitHub Issues page (also the App Store Support URL).
    /// The list opens without a GitHub account; filing a new issue needs one.
    static let issuesURL = URL(string: "https://github.com/Emphasize5599/family-locator-ios/issues")!
    static let supportURL = issuesURL
}
