// tesseractl — command-line harness for TesseraKit.
//
//   tesseractl [--state DIR] [--save DIR] [--seconds N] [--until-done] [--files] [--port N] [TORRENT_OR_MAGNET ...]
//
// Torrents are restored from --state on every run, so running again without arguments
// continues where the last run stopped. Ctrl-C saves progress and exits.

import AVFoundation
import Foundation
import Synchronization
import TesseraKit

struct Options {
    var state = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".tesseractl/state")
    var save = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads/tesseractl")
    var seconds: Double?
    var untilDone = false
    var showFiles = false
    var port = 0
    var fromStart: Int?
    var sources: [String] = []
}

func usage() -> Never {
    print("""
    usage: tesseractl [--state DIR] [--save DIR] [--seconds N] [--until-done] [--files] [--port N] [TORRENT_OR_MAGNET ...]
      --state DIR    where progress is saved (default ~/.tesseractl/state)
      --save DIR     where files are downloaded (default ~/Downloads/tesseractl)
      --seconds N    stop after N seconds
      --until-done   stop when every torrent is complete
      --files        print each torrent's files and piece ranges once metadata is known
      --port N       listen port (default random)
      --from-start N download file N from its start; once its start and end are ready,
                     check with AVFoundation that it plays, while the rest still downloads
    """)
    exit(2)
}

func parseOptions() -> Options {
    var options = Options()
    var args = CommandLine.arguments.dropFirst()
    func value() -> String {
        guard let v = args.popFirst() else { usage() }
        return v
    }
    while let arg = args.popFirst() {
        switch arg {
        case "--state": options.state = URL(filePath: (value() as NSString).expandingTildeInPath)
        case "--save": options.save = URL(filePath: (value() as NSString).expandingTildeInPath)
        case "--seconds":
            guard let n = Double(value()) else { usage() }
            options.seconds = n
        case "--until-done": options.untilDone = true
        case "--files": options.showFiles = true
        case "--port":
            guard let n = Int(value()) else { usage() }
            options.port = n
        case "--from-start":
            guard let n = Int(value()) else { usage() }
            options.fromStart = n
        case "-h", "--help": usage()
        default:
            if arg.hasPrefix("--") { usage() }
            options.sources.append(arg)
        }
    }
    return options
}

func bytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

func duration(_ seconds: TimeInterval) -> String {
    guard seconds >= 0 else { return "--" }
    let s = Int(seconds)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

func stateName(_ t: TorrentStatus) -> String {
    if t.isPaused { return "Paused" }
    if t.isQueued { return "Queued" }
    switch t.state {
    case .checkingResumeData: return "Resuming"
    case .checkingFiles: return "Checking"
    case .downloadingMetadata: return "Metadata"
    case .downloading: return "Downloading"
    case .finished: return "Finished"
    case .seeding: return "Seeding"
    @unknown default: return "?"
    }
}

func line(for t: TorrentStatus) -> String {
    let pct = String(format: "%5.1f%%", t.progress * 100)
    let state = stateName(t).padding(toLength: 11, withPad: " ", startingAt: 0)
    let down = "\(bytes(t.downloadRate))/s".padding(toLength: 11, withPad: " ", startingAt: 0)
    let up = "\(bytes(t.uploadRate))/s".padding(toLength: 11, withPad: " ", startingAt: 0)
    var text = "\(pct)  \(state)  ↓ \(down)  ↑ \(up)  peers \(t.connectedPeers) (\(t.connectedSeeds) seeds)  ETA \(duration(t.eta))  \(t.name)"
    if let error = t.errorMessage { text += "  ERROR: \(error)" }
    return text
}

func printFiles(_ files: [TorrentFile], of t: TorrentStatus) {
    print("   Files in \(t.name) — \(t.numPieces) pieces of \(bytes(Int64(t.pieceLength))):")
    for f in files {
        let pieces = f.firstPiece < 0 ? "empty" : "pieces \(f.firstPiece)–\(f.lastPiece)"
        print("   #\(f.index)  \(bytes(f.size).padding(toLength: 10, withPad: " ", startingAt: 0))  \(pieces.padding(toLength: 20, withPad: " ", startingAt: 0))  \(f.path)")
    }
}

// MARK: - Main

let options = parseOptions()
let settings = SessionSettings()
settings.listenPort = options.port

let session: TorrentSession
do {
    session = try TorrentSession(stateDirectory: options.state, defaultSavePath: options.save, settings: settings)
} catch {
    print("Could not start: \(error.localizedDescription)")
    exit(1)
}

let restored = session.allTorrents()
print("State: \(options.state.path)")
print("Saving to: \(options.save.path)")
print("Restored \(restored.count) torrent(s)")
for t in restored { print(" • \(line(for: t))") }

for source in options.sources {
    do {
        let id = source.hasPrefix("magnet:")
            ? try session.addMagnet(source, options: nil)
            : try session.addTorrent(fileAt: URL(filePath: (source as NSString).expandingTildeInPath), options: nil)
        print("Added \(id)")
    } catch {
        print("Could not add \(source): \(error.localizedDescription)")
    }
}

let stopRequested = Atomic<Bool>(false)
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    source.setEventHandler { stopRequested.store(true, ordering: .relaxed) }
    source.resume()
    signalSources.append(source)
}

let eventTask = Task.detached {
    for await event in session.events() {
        let kind: String = switch event.kind {
        case .added: "added"
        case .metadataReceived: "metadata received"
        case .finished: "FINISHED"
        case .removed: "removed"
        case .filesDeleted: "files deleted"
        case .torrentError: "error"
        case .sessionError: "session error"
        @unknown default: "event"
        }
        print("[event] \(kind): \(event.torrentName ?? "session") \(event.message ?? "")")
    }
}

if let index = options.fromStart {
    for t in session.allTorrents() {
        do {
            try session.downloadFromStart(file: index, torrent: t.id)
            print("Downloading file #\(index) of \(t.name) from its start")
        } catch {
            print("Could not download file #\(index) from start: \(error.localizedDescription)")
        }
    }
}

/// Loads a partly downloaded media file and decodes one frame from near its start.
func checkPlayable(_ url: URL) async -> String {
    let asset = AVURLAsset(url: url)
    do {
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return "no video track" }
        let size = try await track.load(.naturalSize)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        let (image, time) = try await generator.image(at: CMTime(seconds: 10, preferredTimescale: 600))
        return String(format: "PLAYABLE: duration %.0f s, video %.0fx%.0f, decoded a %dx%d frame at %.1f s",
                      duration.seconds, size.width, size.height, image.width, image.height, time.seconds)
    } catch {
        return "not playable yet: \(error.localizedDescription)"
    }
}

let start = Date()
var filesPrinted = Set<String>()
var playableChecked = Set<String>()
for await snapshot in session.snapshots() {
    let elapsed = Date().timeIntervalSince(start)
    print("— \(duration(elapsed))  ↓ \(bytes(snapshot.downloadRate))/s  ↑ \(bytes(snapshot.uploadRate))/s  DHT nodes \(snapshot.dhtNodes)  port \(snapshot.listenPort)")
    for t in snapshot.torrents {
        print("  \(line(for: t))")
        if t.fileDownloadingFromStart >= 0, !playableChecked.contains(t.id),
           let file = session.files(of: t.id)?.first(where: { $0.index == t.fileDownloadingFromStart }) {
            let ready = Double(file.contiguousBytes) / Double(max(1, file.size))
            print(String(format: "   from start: %@ ready to %.0f%%, end %@", file.name, ready * 100, file.hasEnd ? "downloaded" : "not yet"))
            if file.contiguousBytes >= min(file.size, 8 * 1024 * 1024), file.hasEnd {
                playableChecked.insert(t.id)
                let url = URL(filePath: t.savePath).appending(path: file.path)
                let result = await checkPlayable(url)
                print(String(format: "   %@ (file %.0f%% downloaded, torrent %.0f%%)", result, file.progress * 100, t.progress * 100))
            }
        }
        if options.showFiles, t.hasMetadata, !filesPrinted.contains(t.id), let files = session.files(of: t.id) {
            filesPrinted.insert(t.id)
            printFiles(files, of: t)
        }
    }
    let allDone = !snapshot.torrents.isEmpty && snapshot.torrents.allSatisfy { $0.state == .seeding || $0.state == .finished }
    if stopRequested.load(ordering: .relaxed)
        || (options.seconds.map { elapsed >= $0 } ?? false)
        || (options.untilDone && allDone) {
        break
    }
}

print("Saving progress…")
session.shutdown()
_ = await eventTask.value
print("Stopped. Run again with the same --state to continue.")
