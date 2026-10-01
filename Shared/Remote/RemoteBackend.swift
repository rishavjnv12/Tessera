import CryptoKit
import Foundation
import Network
import Observation
import TesseraKit
import TesseraUI

/// A Mac's engine, controlled over the network. Reads answer from what the Mac last sent and ask
/// for fresh data in the background; the screens poll about once per second, so they catch up.
/// Commands are sent without waiting; failures arrive through `onError`.
nonisolated final class RemoteBackend: TorrentBackend, @unchecked Sendable {
    enum State: Equatable, Sendable {
        case connecting
        case connected
        /// The Mac no longer knows this device (it was removed there).
        case needsPairing
        case unreachable(String)
    }

    let peer: PairedPeer
    let endpoint: NWEndpoint
    var displayName: String { peer.name }
    var isRemote: Bool { true }
    var listenPort: Int { 0 }

    /// Both called on the main actor.
    var onStateChange: (@MainActor @Sendable (State) -> Void)?
    var onError: (@MainActor @Sendable (String) -> Void)?

    private let queue = DispatchQueue(label: "io.github.rishavjnv12.Tessera.remote")

    // Guarded by `lock`: read from any thread by the screens.
    private let lock = NSLock()
    private var torrents: [TorrentStatus] = []
    private var lastUpdate: BackendUpdate?
    private var maps: [String: PieceMap] = [:]
    private var fileCache: [String: [TorrentFile]] = [:]
    private var peerCache: [String: [Peer]] = [:]
    private var trackerCache: [String: [Tracker]] = [:]
    private var detailsCache: [String: TorrentDetails] = [:]
    private var refreshing: Set<String> = []
    private var watched: String?
    private var continuations: [UUID: AsyncStream<BackendUpdate>.Continuation] = [:]

    // Confined to `queue`.
    private var wire: WireConnection?
    private var channel: SecureChannel?
    private var clientNonce = Data()
    private var nextCallID = 1
    private var pending: [Int: (Result<Any?, Error>) -> Void] = [:]
    private var stopped = false
    private var retryDelay: TimeInterval = 1

    init(peer: PairedPeer, endpoint: NWEndpoint) {
        self.peer = peer
        self.endpoint = endpoint
    }

    func connect() {
        queue.async { self.open() }
    }

    func disconnect() {
        queue.async {
            self.stopped = true
            self.wire?.close()
            let streams = self.lock.withLock { () -> [AsyncStream<BackendUpdate>.Continuation] in
                defer { self.continuations = [:] }
                return Array(self.continuations.values)
            }
            streams.forEach { $0.finish() }
        }
    }

    // MARK: Connection

    private func open() {
        guard !stopped else { return }
        report(.connecting)
        channel = nil
        clientNonce = RemoteCrypto.nonce()
        let wire = WireConnection(to: endpoint, queue: queue)
        self.wire = wire
        wire.onReady = { [weak self] in
            guard let self else { return }
            self.sendPlain(["type": "hello", "deviceID": RemoteIdentity.deviceID, "nonce": self.clientNonce.base64EncodedString()])
        }
        wire.onMessage = { [weak self] data in self?.receive(data) }
        wire.onClose = { [weak self] error in self?.closed(error) }
        wire.start()
    }

    private func closed(_ error: Error?) {
        channel = nil
        let failed = pending
        pending = [:]
        failed.values.forEach { $0(.failure(RemoteError.disconnected)) }
        guard !stopped else { return }
        report(.unreachable(error?.localizedDescription ?? RemoteError.disconnected.localizedDescription))
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 15)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.open() }
    }

    private func receive(_ data: Data) {
        if var channel {
            do {
                let message = try channel.open(data)
                self.channel = channel
                handle(message)
            } catch {
                wire?.close()
            }
            return
        }
        guard let message = try? WireJSON.decode(data) else { wire?.close(); return }
        switch message["type"] as? String {
        case "welcome":
            guard let string = message["nonce"] as? String, let serverNonce = Data(base64Encoded: string) else { wire?.close(); return }
            let keys = RemoteCrypto.sessionKeys(longTermKey: peer.key, clientNonce: clientNonce, serverNonce: serverNonce)
            channel = SecureChannel(sendKey: keys.clientToServer, receiveKey: keys.serverToClient)
            retryDelay = 1
            report(.connected)
            send(["type": "subscribe"])
            if let watched = lock.withLock({ watched }) { send(["type": "watch", "torrent": watched]) }
        case "unknownDevice":
            stopped = true
            report(.needsPairing)
            wire?.close()
        default:
            wire?.close()
        }
    }

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "snapshot":
            let list = (message["torrents"] as? [[String: Any]] ?? []).compactMap(TorrentStatus.init(jsonObject:))
            let update = BackendUpdate(torrents: list,
                                       downloadRate: (message["down"] as? NSNumber)?.int64Value ?? 0,
                                       uploadRate: (message["up"] as? NSNumber)?.int64Value ?? 0,
                                       dhtNodes: message["dht"] as? Int ?? 0)
            let streams = lock.withLock { () -> [AsyncStream<BackendUpdate>.Continuation] in
                torrents = list
                lastUpdate = update
                return Array(continuations.values)
            }
            streams.forEach { $0.yield(update) }
        case "pieces":
            guard let id = message["torrent"] as? String else { return }
            if let full = try? WireJSON.value(PieceMap.self, from: message["full"]) {
                lock.withLock { maps[id] = full }
            } else if let delta = try? WireJSON.value(PieceMapDelta.self, from: message["delta"]) {
                lock.withLock { maps[id]?.apply(delta) }
            }
        case "result":
            guard let id = message["id"] as? Int, let completion = pending.removeValue(forKey: id) else { return }
            if message["ok"] as? Bool == true {
                completion(.success(message["value"] is NSNull ? nil : message["value"]))
            } else {
                completion(.failure(RemoteError.server(message["error"] as? String ?? "")))
            }
        default:
            break
        }
    }

    private func sendPlain(_ message: [String: Any]) {
        if let data = try? WireJSON.encode(message) { wire?.send(data) }
    }

    private func send(_ message: [String: Any]) {
        guard var channel, let data = try? channel.seal(message) else { return }
        self.channel = channel
        wire?.send(data)
    }

    private func report(_ state: State) {
        guard let handler = onStateChange else { return }
        Task { @MainActor in handler(state) }
    }

    private func reportError(_ error: Error) {
        guard let handler = onError else { return }
        let message = error.localizedDescription
        Task { @MainActor in handler(message) }
    }

    /// Sends a command. Without a completion, failures go to `onError`.
    private func call(_ method: String, _ arguments: [String: Any] = [:], completion: ((Result<Any?, Error>) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let done = completion ?? { [weak self] result in
                if case .failure(let error) = result { self?.reportError(error) }
            }
            guard self.channel != nil else { return done(.failure(RemoteError.disconnected)) }
            let id = self.nextCallID
            self.nextCallID += 1
            self.pending[id] = done
            var message = arguments
            message["type"] = "call"
            message["id"] = id
            message["method"] = method
            self.send(message)
        }
    }

    /// Returns the cached value and asks the Mac for a fresh one, one request at a time.
    private func cached<T>(_ method: String, _ torrent: String, _ cache: ReferenceWritableKeyPath<RemoteBackend, [String: T]>,
                           decode: @escaping (Any?) -> T?) -> T? {
        let key = "\(method):\(torrent)"
        let (value, start) = lock.withLock { () -> (T?, Bool) in
            let value = self[keyPath: cache][torrent]
            return (value, refreshing.insert(key).inserted)
        }
        if start {
            call(method, ["torrent": torrent]) { [weak self] result in
                guard let self else { return }
                self.lock.withLock {
                    self.refreshing.remove(key)
                    if case .success(let object) = result, let decoded = decode(object) { self[keyPath: cache][torrent] = decoded }
                }
            }
        }
        return value
    }

    // MARK: TorrentBackend

    func updates() -> AsyncStream<BackendUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(of: BackendUpdate.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        lock.withLock {
            if let lastUpdate { continuation.yield(lastUpdate) }
            continuations[id] = continuation
        }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { _ = self.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    func finishedEvents() -> AsyncStream<TorrentEvent> {
        AsyncStream { $0.finish() }
    }

    func allTorrents() -> [TorrentStatus] {
        lock.withLock { torrents }
    }

    func pieces(of id: String) -> PieceSnapshot? {
        let (map, changed) = lock.withLock { () -> (PieceMap?, Bool) in
            let changed = watched != id
            watched = id
            return (maps[id], changed)
        }
        if changed { queue.async { self.send(["type": "watch", "torrent": id]) } }
        return map?.snapshot(torrentID: id)
    }

    func files(of id: String) -> [TorrentFile]? {
        cached("files", id, \.fileCache) { ($0 as? [[String: Any]])?.compactMap(TorrentFile.init(jsonObject:)) }
    }

    func peers(of id: String) -> [Peer]? {
        cached("peers", id, \.peerCache) { ($0 as? [[String: Any]])?.compactMap(Peer.init(jsonObject:)) }
    }

    func trackers(of id: String) -> [Tracker]? {
        cached("trackers", id, \.trackerCache) { ($0 as? [[String: Any]])?.compactMap(Tracker.init(jsonObject:)) }
    }

    func details(of id: String) -> TorrentDetails? {
        cached("details", id, \.detailsCache) { ($0 as? [String: Any]).flatMap(TorrentDetails.init(jsonObject:)) }
    }

    func addTorrent(data: Data, options: AddTorrentOptions?) throws -> String {
        let id = try TorrentPreview(data: data).torrentID
        var arguments: [String: Any] = ["data": data.base64EncodedString(), "startPaused": options?.startPaused ?? false]
        if let priorities = options?.filePriorities { arguments["filePriorities"] = priorities.map(\.intValue) }
        call("addTorrent", arguments)
        return id
    }

    func addMagnet(_ link: String, options: AddTorrentOptions?) throws -> String {
        let id = try TorrentPreview(magnet: link).torrentID
        call("addMagnet", ["link": link, "startPaused": options?.startPaused ?? false])
        return id
    }

    func pauseTorrent(_ id: String) throws { call("pause", ["torrent": id]) }
    func resumeTorrent(_ id: String) throws { call("resume", ["torrent": id]) }

    func removeTorrent(_ id: String, deleteFiles: Bool) throws {
        call("remove", ["torrent": id, "deleteFiles": deleteFiles])
    }

    func setFilePriority(_ priority: UInt8, files: [Int], torrent: String) throws {
        call("setFilePriority", ["torrent": torrent, "priority": Int(priority), "files": files])
    }

    func setPiecePriority(_ priority: UInt8, pieces: ClosedRange<Int>, torrent: String) throws {
        call("setPiecePriority", ["torrent": torrent, "priority": Int(priority), "first": pieces.lowerBound, "last": pieces.upperBound])
    }

    func downloadFromStart(file: Int, torrent: String) throws { call("downloadFromStart", ["torrent": torrent, "file": file]) }
    func stopDownloadingFromStart(torrent: String) throws { call("stopDownloadingFromStart", ["torrent": torrent]) }
    func setSequential(_ on: Bool, torrent: String) throws { call("setSequential", ["torrent": torrent, "on": on]) }
    func addTracker(_ url: String, torrent: String) throws { call("addTracker", ["torrent": torrent, "url": url]) }
    func removeTracker(_ url: String, torrent: String) throws { call("removeTracker", ["torrent": torrent, "url": url]) }
}

// MARK: - Pairing

nonisolated enum RemotePairing {
    /// Pairs with a Mac: exchanges keys, calls `showCode` with the code to compare, and waits for
    /// the user to allow it on the Mac. Saves and returns the Mac as a paired peer.
    static func pair(with endpoint: NWEndpoint, deviceName: String, store: any PeerStore,
                     showCode: @escaping @Sendable (String) -> Void) async throws -> PairedPeer {
        let queue = DispatchQueue(label: "io.github.rishavjnv12.Tessera.pairing")
        let wire = WireConnection(to: endpoint, queue: queue)
        return try await withCheckedThrowingContinuation { continuation in
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            let clientKey = privateKey.publicKey.rawRepresentation
            var pairing: RemoteCrypto.Pairing?
            var server: (id: String, name: String)?
            var finished = false
            func finish(_ result: Result<PairedPeer, Error>) {
                guard !finished else { return }
                finished = true
                wire.close()
                continuation.resume(with: result)
            }
            wire.onReady = {
                let hello: [String: Any] = ["type": "pairRequest", "deviceID": RemoteIdentity.deviceID,
                                            "deviceName": deviceName, "publicKey": clientKey.base64EncodedString()]
                if let data = try? WireJSON.encode(hello) { wire.send(data) }
            }
            wire.onMessage = { data in
                guard let message = try? WireJSON.decode(data) else { return finish(.failure(RemoteError.badMessage)) }
                switch message["type"] as? String {
                case "pairChallenge":
                    guard let keyString = message["publicKey"] as? String, let serverKey = Data(base64Encoded: keyString),
                          let id = message["serverID"] as? String, let name = message["serverName"] as? String,
                          let derived = try? RemoteCrypto.pair(privateKey: privateKey, peerPublicKey: serverKey,
                                                               clientPublicKey: clientKey, serverPublicKey: serverKey) else {
                        return finish(.failure(RemoteError.badMessage))
                    }
                    pairing = derived
                    server = (id, name)
                    showCode(derived.code)
                case "pairResult":
                    guard message["ok"] as? Bool == true else { return finish(.failure(RemoteError.declined)) }
                    guard let pairing, let server,
                          let string = message["confirmation"] as? String, let confirmation = Data(base64Encoded: string),
                          confirmation == RemoteCrypto.confirmation(for: pairing.key) else {
                        return finish(.failure(RemoteError.codeMismatch))
                    }
                    let peer = PairedPeer(id: server.id, name: server.name, key: pairing.key.data, pairedAt: Date())
                    store.save(peer)
                    finish(.success(peer))
                default:
                    finish(.failure(RemoteError.badMessage))
                }
            }
            wire.onClose = { _ in finish(.failure(RemoteError.disconnected)) }
            queue.asyncAfter(deadline: .now() + 180) { finish(.failure(RemoteError.disconnected)) }
            wire.start()
        }
    }
}

// MARK: - Finding Macs

/// Macs on the local network that accept remote control.
@Observable
@MainActor
final class RemoteBrowser {
    struct Mac: Identifiable, Hashable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
    }

    private(set) var macs: [Mac] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: RemoteIdentity.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> Mac? in
                guard case .service(let name, _, _, _) = result.endpoint,
                      case .bonjour(let txt) = result.metadata, let id = txt["id"] else { return nil }
                return Mac(id: id, name: name, endpoint: result.endpoint)
            }
            MainActor.assumeIsolated { self?.macs = found.sorted { $0.name < $1.name } }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
