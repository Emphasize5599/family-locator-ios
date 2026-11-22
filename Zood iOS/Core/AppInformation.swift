import Foundation

enum AppInformation {
    static let privacyPolicyURL = URL(string: "https://github.com/Emphasize5599/family-locator-ios/blob/main/Docs/PRIVACY.md")!
    static let licensesURL = URL(string: "https://github.com/Emphasize5599/family-locator-ios/blob/main/Docs/LICENSES.md")!
    /// Support and contact go through the project's public GitHub Issues (also the App Store Support URL).
    static let issuesURL = URL(string: "https://github.com/Emphasize5599/family-locator-ios/issues")!
    static let supportURL = issuesURL

    /// Opens a new GitHub issue with a template. Issues are public, so the template says what not to include.
    static func reportURL(username: String = "") -> URL {
        var components = URLComponents(url: issuesURL.appendingPathComponent("new"), resolvingAgainstBaseURL: false)
        let title = username.isEmpty ? "Problem: " : "Report user: \(username)"
        let body = """
        **This issue is public.** Don't include passwords, encryption keys, precise locations, or timed-sharing links.

        Username being reported (if any): \(username)

        What happened:

        App version / iOS version:

        For account or server-data questions about the Zood service itself, use https://www.zood.xyz/contact
        """
        components?.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
        return components?.url ?? issuesURL
    }
}
