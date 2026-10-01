import CryptoKit
import Foundation
import Network
import Testing
import TesseraKit
import TesseraUI

/// The phone side and the Mac side talking over 127.0.0.1, with real engines.
@MainActor
@Suite(.serialized)
final class RemoteControlTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "RemoteTests-\(UUID().uuidString)")
    private var sessions: [TorrentSession] = []
    private var servers: [RemoteServer] = []
    private var clients: [RemoteBackend] = []

    deinit {
        let sessions = sessions, root = root
        MainActor.assumeIsolated {
            servers.forEach { $0.stop() }
            clients.forEach { $0.disconnect() }
        }
        sessions.forEach { $0.shutdown() }
        try? FileManager.default.removeItem(at: root)
    }

    struct Timeout: Error, CustomStringConvertible { var description: String }

    func waitUntil(_ what: String, timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Timeout(description: "Timed out waiting for \(what)")
    }

    func makeSession(_ name: String) throws -> TorrentSession {
        let settings = SessionSettings()
        settings.listenInterfaces = "127.0.0.1:0"
        settings.enableDHT = false
        settings.enableLSD = false
        settings.enableUPnP = false
        settings.enableNATPMP = false
        let session = try TorrentSession(stateDirectory: root.appending(path: "\(name)-state"),
                                         defaultSavePath: root.appending(path: "\(name)-downloads"), settings: settings)
        sessions.append(session)
        return session
    }

    /// A Mac with one torrent that is downloading (no peers, so it stays incomplete).
    func makeMac(approve: Bool = true, codes: @escaping (String) -> Void = { _ in })
        async throws -> (server: RemoteServer, session: TorrentSession, torrentID: String, fixture: TorrentFixture, endpoint: NWEndpoint) {
        let session = try makeSession("mac")
        let fixture = try TorrentFixture.make(name: "Movie", files: [.init(path: "a.bin", size: 50_000), .init(path: "b.bin", size: 30_000)],
                                              in: root.appending(path: "fixture"))
        let id = try session.addTorrent(data: fixture.torrentData, options: nil)
        let server = RemoteServer(session: session, peers: MemoryPeerStore(), serverID: "mac-1", serverName: "Test Mac")
        server.onPairingRequest = { request in
            codes(request.code)
            request.respond(approve)
        }
        try server.start(advertise: false)
        servers.append(server)
        try await waitUntil("listener ready") { server.port != nil }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: server.port!)!)
        return (server, session, id, fixture, endpoint)
    }

    func connect(_ peer: PairedPeer, _ endpoint: NWEndpoint) -> (RemoteBackend, () -> RemoteBackend.State?, () -> [String]) {
        let client = RemoteBackend(peer: peer, endpoint: endpoint)
        var state: RemoteBackend.State?
        var errors: [String] = []
        client.onStateChange = { state = $0 }
        client.onError = { errors.append($0) }
        client.connect()
        clients.append(client)
        return (client, { state }, { errors })
    }

    // MARK: Crypto

    @Test nonisolated func pairingDerivesTheSameKeyAndCodeOnBothSides() throws {
        let phone = Curve25519.KeyAgreement.PrivateKey()
        let mac = Curve25519.KeyAgreement.PrivateKey()
        let p = phone.publicKey.rawRepresentation, m = mac.publicKey.rawRepresentation
        let a = try RemoteCrypto.pair(privateKey: phone, peerPublicKey: m, clientPublicKey: p, serverPublicKey: m)
        let b = try RemoteCrypto.pair(privateKey: mac, peerPublicKey: p, clientPublicKey: p, serverPublicKey: m)
        #expect(a.key.data == b.key.data)
        #expect(a.code == b.code)
        #expect(a.code.count == 7 && a.code.dropFirst(3).first == " ")
        // Someone in the middle substituting their own key ends up with a different code.
        let intruder = Curve25519.KeyAgreement.PrivateKey()
        let c = try RemoteCrypto.pair(privateKey: phone, peerPublicKey: intruder.publicKey.rawRepresentation,
                                      clientPublicKey: p, serverPublicKey: intruder.publicKey.rawRepresentation)
        #expect(c.code != a.code)
    }

    @Test nonisolated func channelRejectsTamperingReplayAndReflection() throws {
        let key = SymmetricKey(size: .bits256).data
        let keys = RemoteCrypto.sessionKeys(longTermKey: key, clientNonce: RemoteCrypto.nonce(), serverNonce: RemoteCrypto.nonce())
        var phone = SecureChannel(sendKey: keys.clientToServer, receiveKey: keys.serverToClient)
        var mac = SecureChannel(sendKey: keys.serverToClient, receiveKey: keys.clientToServer)

        let first = try phone.seal(["type": "subscribe"])
        #expect(try mac.open(first)["type"] as? String == "subscribe")
        #expect(throws: (any Error).self) { try mac.open(first) } // replayed

        var tampered = try phone.seal(["type": "call"])
        tampered[tampered.count - 1] ^= 1
        #expect(throws: (any Error).self) { try mac.open(tampered) }

        let own = try mac.seal(["type": "snapshot"])
        #expect(throws: (any Error).self) { try mac.open(own) } // reflected back at the sender
        #expect(try phone.open(own)["type"] as? String == "snapshot")
    }

    // MARK: Over the network

    @Test func phoneControlsTheMac() async throws {
        var macCode = ""
        let mac = try await makeMac { macCode = $0 }
        let phoneStore = MemoryPeerStore()
        var phoneCode = ""
        let peer = try await RemotePairing.pair(with: mac.endpoint, deviceName: "Test iPhone", store: phoneStore) { phoneCode = $0 }
        #expect(!phoneCode.isEmpty && phoneCode == macCode, "both screens show the same code")
        #expect(peer.name == "Test Mac" && peer.id == "mac-1")
        #expect(phoneStore.peer(id: "mac-1") != nil)
        #expect(mac.server.peers.peer(id: RemoteIdentity.deviceID)?.name == "Test iPhone")

        let (client, state, errors) = connect(peer, mac.endpoint)
        try await waitUntil("connected") { state() == .connected }
        try await waitUntil("torrent list") { client.allTorrents().map(\.id) == [mac.torrentID] }
        #expect(client.allTorrents().first?.name == "Movie")

        // Piece map arrives, then follows changes made through the remote.
        try await waitUntil("piece map") { client.pieces(of: mac.torrentID)?.pieceCount == mac.fixture.numPieces }
        try await waitUntil("files") { client.files(of: mac.torrentID)?.map(\.name) == ["a.bin", "b.bin"] }
        try client.setPiecePriority(7, pieces: 0...1, torrent: mac.torrentID)
        try await waitUntil("priority on the Mac") {
            mac.session.pieces(of: mac.torrentID).map { [UInt8]($0.priorities).prefix(2) == [7, 7] } ?? false
        }
        try await waitUntil("priority back on the phone") {
            client.pieces(of: mac.torrentID).map { [UInt8]($0.priorities).prefix(2) == [7, 7] } ?? false
        }

        try client.pauseTorrent(mac.torrentID)
        try await waitUntil("paused on the Mac") { mac.session.status(of: mac.torrentID)?.isPaused == true }
        try await waitUntil("paused on the phone") { client.allTorrents().first?.isPaused == true }

        try await waitUntil("details") { client.details(of: mac.torrentID)?.magnetLink.hasPrefix("magnet:") == true }

        // Errors from the Mac come back to the phone.
        try client.downloadFromStart(file: 99, torrent: mac.torrentID)
        try await waitUntil("error reported") { !errors().isEmpty }

        // A second connection with the stored key starts a new session.
        client.disconnect()
        let (again, againState, _) = connect(peer, mac.endpoint)
        try await waitUntil("reconnected") { againState() == .connected }
        try await waitUntil("list again") { again.allTorrents().count == 1 }
    }

    @Test func unknownPhoneIsAskedToPair() async throws {
        let mac = try await makeMac()
        let stranger = PairedPeer(id: "mac-1", name: "Test Mac", key: SymmetricKey(size: .bits256).data, pairedAt: Date())
        let (_, state, _) = connect(stranger, mac.endpoint)
        try await waitUntil("needs pairing") { state() == .needsPairing }
    }

    @Test func wrongKeyNeverConnects() async throws {
        let mac = try await makeMac()
        let peer = try await RemotePairing.pair(with: mac.endpoint, deviceName: "Phone", store: MemoryPeerStore()) { _ in }
        var forged = peer
        forged.key = SymmetricKey(size: .bits256).data
        let (client, state, _) = connect(forged, mac.endpoint)
        try await Task.sleep(for: .seconds(3))
        #expect(state() != .connected || client.allTorrents().isEmpty)
        #expect(client.allTorrents().isEmpty, "nothing readable without the right key")
    }

    @Test func declinedPairingFails() async throws {
        let mac = try await makeMac(approve: false)
        do {
            _ = try await RemotePairing.pair(with: mac.endpoint, deviceName: "Phone", store: MemoryPeerStore()) { _ in }
            Issue.record("pairing should have been declined")
        } catch RemoteError.declined {
            // expected
        } catch {
            Issue.record("expected .declined, got \(error)")
        }
        #expect(mac.server.peers.all().isEmpty)
    }
}
