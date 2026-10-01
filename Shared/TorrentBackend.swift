import Foundation
import TesseraKit
import TesseraUI

/// One refresh of the torrent list, from the local engine or a remote Mac.
struct BackendUpdate: Sendable {
    var torrents: [TorrentStatus]
    var downloadRate: Int64
    var uploadRate: Int64
    var dhtNodes: Int
}

/// What the app's screens need from a torrent engine: this device's own `TorrentSession`, or a
/// Mac controlled over the network (`RemoteBackend`). Methods are synchronous like the engine's;
/// the remote one answers from what it last received and refreshes in the background.
nonisolated protocol TorrentBackend: AnyObject, Sendable {
    /// Shown in the UI, e.g. "This iPhone" or the Mac's name.
    var displayName: String { get }
    var isRemote: Bool { get }
    var listenPort: Int { get }

    func updates() -> AsyncStream<BackendUpdate>
    /// Download-finished events, for notifications. Empty for remote engines.
    func finishedEvents() -> AsyncStream<TorrentEvent>

    func allTorrents() -> [TorrentStatus]
    func pieces(of id: String) -> PieceSnapshot?
    func files(of id: String) -> [TorrentFile]?
    func peers(of id: String) -> [Peer]?
    func trackers(of id: String) -> [Tracker]?
    func details(of id: String) -> TorrentDetails?

    func addTorrent(data: Data, options: AddTorrentOptions?) throws -> String
    func addMagnet(_ link: String, options: AddTorrentOptions?) throws -> String
    func pauseTorrent(_ id: String) throws
    func resumeTorrent(_ id: String) throws
    func removeTorrent(_ id: String, deleteFiles: Bool) throws
    func setFilePriority(_ priority: UInt8, files: [Int], torrent: String) throws
    func setPiecePriority(_ priority: UInt8, pieces: ClosedRange<Int>, torrent: String) throws
    func downloadFromStart(file: Int, torrent: String) throws
    func stopDownloadingFromStart(torrent: String) throws
    func setSequential(_ on: Bool, torrent: String) throws
    func addTracker(_ url: String, torrent: String) throws
    func removeTracker(_ url: String, torrent: String) throws
}

nonisolated extension TorrentSession: TorrentBackend {
    var displayName: String {
        #if os(macOS)
        String(localized: "This Mac")
        #else
        String(localized: "This iPhone")
        #endif
    }

    var isRemote: Bool { false }

    func updates() -> AsyncStream<BackendUpdate> {
        let snapshots = snapshots()
        return AsyncStream { continuation in
            let task = Task {
                for await s in snapshots {
                    continuation.yield(BackendUpdate(torrents: s.torrents, downloadRate: s.downloadRate,
                                                     uploadRate: s.uploadRate, dhtNodes: s.dhtNodes))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func finishedEvents() -> AsyncStream<TorrentEvent> {
        let events = events()
        return AsyncStream { continuation in
            let task = Task {
                for await e in events where e.kind == .finished { continuation.yield(e) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func setFilePriority(_ priority: UInt8, files: [Int], torrent: String) throws {
        try setPriority(priority, files: files, torrent: torrent)
    }

    func setPiecePriority(_ priority: UInt8, pieces: ClosedRange<Int>, torrent: String) throws {
        try setPriority(priority, pieces: pieces, torrent: torrent)
    }
}

extension PieceMap {
    nonisolated init(_ sample: PieceSnapshot, files: [PieceMap.File]) {
        let count = sample.pieceCount
        let fill = [UInt8](sample.fill)
        let priority = [UInt8](sample.priorities)
        let availability = sample.availability.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: UInt16.self).prefix(count))
        }
        self.init(
            pieceLength: sample.pieceLength, totalSize: sample.totalSize,
            fill: fill, priority: priority,
            availability: availability.count == count ? availability : Array(repeating: 0, count: count),
            tracksAvailability: sample.tracksAvailability, files: count > 0 ? files : []
        )
    }
}

extension PieceMap {
    /// The engine-level form, as the remote backend hands it to the piece map feed.
    nonisolated func snapshot(torrentID: String) -> PieceSnapshot {
        PieceSnapshot(
            torrentID: torrentID, pieceLength: pieceLength, totalSize: totalSize,
            fill: Data(fill), priorities: Data(priority),
            availability: availability.withUnsafeBufferPointer { Data(buffer: $0) },
            tracksAvailability: tracksAvailability
        )
    }
}
