import QuickLook
import SwiftUI
import TorrentKit
import TorrentUI

struct TorrentDetailView: View {
    var store: TorrentStore
    var torrentID: String

    @State private var feed = PieceMapFeed()
    @State private var selectedFiles: Set<Int> = []
    @State private var confirmingRemoval = false
    @State private var previewURL: URL?

    private var status: TorrentStatus? { store.status(of: torrentID) }

    var body: some View {
        ScrollView {
            if let status {
                VStack(alignment: .leading, spacing: 20) {
                    TorrentHeader(torrent: status)
                    if let file = feed.files.first(where: { $0.index == status.fileDownloadingFromStart }) {
                        FromStartBanner(file: file, onOpen: { open(file.url(in: status.savePath)) }) {
                            perform { try $0.stopDownloadingFromStart(torrent: torrentID) }
                        }
                    }
                    PieceMapCard(
                        map: feed.map, highlightedRanges: highlightedRanges(status),
                        onSetPriority: canChangePriority(status) ? { range, priority in setPriority(priority, pieces: range) } : nil
                    )
                    FileList(
                        files: feed.files, savePath: status.savePath, selection: $selectedFiles,
                        onSetPriority: canChangePriority(status) ? { files, priority in setPriority(priority, files: files) } : nil,
                        onDownloadFromStart: canChangePriority(status) ? { index in
                            perform { try $0.downloadFromStart(file: index, torrent: torrentID) }
                        } : nil,
                        onStopDownloadingFromStart: { perform { try $0.stopDownloadingFromStart(torrent: torrentID) } },
                        onOpen: open
                    )
                }
                .padding(20)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .overlay {
            if status == nil {
                ContentUnavailableView("Torrent Removed", systemImage: "xmark.circle")
            }
        }
        .navigationTitle(status?.name ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbarContent }
        .task(id: torrentID) {
            guard let session = store.session else { return }
            selectedFiles = []
            await feed.run(session: session, torrentID: torrentID)
        }
        #if os(iOS)
        .quickLookPreview($previewURL)
        #endif
        .confirmationDialog("Remove “\(status?.name ?? "")”?", isPresented: $confirmingRemoval) {
            Button("Remove from List") { store.remove(torrentID, deleteFiles: false) }
            Button("Remove and Delete Files", role: .destructive) { store.remove(torrentID, deleteFiles: true) }
        } message: {
            Text("Removing keeps downloaded files unless you choose to delete them.")
        }
    }

    /// Pieces of the selected files.
    private func highlightedRanges(_ status: TorrentStatus) -> [ClosedRange<Int>] {
        feed.map.files.filter { selectedFiles.contains($0.id) }.compactMap(\.pieces)
    }

    /// Runs an engine action, then refreshes the map and files right away.
    private func perform(_ action: (TorrentSession) throws -> Void) {
        guard store.run(action) else { return }
        feed.refreshSoon()
    }

    private func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        previewURL = url
        #endif
    }

    /// libtorrent ignores priority changes once every piece is downloaded.
    private func canChangePriority(_ status: TorrentStatus) -> Bool {
        status.hasMetadata && status.state != .seeding
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
            #if os(macOS)
            ToolbarItem {
                inOrderToggle(status)
                    .toggleStyle(.button)
            }
            ToolbarItem {
                Button("Remove", systemImage: "trash") { confirmingRemoval = true }
            }
            #else
            ToolbarItem {
                Menu("More", systemImage: "ellipsis.circle") {
                    inOrderToggle(status)
                    Button("Remove…", systemImage: "trash", role: .destructive) { confirmingRemoval = true }
                }
            }
            #endif
        }
    }

    /// Sequential order for the whole torrent. Download from Start manages it while active.
    private func inOrderToggle(_ status: TorrentStatus) -> some View {
        Toggle(isOn: Binding(get: { status.isSequential }, set: { on in
            perform { try $0.setSequential(on, torrent: torrentID) }
        })) {
            Label("Download in Order", systemImage: "arrow.right.to.line")
        }
        .disabled(status.fileDownloadingFromStart >= 0 || status.state == .seeding)
        .help(status.fileDownloadingFromStart >= 0
              ? "Download from Start is choosing the order right now"
              : "Download pieces in order from the start of the torrent instead of rarest first")
    }
}

struct TorrentHeader: View {
    var torrent: TorrentStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(torrent.name)
                .font(.title2.weight(.semibold))
                .lineLimit(2)
                .textSelection(.enabled)
            ProgressView(value: torrent.progress)
                .tint(torrent.isPaused || torrent.isQueued ? .secondary : .accentColor)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { details; Spacer(); speeds }
                VStack(alignment: .leading, spacing: 4) { details; speeds }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    private var details: some View {
        HStack(spacing: 6) {
            Text(Format.state(torrent))
            Text("·")
            Text(Format.percent(torrent.progress))
            if torrent.hasMetadata {
                Text("·")
                Text("\(Format.bytes(torrent.totalWantedDone)) of \(Format.bytes(torrent.totalWanted))")
            }
            if let eta = Format.eta(torrent.eta) {
                Text("·")
                Text("\(eta) left")
            }
        }
        .lineLimit(1)
    }

    private var speeds: some View {
        HStack(spacing: 12) {
            Label(Format.rate(torrent.downloadRate), systemImage: "arrow.down")
            Label(Format.rate(torrent.uploadRate), systemImage: "arrow.up")
            Label("\(torrent.connectedPeers)", systemImage: "person.2")
                .help("Connected peers")
        }
        .labelStyle(CompactLabelStyle())
        .lineLimit(1)
    }
}

/// Shown while a file downloads from its start.
struct FromStartBanner: View {
    var file: TorrentFile
    var onOpen: () -> Void
    var onStop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Downloading from Start")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(file.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(file.canOpen
                     ? String(localized: "Ready to \(Format.percent(file.readyFraction)). Other files wait until it finishes.")
                     : String(localized: "Getting the start and end first. Other files wait until it finishes."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            if file.canOpen {
                Button("Open", action: onOpen)
                    .buttonStyle(.borderedProminent)
            }
            Button("Stop", action: onStop)
        }
        .controlSize(.small)
        .padding(12)
        .background(.fill.quinary, in: .rect(cornerRadius: 12, style: .continuous))
    }
}
