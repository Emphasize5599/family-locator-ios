import Foundation

/// Errors from the Zood server. Known server codes get friendly messages so people see "That username is
/// already taken" rather than a raw error number.
nonisolated enum OscarError: Error, LocalizedError {
    case server(code: Int, message: String?)
    case http(status: Int)
    case invalidResponse

    // Codes from george's OscarError.java
    static let invalidUsername = 3
    static let usernameNotAvailable = 10
    static let invalidAccessToken = 15
    static let userNotFound = 16
    static let backupNotFound = 20
    static let invalidEmail = 21

    var code: Int? {
        if case .server(let code, _) = self { return code }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .server(let code, let message):
            switch code {
            case Self.usernameNotAvailable: return "That username is already taken."
            case Self.userNotFound: return "No user with that username exists."
            case Self.invalidUsername: return "Usernames must be 5–32 lowercase letters or numbers."
            case Self.invalidEmail: return "That email address isn't valid."
            default: return message ?? "Server error \(code)."
            }
        case .http(let status): return "Server returned HTTP \(status)."
        case .invalidResponse: return "Unexpected response from server."
        }
    }
}

/// REST client for the Zood "oscar" API server. Stateless apart from the optional access token.
nonisolated struct OscarAPI: Sendable {
    static let host = "api.zood.xyz"
    static let baseURL = URL(string: "https://\(host)/1/")!

    private static let privateSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    var accessToken: String?
    // Authentication responses and encrypted account packages must not enter a persistent URL cache.
    var session: URLSession = Self.privateSession

    // MARK: Auth

    /// Registers a new account. The body carries only public keys and encrypted key material; the password itself
    /// is never sent (it's stretched locally into the key that encrypts the secret key).
    func createUser(_ user: NewUser) async throws -> CreateUserResponse {
        try await send("POST", "users", body: user)
    }

    /// Step 1 of sign-in: the server sends a random challenge encrypted to our public key plus the salt and
    /// encrypted secret key, so only someone who knows the password can answer it.
    func authChallenge(username: String) async throws -> AuthChallenge {
        try await send("POST", "sessions/\(username.urlPathEscaped)/challenge")
    }

    /// Step 2 of sign-in: returns the decrypted challenge, proving we hold the secret key, in exchange for an access token.
    func completeAuthChallenge(username: String, _ response: FinishedAuthChallenge) async throws -> LoginResponse {
        try await send("POST", "sessions/\(username.urlPathEscaped)/challenge-response", body: response)
    }

    /// The server's public key, used to encrypt our answer to the sign-in challenge.
    func serverPublicKey() async throws -> ServerPublicKey {
        try await send("GET", "public-key")
    }

    /// A short-lived ticket for opening the live socket, so the long-lived access token never appears in a URL.
    func sessionTicket() async throws -> SessionTicket {
        try await send("POST", "sessions/expiring-tickets")
    }

    // MARK: Backup

    /// Downloads the end-to-end encrypted account backup (friends, folders, blocks) after signing in on a new phone.
    func backup() async throws -> EncryptedData {
        try await send("GET", "users/me/backup")
    }

    /// Replaces the encrypted backup. The server can't read it; it only stores it so friends and settings survive
    /// a reinstall or a new phone.
    func saveBackup(_ data: EncryptedData) async throws {
        try await sendIgnoringBody("PUT", "users/me/backup", body: data)
    }

    /// Permanently deletes the authenticated account and its encrypted backup.
    func deleteAccount() async throws {
        try await sendIgnoringBody("DELETE", "users/me")
    }

    // MARK: Users

    /// Looks up a user's public profile (username and public key) by ID, e.g. when a message arrives from someone new.
    func user(id: Data) async throws -> PublicUserInfo {
        try await send("GET", "users/\(id.hexString)")
    }

    /// Finds an account by exact username for Add Friend. The server has no fuzzy search, which keeps strangers from
    /// browsing for people.
    func searchUser(username: String) async throws -> UserSearchResult {
        try await send("GET", "users", query: [URLQueryItem(name: "username", value: username)])
    }

    // MARK: Messages

    /// Sends an encrypted message to one user's inbox (requests, grants, profile updates). The server only sees
    /// who it's for, never what it says.
    func sendMessage(to userID: Data, _ message: OutboundMessage) async throws {
        try await sendIgnoringBody("POST", "users/\(userID.hexString)/messages", body: message)
    }

    /// Fetches every message waiting in our inbox; used when the live socket wasn't connected while they arrived.
    func messages() async throws -> [InboxMessage] {
        try await send("GET", "messages")
    }

    /// Removes a processed message from the server so it isn't handled twice and doesn't sit there indefinitely.
    func deleteMessage(id: Int64) async throws {
        try await sendIgnoringBody("DELETE", "messages/\(id)")
    }

    // MARK: Drop boxes

    func pickUpPackage(boxID: Data) async throws -> EncryptedData? {
        // The server answers 200 with an empty body when nothing has been dropped yet.
        let data = try await perform(makeRequest("GET", "drop-boxes/\(boxID.hexString)"))
        guard !data.isEmpty else { return nil }
        return try? ZoodJSON.decoder.decode(EncryptedData.self, from: data)
    }

    /// Mirrors `POST drop-boxes/send`: one multipart part per box, part name = hex box id, body = JSON EncryptedData.
    func dropPackages(_ packages: [Data: EncryptedData]) async throws {
        guard !packages.isEmpty else { return }
        let boundary = "amidst-\(UUID().uuidString)"
        var body = Data()
        for (boxID, pkg) in packages {
            let json = try ZoodJSON.encoder.encode(pkg)
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(boxID.hexString)\"\r\n")
            body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n")
            body.append(json)
            body.append("\r\n")
        }
        body.append("--\(boundary)--\r\n")
        var request = makeRequest("POST", "drop-boxes/send")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        _ = try await perform(request)
    }

    // MARK: Plumbing

    /// Builds a request against the API base URL with the access token header and a 30 s timeout, so a stalled
    /// network surfaces as an error instead of a spinner that never stops.
    private func makeRequest(_ method: String, _ path: String, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 30
        if let accessToken {
            request.setValue(accessToken, forHTTPHeaderField: "X-Oscar-Access-Token")
        }
        return request
    }

    /// Sends a request without a body and decodes the JSON response.
    private func send<Response: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = []) async throws -> Response {
        let data = try await perform(makeRequest(method, path, query: query))
        return try ZoodJSON.decoder.decode(Response.self, from: data)
    }

    /// Sends a JSON body and decodes the JSON response.
    private func send<Body: Encodable, Response: Decodable>(_ method: String, _ path: String, body: Body) async throws -> Response {
        var request = makeRequest(method, path)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try ZoodJSON.encoder.encode(body)
        let data = try await perform(request)
        return try ZoodJSON.decoder.decode(Response.self, from: data)
    }

    /// For endpoints that answer with an empty body (deletes).
    private func sendIgnoringBody(_ method: String, _ path: String) async throws {
        _ = try await perform(makeRequest(method, path))
    }

    /// Sends a JSON body to an endpoint that answers with an empty body.
    private func sendIgnoringBody<Body: Encodable>(_ method: String, _ path: String, body: Body) async throws {
        var request = makeRequest(method, path)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try ZoodJSON.encoder.encode(body)
        _ = try await perform(request)
    }

    /// Runs a request and turns server errors into `OscarError` with the server's own code, so screens can show a
    /// specific message (for example "username taken") instead of a generic failure. Debug screenshot tours never
    /// touch the real server.
    private func perform(_ request: URLRequest) async throws -> Data {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["ZOOD_SCREENSHOT_TOUR"] == nil else { throw URLError(.notConnectedToInternet) }
        #endif
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OscarError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if let err = try? ZoodJSON.decoder.decode(OscarErrorBody.self, from: data) {
                throw OscarError.server(code: err.errorCode, message: err.errorMessage)
            }
            throw OscarError.http(status: http.statusCode)
        }
        return data
    }
}

private extension Data {
    /// Appends UTF-8 text when assembling the multipart upload body by hand.
    nonisolated mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}

private extension String {
    nonisolated var urlPathEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? self
    }
}
