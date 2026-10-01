import Foundation
import Network

/// One TCP connection carrying whole messages, each sent as a 4-byte big-endian length followed
/// by the bytes. Works with Bonjour service endpoints as well as host and port. Callbacks run on
/// `queue`.
nonisolated final class WireConnection: @unchecked Sendable {
    static let maxMessageSize = 32 * 1024 * 1024

    let connection: NWConnection
    let queue: DispatchQueue
    var onReady: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?
    private var closed = false

    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.noDelay = true
        return NWParameters(tls: nil, tcp: tcp)
    }

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    convenience init(to endpoint: NWEndpoint, queue: DispatchQueue) {
        self.init(connection: NWConnection(to: endpoint, using: Self.parameters()), queue: queue)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.receiveHeader()
            case .failed(let error):
                self.finish(error)
            case .cancelled:
                self.finish(nil)
            case .waiting(let error):
                // Not reachable right now (Mac asleep, Wi-Fi off). Report it; the caller retries.
                self.finish(error)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ data: Data) {
        var length = UInt32(data.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(data)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(error) }
        })
    }

    func close() {
        connection.cancel()
    }

    /// Sends a last message, then closes once it has left (closing right away can drop it).
    func send(_ data: Data, thenClose: Bool) {
        guard thenClose else { return send(data) }
        var length = UInt32(data.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(data)
        connection.send(content: frame, completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard let data, data.count == 4, error == nil else { return self.finish(error) }
            let length = Int(data.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard length > 0, length <= Self.maxMessageSize else { return self.finish(RemoteError.badMessage) }
            self.receiveBody(length)
            _ = isComplete
        }
    }

    private func receiveBody(_ length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self else { return }
            guard let data, data.count == length, error == nil else { return self.finish(error) }
            self.onMessage?(data)
            if !self.closed { self.receiveHeader() }
        }
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?(error)
        onReady = nil
        onMessage = nil
        onClose = nil
    }
}
