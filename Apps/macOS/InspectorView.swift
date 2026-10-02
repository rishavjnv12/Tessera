import SwiftUI
import TesseraKit
import TesseraUI

/// Details pane below the torrent table: the piece map, then Files, Peers, Trackers and Info.
/// Wide panes put them side by side; narrow ones stack them.
struct InspectorView: View {
    var store: TorrentStore
    var selection: Set<String>

    var body: some View {
        if selection.count == 1, let id = selection.first, let torrent = store.status(of: id) {
            TorrentInspector(store: store, torrent: torrent)
                .id(id)
        } else {
            ContentUnavailableView(
                selection.isEmpty ? "No Selection" : "\(selection.count) Torrents Selected",
                systemImage: selection.isEmpty ? "rectangle.bottomthird.inset.filled" : "square.stack",
                description: Text(selection.isEmpty ? "Select a torrent to see its pieces, files and peers." : "Select one torrent to see its details.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity) // centered in the pane, not pinned to its left edge
        }
    }
}

enum InspectorTab: String, CaseIterable, Identifiable {
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

private struct TorrentInspector: View {
    var store: TorrentStore
    var torrent: TorrentStatus

    @AppStorage("inspectorTab") private var tab: InspectorTab = .files
    @State private var feed = PieceMapFeed()
    @State private var selectedFiles: Set<Int> = []
    /// Current pane width, used only to choose one or two columns.
    @State private var width: CGFloat = 0

    private var canChangePriority: Bool { torrent.hasMetadata && torrent.state != .seeding }

    /// At or above this width the piece map and the tabs sit side by side.
    private static let sideBySideWidth: CGFloat = 760

    var body: some View {
        Group {
            if width >= Self.sideBySideWidth {
                // Columns may shrink to nothing: their contents (the peer table's column minimums,
                // a width taken from the current width) must never raise the window's minimum width.
                HStack(alignment: .top, spacing: 0) {
                    ScrollView { overview.padding(16).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(minWidth: 0, maxWidth: min(max(width * 0.42, 340), 600))
                        .layoutPriority(1)
                    Divider()
                    ScrollView { tabs.padding(16).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(minWidth: 0, maxWidth: .infinity)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        overview
                        tabs
                    }
                    .padding(16)
                    // A row wider than the pane must not widen the content (a ScrollView centers it,
                    // which hid the left edge); anchor to the leading edge instead.
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 0, maxWidth: .infinity)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Only records the width to pick a layout; it never sizes anything, so it can't go stale.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: torrent.id) {
            guard let backend = store.backend else { return }
            await feed.run(backend: backend, torrentID: torrent.id)
        }
    }

    /// Name, progress and the piece map.
    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let file = feed.files.first(where: { $0.index == torrent.fileDownloadingFromStart }) {
                FromStartBanner(file: file, onOpen: { NSWorkspace.shared.open(file.url(in: torrent.savePath)) }) {
                    perform { try $0.stopDownloadingFromStart(torrent: torrent.id) }
                }
            }
            PieceMapCard(
                map: feed.map,
                highlightedRanges: feed.map.files.filter { selectedFiles.contains($0.id) }.compactMap(\.pieces),
                fitHeight: 130,
                onSetPriority: canChangePriority ? { range, priority in
                    guard store.setPriority(priority, pieces: range, torrent: torrent.id) else { return }
                    feed.showPriority(priority, pieces: [range])
                    feed.refreshSoon()
                } : nil
            )
        }
    }

    /// Files, Peers, Trackers and Info.
    private var tabs: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Show", selection: $tab) {
                ForEach(InspectorTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            switch tab {
            case .files: files
            case .peers: PeersTab(store: store, torrentID: torrent.id)
            case .trackers: TrackersTab(store: store, torrent: torrent)
            case .info: InfoTab(store: store, torrent: torrent)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(torrent.name)
                .font(.headline)
                .lineLimit(2)
                .textSelection(.enabled)
            ProgressView(value: torrent.progress)
                .tint(torrent.isPaused || torrent.isQueued ? .secondary : .accentColor)
            HStack(spacing: 6) {
                Text(Format.state(torrent))
                Text("·")
                Text(Format.percent(torrent.progress))
                if let eta = Format.eta(torrent.eta) {
                    Text("·")
                    Text("\(eta) left")
                }
                Spacer()
                Label(Format.rate(torrent.downloadRate), systemImage: "arrow.down")
                Label(Format.rate(torrent.uploadRate), systemImage: "arrow.up")
            }
            .labelStyle(CompactLabelStyle())
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
        }
    }

    private var files: some View {
        FileList(
            files: feed.files, savePath: torrent.savePath, selection: $selectedFiles,
            onSetPriority: canChangePriority ? { ids, priority in
                guard store.setPriority(priority, files: ids, torrent: torrent.id) else { return }
                feed.showPriority(priority, pieces: feed.map.files.filter { ids.contains($0.id) }.compactMap(\.pieces))
                feed.refreshSoon()
            } : nil,
            onDownloadFromStart: canChangePriority ? { index in
                perform { try $0.downloadFromStart(file: index, torrent: torrent.id) }
            } : nil,
            onStopDownloadingFromStart: { perform { try $0.stopDownloadingFromStart(torrent: torrent.id) } },
            onOpen: { NSWorkspace.shared.open($0) }
        )
    }

    private func perform(_ action: (any TorrentBackend) throws -> Void) {
        guard store.run(action) else { return }
        feed.refreshSoon()
    }
}

// MARK: - Peers

private struct PeersTab: View {
    var store: TorrentStore
    var torrentID: String
    @State private var poll = Poll<[Peer]>()
    @State private var sortOrder = [KeyPathComparator(\Peer.downloadRate, order: .reverse)]

    var body: some View {
        let peers = (poll.value ?? []).sorted(using: sortOrder)
        VStack(alignment: .leading, spacing: 8) {
            Text(poll.value == nil ? "Loading…" : peers.count == 1 ? "1 peer connected" : "\(peers.count) peers connected")
                .font(.caption)
                .foregroundStyle(.secondary)
            Table(peers, sortOrder: $sortOrder) {
                TableColumn("Address", value: \.address) { p in
                    HStack(spacing: 4) {
                        Text(p.address).lineLimit(1).truncationMode(.middle)
                        if p.isEncrypted { Image(systemName: "lock.fill").imageScale(.small).foregroundStyle(.secondary).help("Encrypted") }
                    }
                }
                .width(min: 110, ideal: 150)
                TableColumn("Client", value: \.client) { p in
                    Text(p.isWebSeed ? String(localized: "Web seed") : (p.client.isEmpty ? "–" : p.client)).lineLimit(1)
                }
                .width(min: 80, ideal: 120)
                TableColumn("Has", value: \.progress) { p in
                    Text(p.isSeed ? String(localized: "All") : Format.percent(p.progress))
                }
                .width(min: 36, ideal: 44)
                TableColumn("Down", value: \.downloadRate) { p in Text(p.downloadRate > 0 ? Format.rate(p.downloadRate) : "–") }
                    .width(min: 56, ideal: 70)
                TableColumn("Up", value: \.uploadRate) { p in Text(p.uploadRate > 0 ? Format.rate(p.uploadRate) : "–") }
                    .width(min: 56, ideal: 70)
            }
            .monospacedDigit()
            .frame(minHeight: 260)
        }
        .task(id: torrentID) {
            guard let backend = store.backend else { return }
            let id = torrentID
            await poll.run(every: .seconds(2)) { backend.peers(of: id) }
        }
    }
}

// MARK: - Trackers

private struct TrackersTab: View {
    var store: TorrentStore
    var torrent: TorrentStatus
    @State private var poll = Poll<[Tracker]>()
    @State private var newTracker = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let trackers = poll.value {
                if trackers.isEmpty {
                    Text(torrent.hasMetadata || trackers.isEmpty ? "No trackers. Peers are found through DHT and peer exchange." : "")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(trackers, id: \.url) { tracker in
                    TrackerRow(tracker: tracker)
                        .nativeContextMenu {
                            [.action(MenuAction(String(localized: "Copy Address"), systemImage: "doc.on.doc") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(tracker.url, forType: .string)
                            }),
                             .separator,
                             .action(MenuAction(String(localized: "Remove Tracker"), systemImage: "trash") {
                                 store.run { try $0.removeTracker(tracker.url, torrent: torrent.id) }
                             })]
                        }
                }
            } else {
                ProgressView().controlSize(.small)
            }
            HStack {
                TextField("Add tracker (udp://, http://, https://)", text: $newTracker)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newTracker.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
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
}

private struct TrackerRow: View {
    var tracker: Tracker

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .help(statusText)
            VStack(alignment: .leading, spacing: 2) {
                Text(tracker.url)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(tracker.status == .error ? Color.red : .secondary)
                    .lineLimit(2)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var color: Color {
        switch tracker.status {
        case .working: .green
        case .updating: .orange
        case .error: .red
        default: .secondary.opacity(0.5)
        }
    }

    private var statusText: String {
        switch tracker.status {
        case .working: String(localized: "Working")
        case .updating: String(localized: "Updating")
        case .error: String(localized: "Error")
        default: String(localized: "Not contacted yet")
        }
    }

    private var detail: String {
        var parts = [statusText]
        if tracker.seeds >= 0 { parts.append(String(localized: "\(tracker.seeds) seeds")) }
        if tracker.peers >= 0 { parts.append(String(localized: "\(tracker.peers) peers")) }
        if !tracker.message.isEmpty { parts.append(tracker.message) }
        parts.append(String(localized: "tier \(tracker.tier)"))
        return parts.joined(separator: " · ")
    }
}

// MARK: - Info

private struct InfoTab: View {
    var store: TorrentStore
    var torrent: TorrentStatus
    @State private var details: TorrentDetails?

    var body: some View {
        Form {
            if let d = details {
                Section {
                    row("Size", d.hasMetadata ? Format.bytes(d.totalSize) : "–")
                    row("Pieces", d.hasMetadata ? "\(d.numPieces.formatted()) × \(Format.bytes(Int64(d.pieceLength)))" : "–")
                    row("Files", d.hasMetadata ? d.fileCount.formatted() : "–")
                    row("Private", d.isPrivate ? String(localized: "Yes, trackers only") : String(localized: "No"))
                }
                Section {
                    if let v1 = d.infoHashV1 { row("Info hash", v1, mono: true) }
                    if let v2 = d.infoHashV2 { row("Info hash v2", v2, mono: true) }
                    if let date = d.creationDate { row("Created", date.formatted(date: .abbreviated, time: .shortened)) }
                    if !d.creator.isEmpty { row("Created by", d.creator) }
                    if !d.comment.isEmpty { row("Comment", d.comment) }
                    row("Added", torrent.addedDate?.formatted(date: .abbreviated, time: .shortened) ?? "–")
                    if let done = torrent.completedDate { row("Completed", done.formatted(date: .abbreviated, time: .shortened)) }
                }
                Section {
                    row("Downloaded", Format.bytes(torrent.totalDownloaded))
                    row("Uploaded", Format.bytes(torrent.totalUploaded))
                    row("Ratio", torrent.ratio.formatted(.number.precision(.fractionLength(2))))
                }
                Section {
                    LabeledContent("Location") {
                        HStack {
                            Text(torrent.contentURL.deletingLastPathComponent().path.abbreviatingHome)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Button("Show", systemImage: "arrow.right.circle.fill") {
                                NSWorkspace.shared.activateFileViewerSelecting([torrent.contentURL])
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Show in Finder")
                        }
                    }
                    LabeledContent("Magnet link") {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(d.magnetLink, forType: .string)
                        }
                        .controlSize(.small)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(minHeight: 520)
        .padding(-16) // grouped form brings its own margins
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

    private func row(_ title: LocalizedStringKey, _ value: String, mono: Bool = false) -> some View {
        LabeledContent(title) {
            Text(value)
                .font(mono ? .caption.monospaced() : nil)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }
}

extension String {
    /// "/Users/name/Tessera" as "~/Tessera".
    var abbreviatingHome: String {
        guard let home = getpwuid(getuid()).flatMap({ String(validatingCString: $0.pointee.pw_dir) }), hasPrefix(home) else { return self }
        return "~" + dropFirst(home.count)
    }
}
