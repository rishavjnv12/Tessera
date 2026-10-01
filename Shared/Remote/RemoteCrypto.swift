import CryptoKit
import Foundation

/// Remote control security.
///
/// Pairing: the phone and the Mac exchange X25519 public keys and derive a long-term key K.
/// Both show a 6-digit code derived from K, and the user approves on the Mac only when the codes
/// match, so a device in the middle cannot pair (it would end up with a different K and code).
///
/// Sessions: each connection derives fresh keys from K and two random nonces, one key per
/// direction. Every message is sealed with ChaCha20-Poly1305 and carries an increasing sequence
/// number, so messages cannot be forged, read, replayed or reflected.
nonisolated enum RemoteCrypto {
    struct Pairing {
        let key: SymmetricKey
        let code: String
    }

    static func pair(privateKey: Curve25519.KeyAgreement.PrivateKey, peerPublicKey: Data,
                     clientPublicKey: Data, serverPublicKey: Data) throws -> Pairing {
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: peerPublicKey))
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("TorrentRemote pairing v1".utf8),
                                                 sharedInfo: clientPublicKey + serverPublicKey, outputByteCount: 32)
        return Pairing(key: key, code: code(for: key))
    }

    /// Six digits, grouped as "123 456".
    static func code(for key: SymmetricKey) -> String {
        let mac = Data(HMAC<SHA256>.authenticationCode(for: Data("pairing code".utf8), using: key))
        let number = mac.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        let digits = String(format: "%06u", number)
        return "\(digits.prefix(3)) \(digits.suffix(3))"
    }

    /// Sent by the Mac after the user approves; proves it holds the same key.
    static func confirmation(for key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("paired v1".utf8), using: key))
    }

    static func sessionKeys(longTermKey: Data, clientNonce: Data, serverNonce: Data)
        -> (clientToServer: SymmetricKey, serverToClient: SymmetricKey) {
        let base = SymmetricKey(data: longTermKey)
        let salt = clientNonce + serverNonce
        func derive(_ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: base, salt: salt, info: Data(label.utf8), outputByteCount: 32)
        }
        return (derive("client to server v1"), derive("server to client v1"))
    }

    static func nonce() -> Data {
        Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
    }
}

extension SymmetricKey {
    nonisolated var data: Data { withUnsafeBytes { Data($0) } }
}

nonisolated enum RemoteError: LocalizedError {
    case badMessage
    case replayed
    case notPaired
    case declined
    case codeMismatch
    case disconnected
    case server(String)

    var errorDescription: String? {
        switch self {
        case .badMessage: String(localized: "The other device sent something unexpected.")
        case .replayed: String(localized: "A message was repeated; the connection was closed for safety.")
        case .notPaired: String(localized: "This device isn’t paired with the Mac anymore. Pair again.")
        case .declined: String(localized: "The Mac didn’t allow pairing.")
        case .codeMismatch: String(localized: "Pairing failed: the devices didn’t agree on a key.")
        case .disconnected: String(localized: "The Mac isn’t reachable.")
        case .server(let message): message
        }
    }
}

/// Encrypts and decrypts one connection's messages.
nonisolated struct SecureChannel {
    let sendKey: SymmetricKey
    let receiveKey: SymmetricKey
    private var sent: UInt64 = 0
    private var received: UInt64 = 0

    init(sendKey: SymmetricKey, receiveKey: SymmetricKey) {
        self.sendKey = sendKey
        self.receiveKey = receiveKey
    }

    mutating func seal(_ message: [String: Any]) throws -> Data {
        sent += 1
        var message = message
        message["seq"] = sent
        return try ChaChaPoly.seal(try WireJSON.encode(message), using: sendKey).combined
    }

    mutating func open(_ data: Data) throws -> [String: Any] {
        let plain = try ChaChaPoly.open(try ChaChaPoly.SealedBox(combined: data), using: receiveKey)
        let message = try WireJSON.decode(plain)
        guard let seq = (message["seq"] as? NSNumber)?.uint64Value, seq > received else { throw RemoteError.replayed }
        received = seq
        return message
    }
}

nonisolated enum WireJSON {
    static func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    static func decode(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RemoteError.badMessage }
        return object
    }

    /// A Codable value (PieceMap, PieceMapDelta) as a JSON object for a message.
    static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: try JSONEncoder().encode(value))
    }

    static func value<T: Decodable>(_ type: T.Type, from object: Any?) throws -> T {
        guard let object else { throw RemoteError.badMessage }
        return try JSONDecoder().decode(T.self, from: try JSONSerialization.data(withJSONObject: object))
    }
}
