import QuickLook
import SwiftUI
import TesseraKit
import TesseraUI

enum DetailSection: String, CaseIterable, Identifiable {
    case files, peers, trackers, info
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .files: "Files"
        case .peers: "Peers"
        case .trackers: "Trackers"
        case .info: "Info"
        }
    }
}

/// One torrent: status, piece map, then Files, Peers, Trackers and Info.
struct TorrentDetailView: View {
    var store: TorrentStore
    var torrentID: String

    @State private var feed = PieceMapFeed()
    /// File whose pieces are outlined on the map, chosen from the file's context menu.
    @State private var highlightedFile: Int?
    /// Highlighting a file scrolls the map into view only when it is off screen.
    @State private var isMapVisible = true
    @State private var confirmingRemoval = false
    @State private var previewURL: URL?
    @AppStorage("detailSection") private var section: DetailSection = .files

    private var status: TorrentStatus? { store.status(of: torrentID) }

    private static let mapID = "pieceMap"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let status {
                    VStack(alignment: .leading, spacing: 20) {
                        TorrentHeader(torrent: status)
                        if let file = feed.files.first(where: { $0.index == status.fileDownloadingFromStart }) {
                            FromStartBanner(file: file, onOpen: store.isRemote ? nil : { previewURL = file.url(in: status.savePath) }) {
                                perform { try $0.stopDownloadingFromStart(torrent: torrentID) }
                            }
                        }
                        PieceMapCard(
                            map: feed.map, highlightedRanges: highlightedRanges,
                            onSetPriority: canChangePriority(status) ? { range, priority in setPriority(priority, pieces: range) } : nil,
                            highlightTitle: feed.files.first { $0.index == highlightedFile }?.name,
                            onClearHighlight: { highlightedFile = nil }
                        )
                        .id(Self.mapID)
                        .onScrollVisibilityChange(threshold: 0.5) { isMapVisible = $0 }
                        Picker("Show", selection: $section) {
                            ForEach(DetailSection.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        switch section {
                        case .files:
                            FileList(
                                files: feed.files, savePath: status.savePath, highlighted: $highlightedFile,
                                onSetPriority: canChangePriority(status) ? { files, priority in setPriority(priority, files: files) } : nil,
                                onDownloadFromStart: canChangePriority(status) ? { index in
                                    perform { try $0.downloadFromStart(file: index, torrent: torrentID) }
                                } : nil,
                                onStopDownloadingFromStart: { perform { try $0.stopDownloadingFromStart(torrent: torrentID) } },
                                onOpen: store.isRemote ? nil : { previewURL = $0 }
                            )
                        case .peers:
                            PeersSection(store: store, torrentID: torrentID)
                        case .trackers:
                            TrackersSection(store: store, torrent: status)
                        case .info:
                            InfoSection(store: store, torrent: status)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
            .onChange(of: highlightedFile) { _, file in
                guard file != nil, !isMapVisible else { return }
                withAnimation { proxy.scrollTo(Self.mapID, anchor: .center) }
            }
        }
        .overlay {
            if status == nil {
                ContentUnavailableView("Torrent Removed", systemImage: "xmark.circle")
            }
        }
        .navigationTitle(status?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task(id: torrentID) {
            guard let backend = store.backend else { return }
            highlightedFile = nil
            await feed.run(backend: backend, torrentID: torrentID)
        }
        .quickLookPreview($previewURL)
        .confirmationDialog("Remove “\(status?.name ?? "")”?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove from List") { store.remove(torrentID, deleteFiles: false) }
            Button("Remove and Delete Files", role: .destructive) { store.remove(torrentID, deleteFiles: true) }
        } message: {
            Text("Removing keeps downloaded files unless you choose to delete them.")
        }
    }

    private var highlightedRanges: [ClosedRange<Int>] {
        guard let pieces = feed.map.files.first(where: { $0.id == highlightedFile })?.pieces else { return [] }
        return [pieces]
    }

    /// libtorrent ignores priority changes once every piece is downloaded.
    private func canChangePriority(_ status: TorrentStatus) -> Bool {
        status.hasMetadata && status.state != .seeding
    }

    private func perform(_ action: (any TorrentBackend) throws -> Void) {
        guard store.run(action) else { return }
        feed.refreshSoon()
    }

    private func setPriority(_ priority: PiecePriority, pieces: ClosedRange<Int>) {
        guard store.setPriority(priority, pieces: pieces, torrent: torrentID) else { return }
        feed.showPriority(priority, pieces: [pieces])
        feed.refreshSoon()
    }

    private func setPriority(_ priority: PiecePriority, files: Set<Int>) {
        guard store.setPriority(priority, files: files, torrent: torrentID) else { return }
        feed.showPriority(priority, pieces: feed.map.files.filter { files.contains($0.id) }.compactMap(\.pieces))
        feed.refreshSoon()
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let status {
            ToolbarItem {
                if status.isPaused {
                    Button("Resume", systemImage: "play.fill") { store.resume(torrentID) }
                } else {
                    Button("Pause", systemImage: "pause.fill") { store.pause(torrentID) }
                }
            }
            ToolbarItem {
                Menu("More", systemImage: "ellipsis") {
                    Toggle(isOn: Binding(get: { status.isSequential }, set: { on in
                        perform { try $0.setSequential(on, torrent: torrentID) }
                    })) {
                        Label("Download in Order", systemImage: "arrow.right.to.line")
                    }
                    .disabled(status.fileDownloadingFromStart >= 0 || status.state == .seeding)
                    if let link = store.backend?.details(of: torrentID)?.magnetLink {
                        ShareLink(item: link, preview: SharePreview(status.name)) {
                            Label("Share Magnet Link", systemImage: "square.and.arrow.up")
                        }
                        Button("Copy Magnet Link", systemImage: "doc.on.doc") { UIPasteboard.general.string = link }
                    }
                    if !store.isRemote {
                        Button("Show in Files", systemImage: "folder") { FilesApp.open(status.contentURL) }
                    }
                    Divider()
                    Button("Remove…", systemImage: "trash", role: .destructive) { confirmingRemoval = true }
                }
            }
        }
    }
}

/// Name, state and progress, then the live numbers as tiles.
struct TorrentHeader: View {
    var torrent: TorrentStatus
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(torrent.name)
                .font(.title2.weight(.semibold))
                .lineLimit(4)
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    statePill
                    Spacer(minLength: 8)
                    Text(Format.percent(torrent.progress))
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                }
                ProgressView(value: torrent.progress)
                    .tint(stateStyle.color)
                amountAndTime
            }
            if let error = torrent.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            stats
        }
    }

    // MARK: State

    private var statePill: some View {
        Label(torrent.errorMessage == nil ? Format.state(torrent) : String(localized: "Error"), systemImage: stateStyle.symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(stateStyle.color)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(stateStyle.color.opacity(0.15), in: .capsule)
    }

    private var stateStyle: (symbol: String, color: Color) {
        if torrent.errorMessage != nil { return ("exclamationmark.triangle.fill", .red) }
        if torrent.isPaused { return ("pause.fill", .secondary) }
        if torrent.isQueued { return ("clock", .secondary) }
        return switch torrent.state {
        case .checkingResumeData, .checkingFiles: ("arrow.triangle.2.circlepath", .orange)
        case .downloadingMetadata: ("magnifyingglass", .accentColor)
        case .downloading: ("arrow.down", .accentColor)
        case .finished: ("checkmark", .green)
        case .seeding: ("arrow.up", .green)
        @unknown default: ("questionmark", .secondary)
        }
    }

    // MARK: Progress

    /// "1.57 GB of 2.14 GB" and "1 hr, 27 min left", side by side when they fit.
    @ViewBuilder
    private var amountAndTime: some View {
        let amount = amountText
        let time = timeText
        if amount != nil || time != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    amount
                    Spacer(minLength: 0)
                    time
                }
                VStack(alignment: .leading, spacing: 2) {
                    amount
                    time
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
        }
    }

    private var amountText: Text? {
        guard torrent.hasMetadata else { return nil }
        if torrent.totalWantedDone >= torrent.totalWanted { return Text(Format.bytes(torrent.totalWanted)) }
        return Text("\(Format.bytes(torrent.totalWantedDone)) of \(Format.bytes(torrent.totalWanted))")
    }

    private var timeText: Text? {
        if let eta = Format.eta(torrent.eta) { return Text("\(eta) left") }
        if torrent.progress >= 1, let completed = torrent.completedDate {
            return Text("Completed \(completed, format: .relative(presentation: .named))")
        }
        return nil
    }

    // MARK: Stats

    private var stats: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
        return layout {
            StatTile(title: "Download", systemImage: "arrow.down", tint: .blue, value: Text(rate(torrent.downloadRate))) {
                Text("\(Format.bytes(torrent.totalDownloaded)) total")
            }
            StatTile(title: "Upload", systemImage: "arrow.up", tint: .green, value: Text(rate(torrent.uploadRate))) {
                Text("Ratio \(torrent.ratio.formatted(.number.precision(.fractionLength(2))))")
            }
            StatTile(title: "Peers", systemImage: "person.2.fill", tint: .orange, value: Text(torrent.connectedPeers.formatted())) {
                Text("^[\(torrent.connectedSeeds) seed](inflect: true)")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "114 kB/s" with the unit smaller than the number.
    private func rate(_ bytesPerSecond: Int64) -> AttributedString {
        let unitFont = Font.system(.subheadline, design: .rounded, weight: .semibold)
        var text = bytesPerSecond.formatted(.byteCount(style: .file, spellsOutZero: false).attributed)
        let unitRanges = text.runs.compactMap { run -> Range<AttributedString.Index>? in
            if case .unit? = run.byteCount { run.range } else { nil }
        }
        for range in unitRanges { text[range].font = unitFont }
        var perSecond = AttributedString("/s")
        perSecond.font = unitFont
        return text + perSecond
    }
}

/// One live number: a caption with a tinted symbol, the value, and a detail line.
private struct StatTile<Detail: View>: View {
    var title: LocalizedStringKey
    var systemImage: String
    var tint: Color
    var value: Text
    @ViewBuilder var detail: Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .imageScale(.small)
                Text(title)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            value
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
            detail
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.fill.quinary, in: .rect(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Peers

private struct PeersSection: View {
    var store: TorrentStore
    var torrentID: String
    @State private var poll = Poll<[Peer]>()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let peers = poll.value?.sorted(by: { $0.downloadRate + $0.uploadRate > $1.downloadRate + $1.uploadRate }) {
                Text(peers.count == 1 ? "1 peer connected" : "\(peers.count) peers connected")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(peers) { peer in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(peer.isWebSeed ? String(localized: "Web seed") : (peer.client.isEmpty ? peer.address : peer.client))
                                .lineLimit(1)
                            if peer.isEncrypted { Image(systemName: "lock.fill").imageScale(.small).foregroundStyle(.secondary) }
                            Spacer()
                            Text(peer.isSeed ? String(localized: "Has all") : Format.percent(peer.progress))
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 12) {
                            Text(peer.address).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Label(Format.rate(peer.downloadRate), systemImage: "arrow.down")
                            Label(Format.rate(peer.uploadRate), systemImage: "arrow.up")
                        }
                        .labelStyle(CompactLabelStyle())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                    .padding(.vertical, 6)
                    Divider()
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task(id: torrentID) {
            guard let backend = store.backend else { return }
            let id = torrentID
            await poll.run(every: .seconds(2)) { backend.peers(of: id) }
        }
    }
}

// MARK: - Trackers

private struct TrackersSection: View {
    var store: TorrentStore
    var torrent: TorrentStatus
    @State private var poll = Poll<[Tracker]>()
    @State private var newTracker = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let trackers = poll.value {
                if trackers.isEmpty {
                    Text("No trackers. Peers are found through DHT and peer exchange.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(trackers) { tracker in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(color(tracker)).frame(width: 8, height: 8).padding(.top, 6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tracker.url).lineLimit(1).truncationMode(.middle)
                            Text(detail(tracker))
                                .font(.caption)
                                .foregroundStyle(tracker.status == .error ? Color.red : .secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 4)
                    .contextMenu {
                        Button("Copy Address", systemImage: "doc.on.doc") { UIPasteboard.general.string = tracker.url }
                        Button("Remove Tracker", systemImage: "trash", role: .destructive) {
                            store.run { try $0.removeTracker(tracker.url, torrent: torrent.id) }
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            HStack {
                TextField("Add tracker (udp://, https://)", text: $newTracker)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newTracker.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .task(id: torrent.id) {
            guard let backend = store.backend else { return }
            let id = torrent.id
            await poll.run(every: .seconds(3)) { backend.trackers(of: id) }
        }
    }

    private func add() {
        if store.run({ try $0.addTracker(newTracker, torrent: torrent.id) }) { newTracker = "" }
    }

    private func color(_ t: Tracker) -> Color {
        switch t.status {
        case .working: .green
        case .updating: .orange
        case .error: .red
        default: .secondary.opacity(0.5)
        }
    }

    private func detail(_ t: Tracker) -> String {
        let status: String = switch t.status {
        case .working: String(localized: "Working")
        case .updating: String(localized: "Updating")
        case .error: String(localized: "Error")
        default: String(localized: "Not contacted yet")
        }
        var parts = [status]
        if t.seeds >= 0 { parts.append(String(localized: "\(t.seeds) seeds")) }
        if t.peers >= 0 { parts.append(String(localized: "\(t.peers) peers")) }
        if !t.message.isEmpty { parts.append(t.message) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Info

private struct InfoSection: View {
    var store: TorrentStore
    var torrent: TorrentStatus
    @State private var details: TorrentDetails?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let d = details {
                group {
                    row("Size", d.hasMetadata ? Format.bytes(d.totalSize) : "–")
                    row("Pieces", d.hasMetadata ? "\(d.numPieces.formatted()) × \(Format.bytes(Int64(d.pieceLength)))" : "–")
                    row("Files", d.hasMetadata ? d.fileCount.formatted() : "–")
                    row("Private", d.isPrivate ? String(localized: "Yes, trackers only") : String(localized: "No"))
                }
                group {
                    if let v1 = d.infoHashV1 { row("Info hash", v1, mono: true) }
                    if let v2 = d.infoHashV2 { row("Info hash v2", v2, mono: true) }
                    if let date = d.creationDate { row("Created", date.formatted(date: .abbreviated, time: .shortened)) }
                    if !d.creator.isEmpty { row("Created by", d.creator) }
                    if !d.comment.isEmpty { row("Comment", d.comment) }
                    row("Added", torrent.addedDate?.formatted(date: .abbreviated, time: .shortened) ?? "–")
                }
                group {
                    row("Downloaded", Format.bytes(torrent.totalDownloaded))
                    row("Uploaded", Format.bytes(torrent.totalUploaded))
                    row("Ratio", torrent.ratio.formatted(.number.precision(.fractionLength(2))))
                }
                HStack {
                    if !store.isRemote {
                        Button("Show in Files", systemImage: "folder") { FilesApp.open(torrent.contentURL) }
                    }
                    Spacer()
                    ShareLink(item: d.magnetLink, preview: SharePreview(d.name)) {
                        Label("Share Magnet Link", systemImage: "square.and.arrow.up")
                    }
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task(id: torrent.id) {
            guard let backend = store.backend else { return }
            let id = torrent.id
            // Polled: a remote Mac answers on the next request.
            while !Task.isCancelled {
                if let d = await Task.detached(operation: { backend.details(of: id) }).value {
                    details = d
                    if !backend.isRemote { break }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 14)
            .background(.fill.quinary, in: .rect(cornerRadius: 12, style: .continuous))
            .padding(.bottom, 14)
    }

    private func row(_ title: LocalizedStringKey, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 16)
            Text(value)
                .font(mono ? .caption.monospaced() : .body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .lineLimit(3)
        }
        .padding(.vertical, 10)
    }
}

/// Opens the Files app at a location inside the app's Documents folder.
enum FilesApp {
    /// Opens the folder that holds `url`.
    static func open(_ url: URL) {
        let folder = url.deletingLastPathComponent()
        // Files matches the path literally and ignores links through a symlink. On iPhone the app's
        // folder is really /private/var/mobile/…, but most URLs (and resolvingSymlinksInPath) say
        // /var/mobile/…, so pass the canonical path.
        let path = (try? folder.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath ?? folder.path
        var components = URLComponents(url: URL(filePath: path, directoryHint: .isDirectory), resolvingAgainstBaseURL: false)
        components?.scheme = "shareddocuments"
        if let target = components?.url { UIApplication.shared.open(target) }
    }
}
