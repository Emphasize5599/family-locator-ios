import Foundation

enum AppInformation {
    static let privacyPolicyURL = URL(string: "https://github.com/Emphasize5599/family-locator-ios/blob/main/Docs/PRIVACY.md")!
    static let supportURL = URL(string: "mailto:bens@sanzone.net")!
    static let licensesURL = URL(string: "https://github.com/Emphasize5599/family-locator-ios/blob/main/Docs/LICENSES.md")!
    static let contactEmail = "bens@sanzone.net"

    static func reportURL(username: String = "") -> URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = contactEmail
        components.queryItems = [URLQueryItem(name: "subject", value: username.isEmpty ? "Family Locator: report a problem" : "Family Locator: report user \(username)"),
            URLQueryItem(name: "body", value: "Reported username (if applicable): \(username)\n\nPlease describe the problem. Do not include passwords, keys, or precise locations.\n")]
        return components.url ?? supportURL
    }
}
