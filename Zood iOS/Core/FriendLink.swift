import Foundation

/// Friend links: a shareable link to someone's Amidst profile that lets the recipient send them a friend request.
///
/// The link people share is a web address, because a web link is tappable in every messaging app and still works
/// for someone who doesn't have Amidst yet: the landing page (GitHub Pages, repository `Emphasize5599/amidst`)
/// shows install links and an "Open in Amidst" button that uses the app's own `amidst://` scheme.
///
/// A link carries only the public username. Nothing is sent or shared until the person who opens it confirms in
/// Add Friend, so a link can never add someone or share a location by itself.
nonisolated enum FriendLink {
    /// The landing page for invites that don't name anyone (what Amidst is, with download links).
    static let homeURL = URL(string: "https://emphasize5599.github.io/amidst/")!
    private static let webHost = "emphasize5599.github.io"
    private static let webPath = "/amidst/add"
    static let scheme = "amidst"

    /// The link that opens Add Friend for `username` (e.g. `https://emphasize5599.github.io/amidst/add/?u=alex`).
    static func url(for username: String) -> URL {
        var components = URLComponents(url: homeURL.appendingPathComponent("add/"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "u", value: Username.forLookup(username))]
        return components.url!
    }

    /// The username a link points to, or nil if it isn't a valid friend link. Accepts the web link and the app's
    /// own forms (`amidst://add/alex` and `amidst://add?u=alex`), and only returns names the server could accept.
    static func username(from url: URL) -> String? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = components?.queryItems?.first(where: { $0.name == "u" })?.value
        let candidate: String?
        if url.scheme?.lowercased() == scheme, url.host?.lowercased() == "add" {
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            candidate = path.isEmpty ? query : path
        } else if url.scheme?.lowercased() == "https", url.host?.lowercased() == webHost,
                  url.path.hasPrefix(webPath) {
            candidate = query
        } else {
            candidate = nil
        }
        guard let candidate else { return nil }
        let username = Username.forLookup(candidate)
        return ZoodConstants.isValidUsername(username) ? username : nil
    }
}
