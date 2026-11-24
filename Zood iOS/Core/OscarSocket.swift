import Foundation

/// Events delivered by the oscar websocket.
nonisolated enum SocketEvent: Sendable {
    case connected
    case disconnected
    /// A friend dropped a package into a box we're watching.
    case package(boxID: Data, EncryptedData)
    /// A message was sent to us (including transient ones like location update requests).
    case message(InboxMessage)
    case invalidToken
}

/// Persistent connection to `wss://api.zood.xyz/1/sockets`. This is what lets the app receive
/// location requests without APNs: as long as the process is alive, the server pushes to us here.
@MainActor
final class OscarSocket {
    private static let cmdWatch: UInt8 = 1
    private static let msgPackage: UInt8 = 1
    private static let msgPushNotification: UInt8 = 2

    private let api: OscarAPI
    private let onEvent: (SocketEvent) -> Void
    private var task: URLSessionWebSocketTask?
    private var watched: Set<Data> = []
    private var generation = UUID()
    private var lastPong: TimeInterval = 0
    private var runLoop: Task<Void, Never>?
    private(set) var isConnected = false

    /// `onEvent` is called on the main actor for every connection change, package and message, so the app model
    /// can update the UI directly.
    init(api: OscarAPI, onEvent: @escaping (SocketEvent) -> Void) {
        self.api = api
        self.onEvent = onEvent
    }

    /// Keeps one live connection open, reconnecting with exponential backoff (2 s doubling to 60 s). Backoff spares
    /// the battery and the shared Zood server when the network is down, instead of retrying in a tight loop.
    func start() {
        guard runLoop == nil else { return }
        let generation = generation
        runLoop = Task { [weak self] in
            var backoff: UInt64 = 2
            while !Task.isCancelled {
                guard let self else { return }
                let started = Date()
                let stop = await self.runOnce(generation: generation)
                if stop || Task.isCancelled { return }
                // A connection that stayed up for a while was healthy; retry quickly after it drops.
                if Date().timeIntervalSince(started) > 60 { backoff = 2 }
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 60)
            }
        }
    }

    /// Closes the connection for good (sign-out, or the app no longer needs live updates). Changing `generation`
    /// makes any in-flight reconnect from the old session give up instead of reopening it.
    func stop() {
        generation = UUID()
        runLoop?.cancel()
        runLoop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        setConnected(false)
    }

    /// Asks the server to push new packages dropped in this box, so a friend's location shows up the moment they
    /// share it instead of on the next poll. Remembered so it can be re-sent after a reconnect.
    func watch(_ boxID: Data) {
        watched.insert(boxID)
        send(command: Self.cmdWatch, boxID: boxID)
    }

    /// One connection lifetime. A pong or server message confirms that the handshake completed.
    private func runOnce(generation: UUID) async -> Bool {
        let url: URL
        do {
            let ticket = try await api.sessionTicket().ticket
            var components = URLComponents(string: "wss://\(OscarAPI.host)/1/sockets")!
            components.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
            url = components.url!
        } catch let error as OscarError where error.code == OscarError.invalidAccessToken {
            if self.generation == generation { onEvent(.invalidToken) }
            return true
        } catch {
            return false
        }
        guard self.generation == generation, !Task.isCancelled else { return true }

        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        lastPong = ProcessInfo.processInfo.systemUptime
        let pinger = Task { [weak self] in
            while !Task.isCancelled {
                task.sendPing { error in
                    Task { @MainActor [weak self] in
                        guard let self, self.task === task else { return }
                        if error != nil {
                            task.cancel()
                        } else {
                            self.lastPong = ProcessInfo.processInfo.systemUptime
                            self.didConnect()
                        }
                    }
                }
                do { try await Task.sleep(nanoseconds: 12_000_000_000) } catch { return }
                if let self, ProcessInfo.processInfo.systemUptime - self.lastPong >= 12 {
                    task.cancel()
                    return
                }
            }
        }
        defer {
            pinger.cancel()
            task.cancel()
            if self.task === task {
                self.task = nil
                setConnected(false)
            }
        }
        while !Task.isCancelled, self.task === task {
            guard let message = try? await task.receive(), self.task === task else { break }
            didConnect()
            if case .data(let data) = message { handle(data) }
        }
        return false
    }

    /// Called on the first sign of a working connection. The server forgets watches when a socket closes, so
    /// every watched box is registered again here.
    private func didConnect() {
        guard !isConnected else { return }
        for box in watched { send(command: Self.cmdWatch, boxID: box) }
        setConnected(true)
    }

    /// Reports connection changes only when they actually change, so the UI doesn't flicker on every ping.
    private func setConnected(_ connected: Bool) {
        guard connected != isConnected else { return }
        isConnected = connected
        onEvent(connected ? .connected : .disconnected)
    }

    /// Wire format: one command byte followed by the 16-byte box ID (matches the Zood server).
    private func send(command: UInt8, boxID: Data) {
        guard let task else { return }
        var payload = Data([command])
        payload.append(boxID)
        task.send(.data(payload)) { _ in }
    }

    /// Decodes one server frame: the first byte says whether it's a dropped package or a message for us.
    /// Anything malformed is ignored, because a bad frame must never crash the app or show bogus data.
    private func handle(_ data: Data) {
        guard data.count >= 3, let kind = data.first else { return }
        let body = data.dropFirst()
        switch kind {
        case Self.msgPackage:
            let idLength = ZoodConstants.dropBoxIDLength
            guard body.count >= idLength + 2 else { return }
            let boxID = Data(body.prefix(idLength))
            guard let pkg = try? ZoodJSON.decoder.decode(EncryptedData.self, from: Data(body.dropFirst(idLength))) else { return }
            onEvent(.package(boxID: boxID, pkg))
        case Self.msgPushNotification:
            guard let push = try? ZoodJSON.decoder.decode(SocketPush.self, from: Data(body)),
                  let message = push.inboxMessage else { return }
            onEvent(.message(message))
        default:
            break
        }
    }
}

/// The server sends message pushes as a string map (see oscar `pushMessageToUser`).
private nonisolated struct SocketPush: Decodable {
    var id: String?
    var cipherText: Data?
    var nonce: Data?
    var senderId: Data?
    var sentDate: String?
    var type: String?

    var inboxMessage: InboxMessage? {
        guard type == nil || type == "message_received",
              let cipherText, !cipherText.isEmpty, let nonce, !nonce.isEmpty,
              let senderId, senderId.count == ZoodConstants.userIDLength else { return nil }
        return InboxMessage(id: Int64(id ?? "") ?? 0, senderId: senderId, cipherText: cipherText, nonce: nonce,
                            sentDate: Int64(sentDate ?? ""))
    }
}
