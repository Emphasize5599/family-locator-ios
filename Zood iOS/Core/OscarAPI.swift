import Foundation

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

    func createUser(_ user: NewUser) async throws -> CreateUserResponse {
        try await send("POST", "users", body: user)
    }

    func authChallenge(username: String) async throws -> AuthChallenge {
        try await send("POST", "sessions/\(username.urlPathEscaped)/challenge")
    }

    func completeAuthChallenge(username: String, _ response: FinishedAuthChallenge) async throws -> LoginResponse {
        try await send("POST", "sessions/\(username.urlPathEscaped)/challenge-response", body: response)
    }

    func serverPublicKey() async throws -> ServerPublicKey {
        try await send("GET", "public-key")
    }

    func sessionTicket() async throws -> SessionTicket {
        try await send("POST", "sessions/expiring-tickets")
    }

    // MARK: Backup

    func backup() async throws -> EncryptedData {
        try await send("GET", "users/me/backup")
    }

    func saveBackup(_ data: EncryptedData) async throws {
        try await sendIgnoringBody("PUT", "users/me/backup", body: data)
    }

    /// Permanently deletes the authenticated account and its encrypted backup.
    func deleteAccount() async throws {
        try await sendIgnoringBody("DELETE", "users/me")
    }

    // MARK: Users

    func user(id: Data) async throws -> PublicUserInfo {
        try await send("GET", "users/\(id.hexString)")
    }

    func searchUser(username: String) async throws -> UserSearchResult {
        try await send("GET", "users", query: [URLQueryItem(name: "username", value: username)])
    }

    // MARK: Messages

    func sendMessage(to userID: Data, _ message: OutboundMessage) async throws {
        try await sendIgnoringBody("POST", "users/\(userID.hexString)/messages", body: message)
    }

    func messages() async throws -> [InboxMessage] {
        try await send("GET", "messages")
    }

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
        let boundary = "zood-\(UUID().uuidString)"
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

    private func send<Response: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = []) async throws -> Response {
        let data = try await perform(makeRequest(method, path, query: query))
        return try ZoodJSON.decoder.decode(Response.self, from: data)
    }

    private func send<Body: Encodable, Response: Decodable>(_ method: String, _ path: String, body: Body) async throws -> Response {
        var request = makeRequest(method, path)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try ZoodJSON.encoder.encode(body)
        let data = try await perform(request)
        return try ZoodJSON.decoder.decode(Response.self, from: data)
    }

    private func sendIgnoringBody(_ method: String, _ path: String) async throws {
        _ = try await perform(makeRequest(method, path))
    }

    private func sendIgnoringBody<Body: Encodable>(_ method: String, _ path: String, body: Body) async throws {
        var request = makeRequest(method, path)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try ZoodJSON.encoder.encode(body)
        _ = try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
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
    nonisolated mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}

private extension String {
    nonisolated var urlPathEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? self
    }
}
