import Foundation
import Testing
import TesseraKit

/// Offline tests. Torrents are generated on disk, and sessions only talk over 127.0.0.1.
@Suite(.serialized)
final class TorrentSessionTests {
    let root: URL
    private var sessions: [TorrentSession] = []

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "TesseraKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        sessions.forEach { $0.shutdown() }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    func makeSession(_ name: String, savePath: URL? = nil) throws -> TorrentSession {
        let settings = SessionSettings()
        settings.listenInterfaces = "127.0.0.1:0"
        settings.enableDHT = false
        settings.enableLSD = false
        settings.enableUPnP = false
        settings.enableNATPMP = false
        let session = try TorrentSession(
            stateDirectory: root.appending(path: "\(name)-state"),
            defaultSavePath: savePath ?? root.appending(path: "\(name)-downloads"),
            settings: settings
        )
        sessions.append(session)
        return session
    }

    /// Three files whose boundaries fall inside pieces, so piece ranges overlap.
    func makeFixture(pieceLength: Int = 16 * 1024, scale: Int = 1) throws -> TorrentFixture {
        try TorrentFixture.make(
            name: "Fixture",
            files: [
                .init(path: "a.bin", size: 40_000 * scale),
                .init(path: "b.txt", size: 10),
                .init(path: "nested/c.bin", size: 70_000 * scale),
            ],
            pieceLength: pieceLength,
            in: root.appending(path: "seed-\(UUID().uuidString.prefix(8))")
        )
    }

    struct Timeout: Error, CustomStringConvertible {
        var description: String
    }

    @discardableResult
    func waitFor(
        _ session: TorrentSession, _ id: String, _ what: String, timeout: TimeInterval = 20,
        until condition: (TorrentStatus) -> Bool
    ) async throws -> TorrentStatus {
        let deadline = Date().addingTimeInterval(timeout)
        var last: TorrentStatus?
        while Date() < deadline {
            if let status = session.status(of: id) {
                last = status
                if condition(status) { return status }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Timeout(description: "Timed out waiting for \(what). Last status: \(String(describing: last))")
    }

    func piecePriorities(_ session: TorrentSession, _ id: String) -> [UInt8] {
        session.pieces(of: id).map { [UInt8]($0.priorities) } ?? []
    }

    func pieceFill(_ session: TorrentSession, _ id: String) -> [UInt8] {
        session.pieces(of: id).map { [UInt8]($0.fill) } ?? []
    }

    func waitUntil(_ what: String, timeout: TimeInterval = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Timeout(description: "Timed out waiting for \(what)")
    }

    func errorCode(_ body: () throws -> Void) -> TesseraKitError.Code? {
        do {
            try body()
            return nil
        } catch let error as TesseraKitError {
            return error.code
        } catch {
            return nil
        }
    }

    // MARK: Tests

    @Test func seedsDataThatIsAlreadyOnDisk() async throws {
        let fixture = try makeFixture()
        let session = try makeSession("seed", savePath: fixture.directory)
        let id = try session.addTorrent(data: fixture.torrentData, options: nil)

        let status = try await waitFor(session, id, "seeding") { $0.state == .seeding }
        #expect(status.progress == 1)
        #expect(status.name == "Fixture")
        #expect(status.hasMetadata)
        #expect(status.totalSize == Int64(fixture.totalSize))
        #expect(status.numPieces == fixture.numPieces)
        #expect(status.pieceLength == fixture.pieceLength)
        #expect(session.allTorrents().map(\.id) == [id])

        let pieces = try #require(session.pieces(of: id))
        #expect(pieces.pieceCount == fixture.numPieces)
        #expect(pieces.pieceLength == fixture.pieceLength)
        #expect([UInt8](pieces.fill).allSatisfy { $0 == PieceFill.have.rawValue })
        #expect([UInt8](pieces.priorities).allSatisfy { $0 == 4 })
        #expect(!pieces.tracksAvailability) // seeding
        #expect(pieces.availability.count == fixture.numPieces * 2)
    }

    @Test func pieceMapBeforeMetadataIsEmpty() throws {
        let session = try makeSession("pieces-magnet")
        let id = try session.addMagnet("magnet:?xt=urn:btih:\(String(repeating: "ef", count: 20))", options: nil)
        let pieces = try #require(session.pieces(of: id))
        #expect(pieces.pieceCount == 0)
        #expect(session.pieces(of: "unknown") == nil)
    }

    @Test func fileListMapsFilesToPieces() async throws {
        let fixture = try makeFixture()
        let session = try makeSession("files", savePath: fixture.directory)
        let id = try session.addTorrent(data: fixture.torrentData, options: nil)
        try await waitFor(session, id, "seeding") { $0.state == .seeding }

        let files = try #require(session.files(of: id))
        #expect(files.map(\.path) == ["Fixture/a.bin", "Fixture/b.txt", "Fixture/nested/c.bin"])
        #expect(files.map(\.name) == ["a.bin", "b.txt", "c.bin"])
        #expect(files.map(\.offset) == [0, 40_000, 40_010])
        // 16 KiB pieces: a.bin covers 0-2, b.txt sits inside piece 2, c.bin runs 2-6.
        #expect(files.map(\.firstPiece) == [0, 2, 2])
        #expect(files.map(\.lastPiece) == [2, 2, 6])
        #expect(files.allSatisfy { $0.downloadedBytes == $0.size && $0.progress == 1 })
        #expect(files.allSatisfy { $0.priority == 4 })
    }

    @Test func rejectsDuplicatesAndInvalidInput() throws {
        let fixture = try makeFixture()
        let session = try makeSession("invalid", savePath: fixture.directory)
        _ = try session.addTorrent(data: fixture.torrentData, options: nil)

        #expect(errorCode { _ = try session.addTorrent(data: fixture.torrentData, options: nil) } == .duplicateTorrent)
        #expect(errorCode { _ = try session.addTorrent(data: Data("not a torrent".utf8), options: nil) } == .invalidTorrent)
        #expect(errorCode { _ = try session.addMagnet("magnet:?xt=urn:btih:nothex", options: nil) } == .invalidMagnet)
        #expect(errorCode { try session.pauseTorrent("0000") } == .torrentNotFound)
        #expect(errorCode { _ = try session.addTorrent(fileAt: self.root.appending(path: "missing.torrent"), options: nil) } == .fileSystem)
    }

    @Test func magnetShowsNameBeforeMetadata() async throws {
        let session = try makeSession("magnet")
        let hash = String(repeating: "ab", count: 20)
        let id = try session.addMagnet("magnet:?xt=urn:btih:\(hash)&dn=Example%20Name", options: nil)

        #expect(id == hash)
        let status = try #require(session.status(of: id))
        #expect(status.name == "Example Name")
        #expect(!status.hasMetadata)
        #expect(status.totalSize == 0)
        #expect(session.files(of: id) == nil)
    }

    @Test func pauseAndResume() async throws {
        let fixture = try makeFixture()
        let session = try makeSession("pause", savePath: fixture.directory)
        let options = AddTorrentOptions()
        options.startPaused = true
        let id = try session.addTorrent(data: fixture.torrentData, options: options)

        #expect(session.status(of: id)?.isPaused == true)
        try session.resumeTorrent(id)
        #expect(session.status(of: id)?.isPaused == false)
        try await waitFor(session, id, "seeding after resume") { $0.state == .seeding }
        try session.pauseTorrent(id)
        #expect(session.status(of: id)?.isPaused == true)
    }

    @Test func restoresTorrentsAfterRestart() async throws {
        let fixture = try makeFixture()
        let state = "restart"
        let first = try makeSession(state, savePath: fixture.directory)
        let seedID = try first.addTorrent(data: fixture.torrentData, options: nil)
        let magnetID = try first.addMagnet("magnet:?xt=urn:btih:\(String(repeating: "cd", count: 20))&dn=Waiting", options: nil)
        try first.pauseTorrent(magnetID)
        try first.setLimits(download: 50_000, upload: 20_000, torrent: seedID)
        try await waitFor(first, seedID, "seeding") { $0.state == .seeding }
        first.shutdown()
        #expect(first.isClosed)

        let second = try makeSession(state, savePath: fixture.directory)
        let events = second.events()
        #expect(second.allTorrents().map(\.id) == [seedID, magnetID])
        let restored = try await waitFor(second, seedID, "seeding after restart") { $0.state == .seeding }
        #expect(restored.progress == 1)
        #expect(restored.downloadLimit == 50_000)
        #expect(restored.uploadLimit == 20_000)
        let magnet = try #require(second.status(of: magnetID))
        #expect(magnet.name == "Waiting")
        #expect(magnet.isPaused)

        // A torrent that was already complete must not announce "finished" again.
        try await Task.sleep(for: .seconds(2))
        second.shutdown()
        var kinds: [TorrentEvent.Kind] = []
        for await event in events { kinds.append(event.kind) }
        #expect(!kinds.contains(.finished))
    }

    @Test func removeKeepsOrDeletesFiles() async throws {
        let fixture = try makeFixture()
        let session = try makeSession("remove", savePath: fixture.directory)
        let events = session.events()
        func stateFile(_ id: String) -> URL { root.appending(path: "remove-state/\(id).fastresume") }

        var id = try session.addTorrent(data: fixture.torrentData, options: nil)
        try await waitFor(session, id, "seeding") { $0.state == .seeding }
        try await waitUntil("resume file") { FileManager.default.fileExists(atPath: stateFile(id).path) }

        try session.removeTorrent(id, deleteFiles: false)
        #expect(session.allTorrents().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: stateFile(id).path))
        #expect(FileManager.default.fileExists(atPath: fixture.url(of: fixture.files[0]).path))

        id = try session.addTorrent(data: fixture.torrentData, options: nil)
        try await waitFor(session, id, "seeding again") { $0.state == .seeding }
        try session.removeTorrent(id, deleteFiles: true)
        try await waitUntil("files deleted") {
            !FileManager.default.fileExists(atPath: fixture.url(of: fixture.files[0]).path)
        }

        var kinds: [TorrentEvent.Kind] = []
        for await event in events {
            kinds.append(event.kind)
            if event.kind == .filesDeleted { break }
        }
        #expect(kinds == [.added, .finished, .removed, .added, .finished, .removed, .filesDeleted])
    }

    @Test func snapshotStreamDeliversUpdates() async throws {
        let fixture = try makeFixture()
        let session = try makeSession("stream", savePath: fixture.directory)
        let snapshots = session.snapshots()
        let id = try session.addTorrent(data: fixture.torrentData, options: nil)

        var seen: SessionSnapshot?
        for await snapshot in snapshots where snapshot.torrents.contains(where: { $0.id == id && $0.state == .seeding }) {
            seen = snapshot
            break
        }
        #expect(seen?.torrents.count == 1)
        #expect(seen?.listenPort ?? 0 > 0)

        session.shutdown()
        var afterShutdown = 0
        for await _ in session.snapshots() { afterShutdown += 1 }
        #expect(afterShutdown <= 1) // at most the cached latest snapshot, then the stream ends
    }

    /// End to end: download from a local seeder, stop halfway, restart, finish.
    @Test func downloadsFromLocalPeerAndResumesAfterRestart() async throws {
        let fixture = try makeFixture(scale: 20) // about 2.2 MB, 135 pieces
        let seeder = try makeSession("seeder", savePath: fixture.directory)
        let seedID = try seeder.addTorrent(data: fixture.torrentData, options: nil)
        try await waitFor(seeder, seedID, "seeder ready") { $0.state == .seeding }
        let seederPort = seeder.listenPort
        #expect(seederPort > 0)

        let downloads = root.appending(path: "leecher-downloads")
        let leecher = try makeSession("leecher", savePath: downloads)
        let id = try leecher.addTorrent(data: fixture.torrentData, options: nil)
        #expect(id == seedID)
        try leecher.setLimits(download: 300_000, upload: 0, torrent: id) // slow enough to stop midway
        try leecher.connectPeer(host: "127.0.0.1", port: seederPort, torrent: id)

        let partial = try await waitFor(leecher, id, "partial download", timeout: 30) { $0.progress >= 0.25 }
        #expect(partial.progress < 1)

        let peers = try #require(leecher.peers(of: id))
        let seederPeer = try #require(peers.first { $0.address == "127.0.0.1:\(seederPort)" })
        #expect(seederPeer.isSeed)
        #expect(!seederPeer.isIncoming)
        #expect(!seederPeer.isWebSeed)
        #expect(seederPeer.totalDownloaded > 0)
        #expect(seederPeer.client.contains("libtorrent") || !seederPeer.client.isEmpty)

        // Mid-download piece map: some pieces done, some missing or in flight, and the seeder has them all.
        let pieces = try #require(leecher.pieces(of: id))
        let fill = [UInt8](pieces.fill)
        #expect(fill.count == fixture.numPieces)
        #expect(fill.contains(PieceFill.have.rawValue))
        #expect(fill.contains { $0 != PieceFill.have.rawValue })
        #expect(pieces.tracksAvailability)
        let availability = pieces.availability.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        #expect(availability.allSatisfy { $0 >= 1 }, "the connected seeder has every piece")
        leecher.shutdown()

        let restarted = try makeSession("leecher", savePath: downloads)
        let events = restarted.events()
        let restored = try await waitFor(restarted, id, "restored") {
            $0.state != .checkingResumeData && $0.state != .checkingFiles
        }
        #expect(restored.progress >= partial.progress * 0.8, "progress should survive the restart")
        #expect(restored.downloadLimit == 300_000)

        try restarted.setLimits(download: 0, upload: 0, torrent: id)
        try restarted.connectPeer(host: "127.0.0.1", port: seederPort, torrent: id)
        try await waitFor(restarted, id, "download complete", timeout: 30) { $0.state == .seeding }

        for file in fixture.files {
            let original = try Data(contentsOf: fixture.url(of: file))
            let downloaded = try Data(contentsOf: fixture.url(of: file, in: downloads))
            #expect(original == downloaded, "\(file.path) differs")
        }
        for await event in events where event.kind == .finished {
            #expect(event.torrentID == id)
            break
        }
    }

    // MARK: Priorities

    @Test func priorityErrors() async throws {
        let fixture = try makeFixture()
        let seed = try makeSession("prio-errors", savePath: fixture.directory)
        let seedingID = try seed.addTorrent(data: fixture.torrentData, options: nil)
        try await waitFor(seed, seedingID, "seeding") { $0.state == .seeding }
        #expect(errorCode { try seed.setPriority(7, pieces: 0...1, torrent: seedingID) } == .torrentComplete)

        let session = try makeSession("prio-errors-leech")
        let id = try session.addTorrent(data: fixture.torrentData, options: nil)
        #expect(errorCode { try session.setPriority(9, pieces: 0...1, torrent: id) } == .invalidArgument)
        #expect(errorCode { try session.setPriority(7, pieces: 0...999, torrent: id) } == .invalidArgument)
        #expect(errorCode { try session.setPriority(7, files: [99], torrent: id) } == .invalidArgument)
        let magnet = try session.addMagnet("magnet:?xt=urn:btih:\(String(repeating: "12", count: 20))", options: nil)
        #expect(errorCode { try session.setPriority(7, pieces: 0...0, torrent: magnet) } == .noMetadata)
    }

    @Test func filePrioritiesKeepHandSetPiecesOutsideTheFile() async throws {
        let fixture = try makeFixture() // a.bin pieces 0-2, b.txt piece 2, c.bin pieces 2-6
        let session = try makeSession("prio-mix")
        let id = try session.addTorrent(data: fixture.torrentData, options: nil) // no peers: nothing downloads

        try session.setPriority(7, pieces: 0...1, torrent: id)
        try await waitUntil("hand-set pieces") { piecePriorities(session, id) == [7, 7, 4, 4, 4, 4, 4] }

        // Skipping c.bin keeps pieces 0-1. Piece 2 is shared with wanted files, so it stays wanted.
        try session.setPriority(0, files: [2], torrent: id)
        try await waitUntil("skip c.bin") { piecePriorities(session, id) == [7, 7, 4, 0, 0, 0, 0] }
        #expect(session.files(of: id)?.map(\.priority) == [4, 4, 0])
        try await waitFor(session, id, "wanted bytes drop") { $0.totalWanted < Int64(fixture.totalSize) }

        // Changing a.bin itself replaces the hand-set pieces inside it.
        try session.setPriority(1, files: [0], torrent: id)
        try await waitUntil("lower a.bin") { piecePriorities(session, id) == [1, 1, 4, 0, 0, 0, 0] }

        // Both kinds survive a restart.
        try session.setPriority(7, pieces: 5...5, torrent: id)
        try await waitUntil("hand-set piece 5") { piecePriorities(session, id) == [1, 1, 4, 0, 0, 7, 0] }
        session.shutdown()
        let restarted = try makeSession("prio-mix")
        try await waitUntil("restored priorities") { piecePriorities(restarted, id) == [1, 1, 4, 0, 0, 7, 0] }
        #expect(restarted.files(of: id)?.map(\.priority) == [1, 4, 0])
    }

    /// The Phase 3 goal: a range set to Highest fills before everything else.
    @Test func highestPieceRangeDownloadsFirst() async throws {
        // libtorrent keeps about 3 s of requests in flight, so the urgent range must be larger
        // than that for the ordering to show: 104 pieces (1.6 MB) from a seeder sending 250 kB/s.
        let fixture = try makeFixture(scale: 60) // 403 pieces
        let seeder = try makeSession("prio-seeder", savePath: fixture.directory)
        let seedID = try seeder.addTorrent(data: fixture.torrentData, options: nil)
        try await waitFor(seeder, seedID, "seeder ready") { $0.state == .seeding }
        try seeder.setLimits(download: 0, upload: 250_000, torrent: seedID) // a slow peer; see the stream test

        let leecher = try makeSession("prio-leecher")
        let options = AddTorrentOptions()
        options.startPaused = true
        let id = try leecher.addTorrent(data: fixture.torrentData, options: options)
        let urgent = (fixture.numPieces - 104)...(fixture.numPieces - 1)
        try leecher.setPriority(7, pieces: urgent, torrent: id)
        try leecher.resumeTorrent(id)
        try leecher.connectPeer(host: "127.0.0.1", port: seeder.listenPort, torrent: id)

        // Sample while downloading. The last urgent pieces are already in flight when the rest
        // start, so judge the order at the point half of the urgent range is done.
        var othersAtHalf: Int?
        try await waitUntil("urgent range complete", timeout: 40) {
            let fill = pieceFill(leecher, id)
            guard fill.count == fixture.numPieces else { return false }
            let urgentDone = urgent.filter { fill[$0] == PieceFill.have.rawValue }.count
            if othersAtHalf == nil, urgentDone * 2 >= urgent.count {
                othersAtHalf = fill.indices.filter { !urgent.contains($0) && fill[$0] == PieceFill.have.rawValue }.count
            }
            return urgentDone == urgent.count
        }
        let others = fixture.numPieces - urgent.count
        let early = try #require(othersAtHalf)
        print("[priority] at 50% of the urgent range, \(early)/\(others) other pieces were done")
        // libtorrent picks its first few pieces at random and keeps seconds of requests in
        // flight, so some normal pieces always land early. The urgent range must be far ahead.
        #expect(Double(early) < Double(others) * 0.25, "urgent range should be at least 2x further along")
    }

    @Test func skippedFileLeavesTorrentFinishedNotSeeding() async throws {
        let fixture = try makeFixture(scale: 5)
        let seeder = try makeSession("skip-seeder", savePath: fixture.directory)
        let seedID = try seeder.addTorrent(data: fixture.torrentData, options: nil)
        try await waitFor(seeder, seedID, "seeder ready") { $0.state == .seeding }

        let leecher = try makeSession("skip-leecher")
        let options = AddTorrentOptions()
        options.startPaused = true
        let id = try leecher.addTorrent(data: fixture.torrentData, options: options)
        try leecher.setPriority(0, files: [2], torrent: id)
        try leecher.resumeTorrent(id)
        try leecher.connectPeer(host: "127.0.0.1", port: seeder.listenPort, torrent: id)

        let done = try await waitFor(leecher, id, "finished", timeout: 30) { $0.state == .finished }
        #expect(done.progress == 1)
        let files = try #require(leecher.files(of: id))
        #expect(files[0].progress == 1 && files[1].progress == 1)
        #expect(files[2].progress < 1)
    }

    // MARK: Download order

    /// Pieces of 128 KiB like a real video torrent (16 KiB pieces would put dozens of pieces
    /// in flight at once and blur the order).
    func makeVideoFixture() throws -> TorrentFixture {
        try TorrentFixture.make(
            name: "Movie",
            files: [
                .init(path: "intro.txt", size: 20_000),
                .init(path: "movie.mp4", size: 8_000_000),
                .init(path: "extras.bin", size: 2_000_000),
            ],
            pieceLength: 128 * 1024,
            in: root.appending(path: "video-\(UUID().uuidString.prefix(8))")
        )
    }

    @Test func sequentialAndDownloadFromStartSurviveRestart() async throws {
        let fixture = try makeVideoFixture()
        let session = try makeSession("order")
        let id = try session.addTorrent(data: fixture.torrentData, options: nil) // no peers

        try session.downloadFromStart(file: 1, torrent: id)
        #expect(session.status(of: id)?.fileDownloadingFromStart == 1)
        #expect(session.files(of: id)?.map(\.downloadsFromStart) == [false, true, false])
        try await waitUntil("other files paused") { session.files(of: id)?.map(\.priority) == [0, 4, 0] }
        #expect(session.status(of: id)?.isSequential == true)

        #expect(errorCode { try session.downloadFromStart(file: 9, torrent: id) } == .invalidArgument)
        let magnet = try session.addMagnet("magnet:?xt=urn:btih:\(String(repeating: "34", count: 20))", options: nil)
        #expect(errorCode { try session.downloadFromStart(file: 0, torrent: magnet) } == .noMetadata)

        session.shutdown()
        let restarted = try makeSession("order")
        let restored = try #require(restarted.status(of: id))
        #expect(restored.isSequential)
        #expect(restored.fileDownloadingFromStart == 1)

        try restarted.stopDownloadingFromStart(torrent: id)
        #expect(restarted.status(of: id)?.fileDownloadingFromStart == -1)
        #expect(restarted.status(of: id)?.isSequential == false) // back to how it was
        try await waitUntil("file priorities restored") { restarted.files(of: id)?.map(\.priority) == [4, 4, 4] }

        try restarted.setSequential(true, torrent: id)
        #expect(restarted.status(of: id)?.isSequential == true)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "order-state/\(id).fromstart").path))
    }

    /// The Phase 4 goal: a file inside a multi-file torrent becomes readable from its start
    /// long before the torrent finishes.
    @Test func downloadFromStartFillsTheFileInOrder() async throws {
        let fixture = try makeVideoFixture()
        let seeder = try makeSession("stream-seeder", savePath: fixture.directory)
        let seedID = try seeder.addTorrent(data: fixture.torrentData, options: nil)
        try await waitFor(seeder, seedID, "seeder ready") { $0.state == .seeding }
        // Throttle the sender, like a real slow peer. A receive limit over loopback lets the
        // sender fill the socket buffers, which the receiver then drains out of request order.
        try seeder.setLimits(download: 0, upload: 1_000_000, torrent: seedID)

        let leecher = try makeSession("stream-leecher")
        let options = AddTorrentOptions()
        options.startPaused = true
        let id = try leecher.addTorrent(data: fixture.torrentData, options: options)
        try leecher.downloadFromStart(file: 1, torrent: id)
        try leecher.resumeTorrent(id)
        try leecher.connectPeer(host: "127.0.0.1", port: seeder.listenPort, torrent: id)

        let movieSize = Int64(fixture.files[1].size)
        var atHalf: [TorrentFile] = []
        try await waitUntil("half the movie readable from its start", timeout: 30) {
            guard let files = leecher.files(of: id) else { return false }
            atHalf = files
            return files[1].contiguousBytes >= movieSize / 2
        }
        let movie = atHalf[1]
        let overall = try #require(leecher.status(of: id)).progress
        print("[stream] movie readable to \(movie.contiguousBytes * 100 / movieSize)% with \(movie.downloadedBytes * 100 / movieSize)% downloaded; end present: \(movie.hasEnd); extras \(Int(atHalf[2].progress * 100))%; torrent \(Int(overall * 100))%")
        #expect(movie.hasEnd, "the end of the file is fetched early")
        #expect(Double(movie.contiguousBytes) >= Double(movie.downloadedBytes) * 0.7, "the file fills in order")
        #expect(atHalf[2].progress < 0.1, "other files wait")

        // Once the movie is complete, download-from-start switches itself off.
        try await waitUntil("movie complete", timeout: 30) { leecher.files(of: id)?[1].progress == 1 }
        try await waitFor(leecher, id, "download-from-start ends") { $0.fileDownloadingFromStart == -1 }
        try await waitUntil("priorities restored") { leecher.files(of: id)?.map(\.priority) == [4, 4, 4] }

        // The paused files are wanted again and the torrent goes back to downloading. (Finishing
        // them needs a new connection: libtorrent drops a seed once nothing is left to exchange and
        // waits 60 s before reconnecting to it; real torrents have trackers and DHT for new peers.)
        try await waitFor(leecher, id, "other files wanted again") {
            $0.totalWanted == Int64(fixture.totalSize) && ($0.state == .downloading || $0.state == .seeding) && !$0.isSequential
        }
    }

    // MARK: Inspector and adding

    @Test func previewDescribesTorrentFilesAndMagnets() throws {
        let fixture = try makeFixture()
        let preview = try TorrentPreview(data: fixture.torrentData)
        #expect(preview.name == "Fixture")
        #expect(preview.totalSize == Int64(fixture.totalSize))
        #expect(preview.files.map(\.path) == ["Fixture/a.bin", "Fixture/b.txt", "Fixture/nested/c.bin"])
        #expect(preview.files.map(\.index) == [0, 1, 2])
        #expect(preview.comment == "Made for tests")
        #expect(!preview.isMagnet)

        let session = try makeSession("preview", savePath: fixture.directory)
        #expect(try session.addTorrent(data: fixture.torrentData, options: nil) == preview.torrentID)

        let hash = String(repeating: "5a", count: 20)
        let magnet = try TorrentPreview(magnet: "magnet:?xt=urn:btih:\(hash)&dn=Some%20Show")
        #expect(magnet.isMagnet && magnet.name == "Some Show" && magnet.torrentID == hash && magnet.files.isEmpty)
        #expect(errorCode { _ = try TorrentPreview(data: Data("junk".utf8)) } == .invalidTorrent)
        #expect(errorCode { _ = try TorrentPreview(magnet: "magnet:?nothing") } == .invalidMagnet)
    }

    @Test func addingWithFilePrioritiesSkipsFiles() async throws {
        let fixture = try makeFixture()
        let session = try makeSession("add-skip")
        let options = AddTorrentOptions()
        options.filePriorities = [4, 0, 7]
        let id = try session.addTorrent(data: fixture.torrentData, options: options)
        try await waitUntil("priorities applied") { session.files(of: id)?.map(\.priority) == [4, 0, 7] }
    }

    @Test func detailsAndTrackers() async throws {
        let fixture = try makeFixture()
        let session = try makeSession("details")
        let id = try session.addTorrent(data: fixture.torrentData, options: nil)

        let details = try #require(session.details(of: id))
        #expect(details.infoHashV1 == id)
        #expect(details.infoHashV2 == nil)
        #expect(details.magnetLink.hasPrefix("magnet:?xt=urn:btih:\(id)"))
        #expect(details.hasMetadata && !details.isPrivate)
        #expect(details.creator == "TesseraKitTests")
        #expect(details.comment == "Made for tests")
        #expect(details.creationDate == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(details.fileCount == 3 && details.numPieces == fixture.numPieces && details.pieceLength == fixture.pieceLength)

        #expect(session.trackers(of: id)?.isEmpty == true)
        try session.addTracker("udp://tracker.invalid:6969/announce", torrent: id)
        try session.addTracker("https://tracker.invalid/announce", torrent: id)
        let trackers = try #require(session.trackers(of: id))
        #expect(trackers.map(\.url) == ["udp://tracker.invalid:6969/announce", "https://tracker.invalid/announce"])
        #expect(trackers.map(\.tier) == [0, 1])
        #expect(errorCode { try session.addTracker("udp://tracker.invalid:6969/announce", torrent: id) } == .invalidArgument)
        #expect(errorCode { try session.addTracker("ftp://nope", torrent: id) } == .invalidArgument)
        try session.removeTracker("udp://tracker.invalid:6969/announce", torrent: id)
        #expect(session.trackers(of: id)?.map(\.url) == ["https://tracker.invalid/announce"])
        #expect(errorCode { try session.removeTracker("udp://gone", torrent: id) } == .invalidArgument)

        let magnetID = try session.addMagnet("magnet:?xt=urn:btih:\(String(repeating: "6b", count: 20))&dn=Later", options: nil)
        let magnetDetails = try #require(session.details(of: magnetID))
        #expect(!magnetDetails.hasMetadata && magnetDetails.name == "Later" && magnetDetails.fileCount == 0)
    }

    // MARK: Remote control encoding

    @Test func valueObjectsRoundTripThroughJSON() async throws {
        let fixture = try makeFixture()
        let session = try makeSession("json", savePath: fixture.directory)
        let id = try session.addTorrent(data: fixture.torrentData, options: nil)
        try session.setLimits(download: 12_345, upload: 0, torrent: id)
        try await waitFor(session, id, "seeding") { $0.state == .seeding }

        func roundTrip<T: JSONRepresentable>(_ value: T) throws -> T {
            let data = try JSONSerialization.data(withJSONObject: value.jsonObject)
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try #require(T(jsonObject: json))
        }

        let status = try #require(session.status(of: id))
        let status2 = try roundTrip(status)
        #expect(status2.id == id && status2.name == status.name && status2.state == status.state)
        #expect(status2.totalSize == status.totalSize && status2.progress == status.progress)
        #expect(status2.downloadLimit == 12_345 && status2.isPaused == status.isPaused)
        #expect(status2.addedDate?.timeIntervalSince1970 == status.addedDate?.timeIntervalSince1970)

        let files = try #require(session.files(of: id))
        let files2 = try files.map(roundTrip)
        #expect(files2.map(\.path) == files.map(\.path))
        #expect(files2.map(\.lastPiece) == files.map(\.lastPiece))
        #expect(files2.map(\.contiguousBytes) == files.map(\.contiguousBytes))

        let details = try roundTrip(try #require(session.details(of: id)))
        #expect(details.magnetLink.hasPrefix("magnet:") && details.creator == "TesseraKitTests" && details.infoHashV2 == nil)

        let pieces = try #require(session.pieces(of: id))
        let pieces2 = try roundTrip(pieces)
        #expect(pieces2.fill == pieces.fill && pieces2.priorities == pieces.priorities && pieces2.pieceCount == pieces.pieceCount)

        #expect(TorrentStatus(jsonObject: ["name": "no id"]) == nil)
        #expect(TorrentStatus(jsonObject: ["torrentID": 5]) == nil) // wrong type
    }
}
