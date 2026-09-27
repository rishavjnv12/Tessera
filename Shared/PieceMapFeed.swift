import Foundation
import Observation
import TorrentKit
import TorrentUI

/// Keeps a piece map and file list of one torrent up to date, once per second.
///
/// The engine is queried off the main thread, and only the pieces that changed since
/// the last tick are handed to the UI.
@Observable
final class PieceMapFeed {
    private(set) var map: PieceMap = .empty
    private(set) var files: [TorrentFile] = []
    /// Pieces that changed in the last update, for diagnostics.
    private(set) var lastChangeCount = 0

    private var producer: PieceMapProducer?

    func run(session: TorrentSession, torrentID: String) async {
        map = .empty
        files = []
        let producer = PieceMapProducer(session: session, torrentID: torrentID)
        self.producer = producer
        while !Task.isCancelled {
            apply(await producer.next())
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Shows a priority change right away. The next refresh replaces it with what the engine did.
    func showPriority(_ priority: PiecePriority, pieces ranges: [ClosedRange<Int>]) {
        for range in ranges {
            for i in range where i >= 0 && i < map.pieceCount { map.priority[i] = priority.rawValue }
        }
    }

    /// Fetches everything from the engine now instead of waiting for the next tick.
    func refreshSoon() {
        guard let producer else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(250)) // file priorities apply asynchronously
            await producer.invalidate()
            apply(await producer.next())
        }
    }

    private func apply(_ result: (PieceMapUpdate, [TorrentFile]?)) {
        let (update, files) = result
        if let files, files != self.files { self.files = files }
        switch update {
        case .full(let full):
            map = full
            lastChangeCount = full.pieceCount
        case .delta(let delta):
            map.apply(delta)
            lastChangeCount = delta.count
        case .unchanged:
            lastChangeCount = 0
        }
    }
}

enum PieceMapUpdate: Sendable {
    case full(PieceMap)
    case delta(PieceMapDelta)
    case unchanged
}

/// Runs off the main actor and remembers what it last sent.
actor PieceMapProducer {
    let session: TorrentSession
    let torrentID: String
    private var sent: PieceMap?
    private var fileLayout: [PieceMap.File] = []

    init(session: TorrentSession, torrentID: String) {
        self.session = session
        self.torrentID = torrentID
    }

    /// Forces the next update to be a full map, e.g. after the UI showed a guess.
    func invalidate() {
        sent = nil
    }

    func next() -> (PieceMapUpdate, [TorrentFile]?) {
        let files = session.files(of: torrentID)
        guard let sample = session.pieces(of: torrentID) else { return (.unchanged, files) }
        if fileLayout.isEmpty, let files {
            fileLayout = files.map {
                PieceMap.File(id: $0.index, path: $0.path, size: $0.size,
                              pieces: $0.firstPiece >= 0 ? $0.firstPiece...$0.lastPiece : nil)
            }
        }
        let map = PieceMap(sample, files: fileLayout)
        defer { sent = map }
        if let sent, sent.files == map.files, let delta = sent.delta(to: map) {
            let unchanged = delta.isEmpty && sent.tracksAvailability == map.tracksAvailability
            return (unchanged ? .unchanged : .delta(delta), files)
        }
        return (.full(map), files)
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
