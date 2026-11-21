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
    private var runLoop: Task<Void, Never>?
    private(set) var isConnected = false

    init(api: OscarAPI, onEvent: @escaping (SocketEvent) -> Void) {
        self.api = api
        self.onEvent = onEvent
    }

    func start() {
        guard runLoop == nil else { return }
        runLoop = Task { [weak self] in
            var backoff: UInt64 = 2
            while !Task.isCancelled {
                guard let self else { return }
                let started = Date()
                let stop = await self.runOnce()
                if stop || Task.isCancelled { return }
                // A connection that stayed up for a while was healthy; retry quickly after it drops.
                if Date().timeIntervalSince(started) > 60 { backoff = 2 }
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 60)
            }
        }
    }

    func stop() {
        runLoop?.cancel()
        runLoop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        setConnected(false)
    }

    func watch(_ boxID: Data) {
        watched.insert(boxID)
        send(command: Self.cmdWatch, boxID: boxID)
    }

    /// One connection lifetime. Returns `true` if we should stop retrying (bad credentials).
    private func runOnce() async -> Bool {
        let ticket: String
        do {
            ticket = try await api.sessionTicket().ticket
        } catch let error as OscarError where error.code == OscarError.invalidAccessToken {
            onEvent(.invalidToken)
            return true
        } catch {
            return false
        }

        var components = URLComponents(string: "wss://\(OscarAPI.host)/1/sockets")!
        components.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
        let task = URLSession.shared.webSocketTask(with: components.url!)
        self.task = task
        task.resume()

        // Keep-alive pings; the server and NATs drop idle connections otherwise.
        let pinger = Task { [weak task] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                task?.sendPing { _ in }
            }
        }
        defer { pinger.cancel() }

        var first = true
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                if first {
                    // The handshake completes lazily; re-subscribe once it's up.
                    first = false
                    setConnected(true)
                    for box in watched { send(command: Self.cmdWatch, boxID: box) }
                }
                message = try await task.receive()
            } catch {
                break
            }
            if case .data(let data) = message {
                handle(data)
            }
        }
        setConnected(false)
        self.task = nil
        return false
    }

    private func setConnected(_ connected: Bool) {
        guard connected != isConnected else { return }
        isConnected = connected
        onEvent(connected ? .connected : .disconnected)
    }

    private func send(command: UInt8, boxID: Data) {
        guard let task else { return }
        var payload = Data([command])
        payload.append(boxID)
        task.send(.data(payload)) { _ in }
    }

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
        guard type == "message_received", let cipherText, let nonce, let senderId else { return nil }
        return InboxMessage(id: Int64(id ?? "") ?? 0, senderId: senderId, cipherText: cipherText, nonce: nonce,
                            sentDate: Int64(sentDate ?? ""))
    }
}
