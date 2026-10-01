import Foundation
import Security

/// A device on the other side of a pairing, with the long-term key both sides derived.
nonisolated struct PairedPeer: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var name: String
    var key: Data
    var pairedAt: Date
}

/// Where pairings are kept: the Keychain in the apps, memory in tests.
nonisolated protocol PeerStore: AnyObject, Sendable {
    func save(_ peer: PairedPeer)
    func peer(id: String) -> PairedPeer?
    func all() -> [PairedPeer]
    func remove(id: String)
}

nonisolated final class KeychainPeerStore: PeerStore, @unchecked Sendable {
    private let service: String

    /// "io.github.rishavjnv12.Tessera.remote.devices" on the Mac, "io.github.rishavjnv12.Tessera.remote.macs" on iPhone.
    init(service: String) {
        self.service = service
    }

    func save(_ peer: PairedPeer) {
        guard let data = try? JSONEncoder().encode(peer) else { return }
        remove(id: peer.id)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: peer.id,
            kSecAttrLabel as String: "Tessera remote: \(peer.name)",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    func peer(id: String) -> PairedPeer? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(PairedPeer.self, from: data)
    }

    func all() -> [PairedPeer] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { ($0[kSecAttrAccount as String] as? String).flatMap(peer(id:)) }
            .sorted { $0.pairedAt < $1.pairedAt }
    }

    func remove(id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

nonisolated final class MemoryPeerStore: PeerStore, @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [String: PairedPeer] = [:]

    init() {}

    func save(_ peer: PairedPeer) { lock.withLock { peers[peer.id] = peer } }
    func peer(id: String) -> PairedPeer? { lock.withLock { peers[id] } }
    func all() -> [PairedPeer] { lock.withLock { Array(peers.values) } }
    func remove(id: String) { _ = lock.withLock { peers.removeValue(forKey: id) } }
}

/// This device's identity for remote control.
nonisolated enum RemoteIdentity {
    static let serviceType = "_tesseraremote._tcp"

    static var deviceID: String {
        let key = "remoteDeviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
}
