import CryptoKit
import Foundation
import Network
import TorrentKit
import TorrentUI

/// A phone asking to pair, waiting for the user's decision on the Mac.
struct PairingRequest: Identifiable {
    let id = UUID()
    let deviceName: String
    /// The code the phone shows; the user allows pairing only when both match.
    let code: String
    let respond: (Bool) -> Void
}

/// Lets paired iPhones and iPads control this Mac's engine over the local network.
/// Advertised with Bonjour; everything after pairing is encrypted (see RemoteCrypto).
@MainActor
final class RemoteServer {
    let session: TorrentSession
    let peers: any PeerStore
    let serverID: String
    let serverName: String
    /// Shows the pairing approval. Without it, pairing requests are declined.
    var onPairingRequest: ((PairingRequest) -> Void)?

    private(set) var port: UInt16?
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: ServerClient] = [:]
    fileprivate var latest: BackendUpdate?
    private var updatesTask: Task<Void, Never>?
    fileprivate var pairingInProgress = false

    init(session: TorrentSession, peers: any PeerStore, serverID: String, serverName: String) {
        self.session = session
        self.peers = peers
        self.serverID = serverID
        self.serverName = serverName
    }

    /// Names of the devices connected right now.
    var connectedDevices: [String] {
        clients.values.compactMap(\.deviceName)
    }

    func start(advertise: Bool = true, port: NWEndpoint.Port = .any) throws {
        let listener = try NWListener(using: WireConnection.parameters(), on: port)
        if advertise {
            listener.service = NWListener.Service(name: serverName, type: RemoteIdentity.serviceType,
                                                  txtRecord: NWTXTRecord(["id": serverID]))
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                if case .ready = state { self?.port = listener.port?.rawValue }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener

        let updates = session.updates()
        updatesTask = Task { [weak self] in
            for await update in updates {
                guard let self else { return }
                self.latest = update
                for client in self.clients.values { client.didUpdate(update) }
            }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        updatesTask?.cancel()
        for client in clients.values { client.close() }
        clients = [:]
    }

    /// Forgets a paired device and drops its connection.
    func unpair(_ id: String) {
        peers.remove(id: id)
        for client in clients.values where client.deviceID == id { client.close() }
    }

    private func accept(_ connection: NWConnection) {
        let client = ServerClient(wire: WireConnection(connection: connection, queue: .main), server: self)
        clients[ObjectIdentifier(client)] = client
        client.start()
    }

    fileprivate func remove(_ client: ServerClient) {
        clients[ObjectIdentifier(client)] = nil
    }
}

@MainActor
private final class ServerClient {
    private let wire: WireConnection
    private weak var server: RemoteServer?
    private var channel: SecureChannel?
    private(set) var deviceID: String?
    private(set) var deviceName: String?
    private var subscribed = false
    private var watched: String?
    private var sentMap: PieceMap?
    private var computingPieces = false

    init(wire: WireConnection, server: RemoteServer) {
        self.wire = wire
        self.server = server
    }

    func start() {
        wire.onMessage = { [weak self] data in MainActor.assumeIsolated { self?.receive(data) } }
        wire.onClose = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.server?.remove(self)
            }
        }
        wire.start()
    }

    func close() {
        wire.close()
    }

    // MARK: Receiving

    private func receive(_ data: Data) {
        if var channel {
            do {
                let message = try channel.open(data)
                self.channel = channel
                handle(message)
            } catch {
                close() // forged, replayed or garbled
            }
            return
        }
        guard let message = try? WireJSON.decode(data), let type = message["type"] as? String else { return close() }
        switch type {
        case "pairRequest": pair(message)
        case "hello": hello(message)
        default: close()
        }
    }

    private func sendPlain(_ message: [String: Any], thenClose: Bool = false) {
        guard let data = try? WireJSON.encode(message) else { return close() }
        wire.send(data, thenClose: thenClose)
    }

    private func send(_ message: [String: Any]) {
        guard var channel, let data = try? channel.seal(message) else { return }
        self.channel = channel
        wire.send(data)
    }

    // MARK: Handshakes

    private func pair(_ message: [String: Any]) {
        guard let server else { return close() }
        guard let deviceID = message["deviceID"] as? String,
              let name = message["deviceName"] as? String,
              let keyString = message["publicKey"] as? String, let clientKey = Data(base64Encoded: keyString),
              !server.pairingInProgress, let ask = server.onPairingRequest else {
            return sendPlain(["type": "pairResult", "ok": false], thenClose: true)
        }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let serverKey = privateKey.publicKey.rawRepresentation
        guard let pairing = try? RemoteCrypto.pair(privateKey: privateKey, peerPublicKey: clientKey,
                                                   clientPublicKey: clientKey, serverPublicKey: serverKey) else { return close() }
        server.pairingInProgress = true
        sendPlain(["type": "pairChallenge", "publicKey": serverKey.base64EncodedString(),
                   "serverID": server.serverID, "serverName": server.serverName])
        var answered = false
        ask(PairingRequest(deviceName: name, code: pairing.code) { [weak self, weak server] allowed in
            guard let self, let server, !answered else { return }
            answered = true
            server.pairingInProgress = false
            // Either way the connection ends; the phone reconnects with "hello" to start a session.
            if allowed {
                server.peers.save(PairedPeer(id: deviceID, name: name, key: pairing.key.data, pairedAt: Date()))
                self.sendPlain(["type": "pairResult", "ok": true,
                                "confirmation": RemoteCrypto.confirmation(for: pairing.key).base64EncodedString()], thenClose: true)
            } else {
                self.sendPlain(["type": "pairResult", "ok": false], thenClose: true)
            }
        })
    }

    private func hello(_ message: [String: Any]) {
        guard let server else { return close() }
        guard let deviceID = message["deviceID"] as? String,
              let nonceString = message["nonce"] as? String, let clientNonce = Data(base64Encoded: nonceString),
              clientNonce.count == 16 else { return close() }
        guard let peer = server.peers.peer(id: deviceID) else {
            return sendPlain(["type": "unknownDevice"], thenClose: true)
        }
        let serverNonce = RemoteCrypto.nonce()
        let keys = RemoteCrypto.sessionKeys(longTermKey: peer.key, clientNonce: clientNonce, serverNonce: serverNonce)
        self.deviceID = deviceID
        deviceName = peer.name
        sendPlain(["type": "welcome", "nonce": serverNonce.base64EncodedString(), "serverName": server.serverName])
        channel = SecureChannel(sendKey: keys.serverToClient, receiveKey: keys.clientToServer)
    }

    // MARK: Session

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "subscribe":
            subscribed = true
            if let latest = server?.latest { sendSnapshot(latest) }
        case "watch":
            watched = message["torrent"] as? String
            sentMap = nil
            sendPieces()
        case "unwatch":
            watched = nil
            sentMap = nil
        case "call":
            guard let id = message["id"] as? Int, let method = message["method"] as? String else { return }
            do {
                let value = try perform(method, message)
                send(["type": "result", "id": id, "ok": true, "value": value ?? NSNull()])
            } catch {
                send(["type": "result", "id": id, "ok": false, "error": error.localizedDescription])
            }
        default:
            break
        }
    }

    func didUpdate(_ update: BackendUpdate) {
        guard channel != nil else { return }
        if subscribed { sendSnapshot(update) }
        sendPieces()
    }

    private func sendSnapshot(_ update: BackendUpdate) {
        send(["type": "snapshot", "torrents": update.torrents.map(\.jsonObject),
              "down": update.downloadRate, "up": update.uploadRate, "dht": update.dhtNodes])
    }

    /// Sends the watched torrent's pieces: the full map first, then only what changed.
    private func sendPieces() {
        guard let torrentID = watched, !computingPieces, let session = server?.session else { return }
        computingPieces = true
        Task {
            let sample = await Task.detached { session.pieces(of: torrentID) }.value
            computingPieces = false
            guard watched == torrentID, let sample else { return }
            let map = PieceMap(sample, files: [])
            if let sentMap, let delta = sentMap.delta(to: map) {
                if !delta.isEmpty || sentMap.tracksAvailability != map.tracksAvailability,
                   let object = try? WireJSON.object(delta) {
                    send(["type": "pieces", "torrent": torrentID, "delta": object])
                }
            } else if let object = try? WireJSON.object(map) {
                send(["type": "pieces", "torrent": torrentID, "full": object])
            }
            self.sentMap = map
        }
    }

    private func perform(_ method: String, _ m: [String: Any]) throws -> Any? {
        guard let session = server?.session else { throw RemoteError.disconnected }
        let torrent = m["torrent"] as? String ?? ""
        switch method {
        case "files": return session.files(of: torrent)?.map(\.jsonObject)
        case "peers": return session.peers(of: torrent)?.map(\.jsonObject)
        case "trackers": return session.trackers(of: torrent)?.map(\.jsonObject)
        case "details": return session.details(of: torrent)?.jsonObject
        case "pause": try session.pauseTorrent(torrent)
        case "resume": try session.resumeTorrent(torrent)
        case "remove": try session.removeTorrent(torrent, deleteFiles: m["deleteFiles"] as? Bool ?? false)
        case "setFilePriority":
            try session.setFilePriority(UInt8(m["priority"] as? Int ?? 4), files: m["files"] as? [Int] ?? [], torrent: torrent)
        case "setPiecePriority":
            guard let first = m["first"] as? Int, let last = m["last"] as? Int, first <= last else { throw RemoteError.badMessage }
            try session.setPiecePriority(UInt8(m["priority"] as? Int ?? 4), pieces: first...last, torrent: torrent)
        case "downloadFromStart": try session.downloadFromStart(file: m["file"] as? Int ?? -1, torrent: torrent)
        case "stopDownloadingFromStart": try session.stopDownloadingFromStart(torrent: torrent)
        case "setSequential": try session.setSequential(m["on"] as? Bool ?? false, torrent: torrent)
        case "addTracker": try session.addTracker(m["url"] as? String ?? "", torrent: torrent)
        case "removeTracker": try session.removeTracker(m["url"] as? String ?? "", torrent: torrent)
        case "addTorrent":
            guard let string = m["data"] as? String, let data = Data(base64Encoded: string) else { throw RemoteError.badMessage }
            return try session.addTorrent(data: data, options: options(m))
        case "addMagnet":
            return try session.addMagnet(m["link"] as? String ?? "", options: options(m))
        default:
            throw RemoteError.badMessage
        }
        return nil
    }

    private func options(_ m: [String: Any]) -> AddTorrentOptions {
        let options = AddTorrentOptions()
        options.startPaused = m["startPaused"] as? Bool ?? false
        options.filePriorities = (m["filePriorities"] as? [Int])?.map(NSNumber.init(value:))
        return options
    }
}
