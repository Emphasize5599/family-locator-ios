import Foundation

/// Friend links: a shareable link to someone's Amidst profile.
///
/// The link people share is a web address, because a web link is tappable in every messaging app and still works
/// for someone who doesn't have Amidst yet: the landing page (GitHub Pages, repository `Emphasize5599/amidst`)
/// shows install links and an "Open in Amidst" button that uses the app's own `amidst://` scheme.
///
/// A one-time link also carries `t`, a random token the inviter stored. Accepting it connects the two people
/// immediately. A link with only the public username still asks the inviter to approve a friend request.
/// Nothing is sent until the person who opens the link confirms in Add Friend.
nonisolated enum FriendLink {
    /// The landing page for invites that don't name anyone (what Amidst is, with download links).
    static let homeURL = URL(string: "https://emphasize5599.github.io/amidst/")!
    private static let webHost = "emphasize5599.github.io"
    private static let webPath = "/amidst/add"
    static let scheme = "amidst"

    /// The link that opens Add Friend for `username`. `token` makes it one-time (`t`); without one it is reusable.
    static func url(for username: String, token: Data? = nil) -> URL {
        var components = URLComponents(url: homeURL.appendingPathComponent("add/"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "u", value: Username.forLookup(username))]
        if let token, let encoded = InviteLedger.queryToken(token) {
            components.fragment = "t=" + encoded
        }
        return components.url!
    }

    /// The username a link points to, or nil if it isn't a valid friend link.
    static func username(from url: URL) -> String? { target(from: url)?.username }

    /// The username and, when the link has a valid `t`, its one-time token. A broken token is ignored so the
    /// username still opens Add Friend as an ordinary request. Accepts the web link and `amidst://add/alex?t=…`.
    static func target(from url: URL) -> FriendLinkTarget? {
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
        guard ZoodConstants.isValidUsername(username) else { return nil }
        let fragment = components?.fragment
        let fromFragment = fragment.flatMap { $0.hasPrefix("t=") ? String($0.dropFirst(2)) : nil }
        let rawToken = fromFragment ?? components?.queryItems?.first(where: { $0.name == "t" })?.value
        let token = rawToken.flatMap(InviteLedger.token(fromQuery:))
        return FriendLinkTarget(username: username, inviteToken: token)
    }
}

/// Who a friend link points to. `inviteToken` is set only for a well-formed one-time link.
nonisolated struct FriendLinkTarget: Equatable, Sendable {
    var username: String
    var inviteToken: Data?
}

/// A friend link waiting for the map screen. Kept on the model so a link opened while signed out still works after sign-in.
nonisolated struct PendingFriendLink: Equatable, Sendable {
    var username: String
    var inviteToken: Data?
}
