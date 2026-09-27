import Foundation
import ObjectiveC

extension TorrentSession {
    /// Snapshots about once per second. Starts with the latest snapshot if one exists.
    /// Any number of streams can be active. They finish when the session shuts down.
    public func snapshots() -> AsyncStream<SessionSnapshot> {
        hub.makeSnapshotStream()
    }

    /// Events from the moment this is called. They finish when the session shuts down.
    public func events() -> AsyncStream<TorrentEvent> {
        hub.makeEventStream()
    }

    /// Fans the session's single set of callbacks out to any number of async streams.
    private var hub: StreamHub {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        if let hub = objc_getAssociatedObject(self, &hubKey) as? StreamHub {
            return hub
        }
        let hub = StreamHub()
        objc_setAssociatedObject(self, &hubKey, hub, .OBJC_ASSOCIATION_RETAIN)
        snapshotHandler = { [weak hub] in hub?.send($0) }
        eventHandler = { [weak hub] in hub?.send($0) }
        closeHandler = { [weak hub] in hub?.finish() }
        if isClosed { hub.finish() }
        return hub
    }
}

nonisolated(unsafe) private var hubKey: UInt8 = 0

private final class StreamHub: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshotStreams: [UUID: AsyncStream<SessionSnapshot>.Continuation] = [:]
    private var eventStreams: [UUID: AsyncStream<TorrentEvent>.Continuation] = [:]
    private var latest: SessionSnapshot?
    private var finished = false

    deinit {
        finish()
    }

    func makeSnapshotStream() -> AsyncStream<SessionSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: SessionSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        let alreadyFinished = lock.withLock {
            if !finished {
                if let latest { continuation.yield(latest) }
                snapshotStreams[id] = continuation
            }
            return finished
        }
        if alreadyFinished {
            continuation.finish()
        } else {
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.snapshotStreams.removeValue(forKey: id) }
            }
        }
        return stream
    }

    func makeEventStream() -> AsyncStream<TorrentEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: TorrentEvent.self, bufferingPolicy: .bufferingNewest(256))
        let id = UUID()
        let alreadyFinished = lock.withLock {
            if !finished { eventStreams[id] = continuation }
            return finished
        }
        if alreadyFinished {
            continuation.finish()
        } else {
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.eventStreams.removeValue(forKey: id) }
            }
        }
        return stream
    }

    func send(_ snapshot: SessionSnapshot) {
        let streams = lock.withLock {
            latest = snapshot
            return Array(snapshotStreams.values)
        }
        for stream in streams { stream.yield(snapshot) }
    }

    func send(_ event: TorrentEvent) {
        let streams = lock.withLock { Array(eventStreams.values) }
        for stream in streams { stream.yield(event) }
    }

    func finish() {
        let (snapshots, events) = lock.withLock {
            finished = true
            defer {
                snapshotStreams.removeAll()
                eventStreams.removeAll()
            }
            return (Array(snapshotStreams.values), Array(eventStreams.values))
        }
        snapshots.forEach { $0.finish() }
        events.forEach { $0.finish() }
    }
}

extension TorrentStatus: Identifiable {}

extension TorrentFile: Identifiable {
    public var id: Int { index }
}

extension TorrentSession {
    /// Sets the priority of pieces `pieces` (inclusive). 0 skip, 1 lowest, 4 normal, 7 highest.
    public func setPriority(_ priority: UInt8, pieces: ClosedRange<Int>, torrent: String) throws {
        try setPriority(priority, forPieceRange: NSRange(location: pieces.lowerBound, length: pieces.count), torrent: torrent)
    }

    /// Sets the priority of files by `TorrentFile.index`. 0 skip, 1 lowest, 4 normal, 7 highest.
    public func setPriority(_ priority: UInt8, files: some Sequence<Int>, torrent: String) throws {
        try setPriority(priority, forFiles: IndexSet(files), torrent: torrent)
    }
}

extension Peer: Identifiable {
    public var id: String { address }
}

extension Tracker: Identifiable {
    public var id: String { url }
}
