import Foundation
import Observation
import OSLog
import TorrentKit
import TorrentUI

/// A torrent waiting in the add sheet for the user to choose a folder and files.
struct PendingAdd: Identifiable {
    enum Source {
        case file(data: Data, name: String)
        case magnet(String)
    }

    let id = UUID()
    let source: Source
    let preview: TorrentPreview
}

/// Which torrents a list shows.
enum TorrentFilter: String, CaseIterable, Identifiable, Hashable {
    case all, downloading, seeding, completed, paused

    var id: Self { self }

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .downloading: String(localized: "Downloading")
        case .seeding: String(localized: "Seeding")
        case .completed: String(localized: "Completed")
        case .paused: String(localized: "Paused")
        }
    }

    var systemImage: String {
        switch self {
        case .all: "tray.full"
        case .downloading: "arrow.down.circle"
        case .seeding: "arrow.up.circle"
        case .completed: "checkmark.circle"
        case .paused: "pause.circle"
        }
    }

    func includes(_ t: TorrentStatus) -> Bool {
        switch self {
        case .all: true
        case .downloading: !t.isPaused && t.state != .seeding && t.state != .finished
        case .seeding: !t.isPaused && t.state == .seeding
        case .completed: t.progress >= 1
        case .paused: t.isPaused
        }
    }
}

/// Owns the engine session and publishes torrent statuses to the UI.
@Observable
final class TorrentStore {
    private(set) var torrents: [TorrentStatus] = []
    private(set) var downloadRate: Int64 = 0
    private(set) var uploadRate: Int64 = 0
    private(set) var dhtNodes = 0
    private(set) var startError: String?
    /// Shown as an alert, then cleared.
    var lastError: String?
    private(set) var session: TorrentSession?

    /// Torrents waiting for the add sheet, first one shown.
    private(set) var pendingAdds: [PendingAdd] = []
    /// Set to ask the window to select and show a torrent (e.g. from a notification).
    var selectionRequest: String?
    /// Called on the main actor when a download finishes.
    var onFinished: ((TorrentEvent) -> Void)?

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            session?.applySettings(settings.sessionSettings)
        }
    }

    let engineVersion = BuildInfo.libtorrentVersion
    private let logger = Logger(subsystem: "io.github.rishavjnv12.Torrent", category: "store")

    init() {
        settings = AppSettings.load()
        #if os(macOS)
        FolderAccess.restoreAll()
        #endif
        start()
    }

    static var stateDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Torrent/State", directoryHint: .isDirectory)
    }

    var downloadFolder: URL { DownloadFolders.folder(for: settings) }

    private func start() {
        do {
            let session = try TorrentSession(
                stateDirectory: Self.stateDirectory, defaultSavePath: downloadFolder, settings: settings.sessionSettings
            )
            self.session = session
            torrents = session.allTorrents()
            logger.notice("Engine started with \(self.torrents.count) torrents, libtorrent \(self.engineVersion, privacy: .public)")
            Task { [weak self] in
                for await snapshot in session.snapshots() {
                    guard let self else { return }
                    self.torrents = snapshot.torrents
                    self.downloadRate = snapshot.downloadRate
                    self.uploadRate = snapshot.uploadRate
                    self.dhtNodes = snapshot.dhtNodes
                }
            }
            Task { [weak self] in
                for await event in session.events() where event.kind == .finished {
                    self?.onFinished?(event)
                }
            }
        } catch {
            startError = error.localizedDescription
            logger.error("Engine failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    func status(of id: String) -> TorrentStatus? {
        torrents.first { $0.id == id }
    }

    func count(_ filter: TorrentFilter) -> Int {
        torrents.filter(filter.includes).count
    }

    /// Overall progress of torrents still downloading, 0...1, or nil when none are.
    var downloadingProgress: Double? {
        let active = torrents.filter { TorrentFilter.downloading.includes($0) && $0.hasMetadata }
        let wanted = active.reduce(Int64(0)) { $0 + $1.totalWanted }
        guard wanted > 0 else { return nil }
        return Double(active.reduce(Int64(0)) { $0 + $1.totalWantedDone }) / Double(wanted)
    }

    // MARK: Adding

    /// Adds right away, or queues for the add sheet when "ask before adding" is on.
    func open(_ urls: [URL]) {
        for url in urls {
            if url.scheme?.lowercased() == "magnet" {
                open(magnet: url.absoluteString)
            } else if url.isFileURL {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    let preview = try TorrentPreview(data: data)
                    queue(PendingAdd(source: .file(data: data, name: url.lastPathComponent), preview: preview))
                } catch {
                    lastError = String(localized: "“\(url.lastPathComponent)” couldn’t be opened: \(error.localizedDescription)")
                }
            }
        }
    }

    /// A .torrent file's contents, e.g. from the share extension's inbox.
    func open(torrentData data: Data, name: String) {
        do {
            queue(PendingAdd(source: .file(data: data, name: name), preview: try TorrentPreview(data: data)))
        } catch {
            lastError = String(localized: "“\(name)” couldn’t be opened: \(error.localizedDescription)")
        }
    }

    func open(magnet link: String) {
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            queue(PendingAdd(source: .magnet(link), preview: try TorrentPreview(magnet: link)))
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func queue(_ add: PendingAdd) {
        if status(of: add.preview.torrentID) != nil {
            lastError = String(localized: "“\(add.preview.name)” is already in the list.")
            selectionRequest = add.preview.torrentID
            return
        }
        if settings.askBeforeAdding {
            pendingAdds.append(add)
        } else {
            accept(add, folder: downloadFolder, filePriorities: nil, start: true)
        }
    }

    /// Adds a torrent from the add sheet. `filePriorities` nil downloads every file.
    @discardableResult
    func accept(_ add: PendingAdd, folder: URL, filePriorities: [Int]?, start: Bool) -> String? {
        pendingAdds.removeAll { $0.id == add.id }
        let options = AddTorrentOptions()
        options.savePath = folder
        options.startPaused = !start
        options.filePriorities = filePriorities.map { $0.map(NSNumber.init(value:)) }
        let id: String? = switch add.source {
        case .file(let data, _): perform { try $0.addTorrent(data: data, options: options) }
        case .magnet(let link): perform { try $0.addMagnet(link, options: options) }
        }
        if let id { selectionRequest = id }
        return id
    }

    func dismiss(_ add: PendingAdd) {
        pendingAdds.removeAll { $0.id == add.id }
    }

    /// Adds without the sheet (iPhone, tests).
    @discardableResult
    func addTorrent(fileAt url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return perform { try $0.addTorrent(fileAt: url, options: nil) }
    }

    @discardableResult
    func addMagnet(_ link: String) -> String? {
        perform { try $0.addMagnet(link.trimmingCharacters(in: .whitespacesAndNewlines), options: nil) }
    }

    #if DEBUG
    /// Debug launch options `-addTorrent <magnet or path>`, `-downloadFromStart <file index>` and
    /// `-highestPieces <first>-<last>`: adds the torrent once and applies them. Returns its ID,
    /// or the first torrent's ID when it is already in the list.
    func addFromLaunchArguments() -> String? {
        guard let source = UserDefaults.standard.string(forKey: "addTorrent") else { return nil }
        let id = source.hasPrefix("magnet:") ? addMagnet(source) : addTorrent(fileAt: URL(filePath: source))
        if id == nil { lastError = nil }
        if let id, UserDefaults.standard.object(forKey: "downloadFromStart") != nil {
            run { try $0.downloadFromStart(file: UserDefaults.standard.integer(forKey: "downloadFromStart"), torrent: id) }
        }
        if let id, let spec = UserDefaults.standard.string(forKey: "highestPieces") {
            let bounds = spec.split(separator: "-").compactMap { Int($0) }
            if bounds.count == 2, bounds[0] <= bounds[1] {
                setPriority(.highest, pieces: bounds[0]...bounds[1], torrent: id)
            }
        }
        return id ?? torrents.first?.id
    }
    #endif

    // MARK: Actions

    @discardableResult
    func setPriority(_ priority: PiecePriority, files: Set<Int>, torrent id: String) -> Bool {
        perform { try $0.setPriority(priority.rawValue, files: files, torrent: id) } != nil
    }

    @discardableResult
    func setPriority(_ priority: PiecePriority, pieces: ClosedRange<Int>, torrent id: String) -> Bool {
        perform { try $0.setPriority(priority.rawValue, pieces: pieces, torrent: id) } != nil
    }

    /// Runs any engine action, reporting errors like the other actions. Returns false on failure.
    @discardableResult
    func run(_ action: (TorrentSession) throws -> Void) -> Bool {
        perform(action) != nil
    }

    func pause(_ id: String) { pause([id]) }
    func resume(_ id: String) { resume([id]) }
    func remove(_ id: String, deleteFiles: Bool) { remove([id], deleteFiles: deleteFiles) }

    func pause(_ ids: some Collection<String>) {
        perform { session in for id in ids { try session.pauseTorrent(id) } }
    }

    func resume(_ ids: some Collection<String>) {
        perform { session in for id in ids { try session.resumeTorrent(id) } }
    }

    func remove(_ ids: some Collection<String>, deleteFiles: Bool) {
        perform { session in for id in ids { try session.removeTorrent(id, deleteFiles: deleteFiles) } }
    }

    func pauseAll() { pause(torrents.filter { !$0.isPaused }.map(\.id)) }
    func resumeAll() { resume(torrents.filter(\.isPaused).map(\.id)) }

    func saveResumeData() { session?.saveResumeData() }

    func shutdown() {
        session?.shutdown()
    }

    @discardableResult
    private func perform<T>(_ action: (TorrentSession) throws -> T) -> T? {
        guard let session else { return nil }
        do {
            let result = try action(session)
            torrents = session.allTorrents() // reflect the change before the next snapshot
            return result
        } catch {
            lastError = error.localizedDescription
            torrents = session.allTorrents()
            return nil
        }
    }
}

extension TorrentStatus {
    /// Real location of the torrent's data (resolves the sandbox container's Downloads link).
    var contentURL: URL {
        URL(filePath: savePath, directoryHint: .isDirectory).appending(path: name).resolvingSymlinksInPath()
    }
}
