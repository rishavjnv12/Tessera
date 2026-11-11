import SwiftUI
import TesseraKit
import TesseraUI
import UniformTypeIdentifiers

extension TorrentFile {
    /// Bytes from the start needed before offering to open a file that is still downloading.
    static let openThreshold: Int64 = 8 * 1024 * 1024

    /// Share of the file readable from its start, 0...1.
    var readyFraction: Double {
        size > 0 ? Double(contiguousBytes) / Double(size) : 1
    }

    /// Complete, or enough of its start and its end are here for a player to begin.
    var canOpen: Bool {
        progress >= 1 || (contiguousBytes >= min(size, Self.openThreshold) && hasEnd)
    }

    /// Real location on disk. Resolves the sandbox container's link to ~/Downloads, which
    /// Finder and other apps are not allowed to open (torrents added before this fix use it).
    func url(in savePath: String) -> URL {
        URL(filePath: savePath).appending(path: path).resolvingSymlinksInPath()
    }
}

/// Files with their piece ranges and priorities.
///
/// With `selection` (Mac), clicking rows selects files: their pieces are outlined on the map and
/// their priority can be changed together. Without it (iPhone), tapping a row opens its file and
/// the row's context menu outlines its pieces through `highlighted`.
struct FileList: View {
    var files: [TorrentFile]
    var savePath: String
    var selection: Binding<Set<Int>>?
    /// The file whose pieces are outlined on the map. nil leaves "Highlight Pieces" out of the menus.
    var highlighted: Binding<Int?>?
    /// nil when priorities cannot change, e.g. once the torrent is complete.
    var onSetPriority: ((Set<Int>, PiecePriority) -> Void)?
    var onDownloadFromStart: ((Int) -> Void)?
    var onStopDownloadingFromStart: (() -> Void)?
    /// nil when the files are not on this device (a remote Mac).
    var onOpen: ((URL) -> Void)?

    private var selected: Set<Int> { selection?.wrappedValue ?? [] }

    private var selectedPriority: PiecePriority? {
        PiecePriority.common(files.filter { selected.contains($0.index) }.map { PiecePriority(level: $0.priority) })
    }

    /// The one selected file, when it can be downloaded from its start.
    private var singleIncompleteSelection: TorrentFile? {
        guard selected.count == 1, let file = files.first(where: { selected.contains($0.index) }),
              file.progress < 1, !file.downloadsFromStart else { return nil }
        return file
    }

    var body: some View {
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Files").font(.headline)
                    Text(selected.isEmpty ? "\(files.count)" : "\(selected.count) of \(files.count) selected")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    if let selection {
                        selectionControls(selection)
                    }
                }
                LazyVStack(spacing: 2) {
                    ForEach(files) { file in
                        FileListRow(
                            name: file.name, path: file.path, size: file.size, progress: file.progress,
                            pieces: file.firstPiece >= 0 ? file.firstPiece...file.lastPiece : nil,
                            priority: PiecePriority(level: file.priority),
                            isSelected: selected.contains(file.index),
                            isHighlighted: highlighted?.wrappedValue == file.index,
                            readiness: file.downloadsFromStart ? .init(readyFraction: file.readyFraction, hasEnd: file.hasEnd) : nil,
                            onOpen: file.canOpen && file.downloadsFromStart ? onOpen.map { open in { open(file.url(in: savePath)) } } : nil,
                            actions: actions(for: file),
                            onSetPriority: onSetPriority.map { set in
                                { priority in set(selected.contains(file.index) ? selected : [file.index], priority) }
                            },
                            action: rowAction(for: file)
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func selectionControls(_ selection: Binding<Set<Int>>) -> some View {
        if !selected.isEmpty {
            if let onDownloadFromStart, let file = singleIncompleteSelection {
                Button("Download from Start", systemImage: "play.circle") { onDownloadFromStart(file.index) }
                    .help("Download this file first, in order, so it can be opened early")
            }
            if let onSetPriority {
                PriorityMenu(current: selectedPriority) { onSetPriority(selected, $0) }
                    .fixedSize()
            }
            Button("Clear") { selection.wrappedValue = [] }
                .buttonStyle(.borderless)
        } else if files.count > 1 {
            Button("Select All") { selection.wrappedValue = Set(files.map(\.index)) }
                .buttonStyle(.borderless)
        }
    }

    /// Selects the file when rows are selectable, otherwise opens it. nil when tapping does nothing.
    private func rowAction(for file: TorrentFile) -> (() -> Void)? {
        if let selection {
            return { selection.wrappedValue.formSymmetricDifference([file.index]) }
        }
        guard file.canOpen, let onOpen else { return nil }
        let url = file.url(in: savePath)
        return { onOpen(url) }
    }

    private func actions(for file: TorrentFile) -> [MenuAction] {
        var actions: [MenuAction] = []
        if file.downloadsFromStart, let onStopDownloadingFromStart {
            actions.append(MenuAction(String(localized: "Stop Downloading from Start"), systemImage: "stop.circle", action: onStopDownloadingFromStart))
        } else if file.progress < 1, let onDownloadFromStart {
            actions.append(MenuAction(String(localized: "Download from Start"), systemImage: "play.circle") { onDownloadFromStart(file.index) })
        }
        if file.canOpen, let onOpen {
            let url = file.url(in: savePath)
            actions.append(MenuAction(String(localized: "Open"), systemImage: "arrow.up.forward.app") { onOpen(url) })
            #if os(macOS)
            actions.append(MenuAction(String(localized: "Show in Finder"), systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            })
            #endif
        }
        if let highlighted, file.firstPiece >= 0 {
            if highlighted.wrappedValue == file.index {
                actions.append(MenuAction(String(localized: "Stop Highlighting"), systemImage: "xmark.circle") {
                    highlighted.wrappedValue = nil
                })
            } else {
                actions.append(MenuAction(String(localized: "Highlight Pieces"), systemImage: "highlighter") {
                    highlighted.wrappedValue = file.index
                })
            }
        }
        return actions
    }
}

struct FileListRow: View {
    struct Readiness: Equatable {
        var readyFraction: Double
        var hasEnd: Bool
    }

    var name: String
    var path: String
    var size: Int64
    var progress: Double
    var pieces: ClosedRange<Int>?
    var priority: PiecePriority = .normal
    var isSelected = false
    /// Its pieces are outlined on the map.
    var isHighlighted = false
    /// Shown while the file downloads from its start.
    var readiness: Readiness?
    var onOpen: (() -> Void)?
    var actions: [MenuAction] = []
    var onSetPriority: ((PiecePriority) -> Void)?
    /// Runs when the row is tapped. nil when tapping does nothing.
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
            if let onOpen {
                Button("Open", action: onOpen)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Open the part downloaded so far")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(background)
        .help(path)
        .fileContextMenu(actions: actions, current: priority, onSetPriority: onSetPriority)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(priority == .normal ? "" : priority.title)
    }

    /// Selected rows are tinted; a highlighted row is outlined like its pieces on the map.
    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if isHighlighted {
            shape.fill(Color.accentColor.opacity(0.12))
                .overlay(shape.strokeBorder(Color.accentColor, lineWidth: 1.5))
        } else if isSelected {
            shape.fill(Color.accentColor.opacity(0.14))
        }
    }

    private var content: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : FileKind.symbol(for: name))
                .foregroundStyle(isSelected || isHighlighted || progress >= 1 || readiness != nil ? Color.accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(priority == .skip, color: .secondary)
                if let readiness {
                    ReadinessBar(ready: readiness.readyFraction, downloaded: progress)
                    Text(readinessText(readiness))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 8)
            if readiness != nil {
                Badge(title: String(localized: "From Start"), systemImage: "play.circle", color: .accentColor)
            } else if priority != .normal {
                PriorityBadge(priority: priority)
            }
            Text(Format.percent(progress))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 40, alignment: .trailing)
        }
        .opacity(priority == .skip ? 0.6 : 1)
        .contentShape(Rectangle())
    }

    private var detail: String {
        var parts = [Format.bytes(size)]
        if let pieces {
            parts.append(pieces.count == 1
                ? String(localized: "piece \(pieces.lowerBound.formatted())")
                : String(localized: "pieces \(pieces.lowerBound.formatted())–\(pieces.upperBound.formatted())"))
        }
        return parts.joined(separator: " · ")
    }

    private func readinessText(_ readiness: Readiness) -> String {
        let ready = String(localized: "Ready to \(Format.percent(readiness.readyFraction)) from the start")
        let end = readiness.hasEnd ? String(localized: "end downloaded") : String(localized: "getting the end")
        return "\(ready) · \(end)"
    }
}

/// SF Symbol for a file, from its extension.
enum FileKind {
    /// Common torrent formats the system may not declare a type for.
    private static let subtitles: Set<String> = ["srt", "vtt", "ass", "ssa", "sub", "idx"]
    private static let videos: Set<String> = ["mkv", "webm", "avi", "wmv", "flv", "m2ts", "ts"]

    static func symbol(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if subtitles.contains(ext) { return "captions.bubble" }
        if videos.contains(ext) { return "film" }
        guard let type = UTType(filenameExtension: ext) else { return "doc" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return "doc.zipper" }
        if type.conforms(to: .text) || type.conforms(to: .pdf) { return "doc.text" }
        return "doc"
    }
}

/// How far a file can be read from its start (solid) over how much is downloaded (light).
struct ReadinessBar: View {
    var ready: Double
    var downloaded: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(Color.accentColor.opacity(0.3))
                    .frame(width: proxy.size.width * min(1, max(downloaded, ready)))
                Capsule().fill(Color.accentColor)
                    .frame(width: proxy.size.width * min(1, ready))
            }
        }
        .frame(height: 4)
        .frame(maxWidth: 360)
        .accessibilityHidden(true)
    }
}

struct Badge: View {
    var title: String
    var systemImage: String
    var color: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(CompactLabelStyle())
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: .capsule)
    }
}

struct PriorityBadge: View {
    var priority: PiecePriority

    var body: some View {
        Badge(title: priority == .skip ? String(localized: "Skipped") : priority.title, systemImage: priority.systemImage, color: color)
    }

    private var color: Color {
        switch priority {
        case .highest: .pink
        case .lowest: .teal
        case .normal, .skip: .secondary
        }
    }
}

/// Shown while a file downloads from its start.
struct FromStartBanner: View {
    var file: TorrentFile
    /// nil when the file is not on this device.
    var onOpen: (() -> Void)?
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
            if file.canOpen, let onOpen {
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
