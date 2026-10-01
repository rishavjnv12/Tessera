import SwiftUI
import TorrentKit
import TorrentUI

/// Sortable list of torrents. Right-click acts on the clicked row, or on the whole selection
/// when the clicked row is part of it. Double-click shows the files in Finder.
struct TorrentTable: View {
    var store: TorrentStore
    var rows: [TorrentStatus]
    @Binding var selection: Set<String>
    var onRemove: (Set<String>, _ deleteFiles: Bool) -> Void

    @State private var sortOrder: [KeyPathComparator<TorrentStatus>] = [KeyPathComparator(\.addedOrder)]

    var body: some View {
        Table(sorted, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { t in
                cell(t) {
                    HStack(spacing: 6) {
                        StatusSymbol(torrent: t)
                        Text(t.name).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .width(min: 180, ideal: 320)

            TableColumn("Progress", value: \.progress) { t in
                cell(t) {
                    HStack(spacing: 6) {
                        ProgressView(value: t.progress)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .tint(t.isPaused || t.isQueued ? .secondary : .accentColor)
                        Text(Format.percent(t.progress))
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }
            .width(min: 110, ideal: 150)

            TableColumn("Size", value: \.totalWanted) { t in
                cell(t) { Text(t.hasMetadata ? Format.bytes(t.totalWanted) : "–").foregroundStyle(.secondary) }
            }
            .width(min: 60, ideal: 80)

            TableColumn("Status", value: \.statusOrder) { t in
                cell(t) { Text(Format.state(t)).foregroundStyle(t.errorMessage == nil ? .secondary : Color.red).lineLimit(1) }
            }
            .width(min: 80, ideal: 110)

            TableColumn("Down", value: \.downloadRate) { t in
                cell(t) { Text(t.downloadRate > 0 ? Format.rate(t.downloadRate) : "–").foregroundStyle(.secondary) }
            }
            .width(min: 60, ideal: 80)

            TableColumn("Up", value: \.uploadRate) { t in
                cell(t) { Text(t.uploadRate > 0 ? Format.rate(t.uploadRate) : "–").foregroundStyle(.secondary) }
            }
            .width(min: 60, ideal: 80)

            TableColumn("ETA", value: \.etaOrder) { t in
                cell(t) { Text(Format.eta(t.eta) ?? "–").foregroundStyle(.secondary) }
            }
            .width(min: 50, ideal: 70)

            TableColumn("Ratio", value: \.ratio) { t in
                cell(t) { Text(t.ratio.formatted(.number.precision(.fractionLength(2)))).foregroundStyle(.secondary) }
            }
            .width(min: 40, ideal: 50)

            TableColumn("Peers", value: \.connectedPeers) { t in
                cell(t) { Text("\(t.connectedPeers)").foregroundStyle(.secondary) }
            }
            .width(min: 40, ideal: 50)
        }
        .monospacedDigit()
        .contextMenu(forSelectionType: String.self) { _ in
            // Right-click menus are drawn by AppKit in each cell (see `cell`); this only adds double-click.
        } primaryAction: { ids in
            NSWorkspace.shared.activateFileViewerSelecting(store.torrents.filter { ids.contains($0.id) }.map(\.contentURL))
        }
    }

    private var sorted: [TorrentStatus] {
        rows.sorted(using: sortOrder)
    }

    private func cell<Content: View>(_ torrent: TorrentStatus, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .nativeContextMenu { menu(for: torrent) }
    }

    private func menu(for torrent: TorrentStatus) -> [ContextMenuItem] {
        let ids = selection.contains(torrent.id) ? selection : [torrent.id]
        let targets = store.torrents.filter { ids.contains($0.id) }
        let plural = targets.count > 1
        var items: [ContextMenuItem] = []
        if targets.contains(where: \.isPaused) {
            items.append(.action(MenuAction(plural ? String(localized: "Resume \(targets.count) Torrents") : String(localized: "Resume"),
                                            systemImage: "play.fill") { store.resume(ids) }))
        }
        if targets.contains(where: { !$0.isPaused }) {
            items.append(.action(MenuAction(plural ? String(localized: "Pause \(targets.count) Torrents") : String(localized: "Pause"),
                                            systemImage: "pause.fill") { store.pause(ids) }))
        }
        items.append(.separator)
        items.append(.action(MenuAction(String(localized: "Show in Finder"), systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.contentURL))
        }))
        if !plural {
            items.append(.action(MenuAction(String(localized: "Copy Magnet Link"), systemImage: "link") {
                guard let link = store.backend?.details(of: torrent.id)?.magnetLink else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
            }))
            items.append(.separator)
            items.append(.action(MenuAction(String(localized: "Download in Order"), systemImage: "arrow.right.to.line",
                                            isEnabled: torrent.fileDownloadingFromStart < 0 && torrent.state != .seeding,
                                            isChecked: torrent.isSequential) {
                store.run { try $0.setSequential(!torrent.isSequential, torrent: torrent.id) }
            }))
        }
        items.append(.separator)
        items.append(.action(MenuAction(plural ? String(localized: "Remove \(targets.count) Torrents…") : String(localized: "Remove…"),
                                        systemImage: "trash") { onRemove(ids, false) }))
        items.append(.action(MenuAction(String(localized: "Remove and Delete Files…"), systemImage: "trash.slash") { onRemove(ids, true) }))
        return items
    }
}

/// Small colored symbol for a torrent's state.
struct StatusSymbol: View {
    var torrent: TorrentStatus

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
            .imageScale(.medium)
            .frame(width: 16)
            .help(Format.state(torrent))
    }

    private var symbol: String {
        if torrent.errorMessage != nil { return "exclamationmark.triangle.fill" }
        if torrent.isPaused { return "pause.circle.fill" }
        if torrent.isQueued { return "clock.fill" }
        switch torrent.state {
        case .checkingFiles, .checkingResumeData: return "arrow.triangle.2.circlepath.circle.fill"
        case .downloadingMetadata: return "ellipsis.circle.fill"
        case .downloading: return "arrow.down.circle.fill"
        case .finished: return "checkmark.circle.fill"
        case .seeding: return "arrow.up.circle.fill"
        @unknown default: return "circle"
        }
    }

    private var color: Color {
        if torrent.errorMessage != nil { return .red }
        if torrent.isPaused || torrent.isQueued { return .secondary }
        switch torrent.state {
        case .downloading, .downloadingMetadata: return .accentColor
        case .seeding: return .green
        case .finished: return .green
        default: return .secondary
        }
    }
}

extension TorrentStatus {
    /// What the menu commands depend on, to update them only when it changes.
    var menuState: [String] {
        [id, isPaused ? "p" : "", isSequential ? "s" : "", "\(fileDownloadingFromStart)", "\(state.rawValue)"]
    }

    /// Sort key for the default order: when the torrent was added.
    @objc var addedOrder: Double { addedDate?.timeIntervalSince1970 ?? 0 }
    /// Sort key for the Status column: active first.
    @objc var statusOrder: Int {
        if errorMessage != nil { return 0 }
        if isPaused { return 6 }
        if isQueued { return 5 }
        switch state {
        case .downloading, .downloadingMetadata: return 1
        case .checkingFiles, .checkingResumeData: return 2
        case .seeding: return 3
        case .finished: return 4
        @unknown default: return 7
        }
    }
    /// Sort key for the ETA column: unknown ETAs last.
    @objc var etaOrder: Double { eta < 0 ? .greatestFiniteMagnitude : eta }
}
