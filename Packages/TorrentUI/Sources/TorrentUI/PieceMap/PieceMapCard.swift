import SwiftUI

/// The piece map with its controls: mode, zoom, legend, an info line and, when
/// `onSetPriority` is set, selecting a run of pieces to change their priority.
public struct PieceMapCard: View {
    public var map: PieceMap
    public var highlightedRanges: [ClosedRange<Int>]
    public var fitHeight: CGFloat
    public var onSetPriority: ((ClosedRange<Int>, PiecePriority) -> Void)?

    @State private var mode: PieceMapMode = .progress
    @State private var zoom: CGFloat = 1
    @State private var inspection: PieceMapInspection?
    @State private var selection: ClosedRange<Int>?

    public init(
        map: PieceMap, highlightedRanges: [ClosedRange<Int>] = [], fitHeight: CGFloat = 160,
        onSetPriority: ((ClosedRange<Int>, PiecePriority) -> Void)? = nil
    ) {
        self.map = map
        self.highlightedRanges = highlightedRanges
        self.fitHeight = fitHeight
        self.onSetPriority = onSetPriority
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if map.pieceCount == 0 {
                ContentUnavailableView {
                    Label("Waiting for Metadata", systemImage: "square.grid.3x3")
                } description: {
                    Text("Pieces appear once the torrent's details arrive from peers.")
                }
                .frame(height: fitHeight)
            } else {
                PieceMapView(
                    map: map, mode: mode, highlightedRanges: highlightedRanges,
                    fitHeight: fitHeight, zoom: $zoom, inspection: $inspection,
                    selection: onSetPriority == nil ? nil : $selection
                )
                footer
                if let selection, onSetPriority != nil {
                    selectionBar(selection)
                }
            }
        }
        .padding(14)
        .background(.fill.quinary, in: .rect(cornerRadius: 14, style: .continuous))
        .onChange(of: onSetPriority == nil) { _, disabled in if disabled { selection = nil } }
        .onChange(of: map.pieceCount) { _, _ in selection = nil }
    }

    private func selectionBar(_ range: ClosedRange<Int>) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(range.count == 1
                     ? "Piece \(range.lowerBound.formatted()) selected"
                     : "Pieces \(range.lowerBound.formatted())–\(range.upperBound.formatted()) selected")
                    .fontWeight(.medium)
                Text("\(range.count.formatted()) pieces · \(ByteCountFormatter.string(fromByteCount: Int64(range.count) * Int64(map.pieceLength), countStyle: .file))")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .monospacedDigit()
            Spacer(minLength: 8)
            PriorityMenu(current: PiecePriority.common(map.priority[range].map { PiecePriority(level: Int($0)) })) { priority in
                onSetPriority?(range, priority)
            }
            .fixedSize()
            Button("Clear Selection", systemImage: "xmark.circle.fill") { selection = nil }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.background.secondary, in: .rect(cornerRadius: 10, style: .continuous))
    }

    private var header: some View {
        // One row when it fits, otherwise the controls move under the title.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                titleBlock.fixedSize()
                Spacer(minLength: 8)
                controls
            }
            VStack(alignment: .leading, spacing: 10) {
                titleBlock
                HStack(spacing: 10) { controls }
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Pieces")
                .font(.headline)
            if map.pieceCount > 0 {
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        if map.pieceCount > 0 {
            Picker("Show", selection: $mode) {
                ForEach(PieceMapMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
            zoomControls
        }
    }

    private var zoomControls: some View {
        ControlGroup {
            Button("Zoom Out", systemImage: "minus.magnifyingglass") { zoom = max(1, zoom / 2) }
                .disabled(zoom <= 1)
            Button("Zoom In", systemImage: "plus.magnifyingglass") { zoom *= 2 }
        }
        .labelStyle(.iconOnly)
        .controlSize(.small)
        .fixedSize()
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let inspection {
                Text(inspection.title).fontWeight(.medium)
                Text(inspection.detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        PieceMapLegend(mode: mode, tracksAvailability: map.tracksAvailability)
                        Spacer(minLength: 12)
                        if onSetPriority != nil, selection == nil { selectionHint }
                    }
                    PieceMapLegend(mode: mode, tracksAvailability: map.tracksAvailability)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .monospacedDigit()
        .frame(minHeight: 16)
    }

    private var selectionHint: some View {
        #if os(macOS)
        Text("Drag across pieces to set their priority").foregroundStyle(.tertiary)
        #else
        Text("Touch and hold to select pieces").foregroundStyle(.tertiary)
        #endif
    }

    private var summaryText: String {
        let s = map.summary
        let size = ByteCountFormatter.string(fromByteCount: Int64(map.pieceLength), countStyle: .file)
        var text = String(localized: "\(s.downloaded.formatted()) of \(map.pieceCount.formatted()) · \(size) each")
        if s.downloading > 0 { text += String(localized: " · \(s.downloading) downloading") }
        return text
    }
}

struct PieceMapLegend: View {
    var mode: PieceMapMode
    var tracksAvailability: Bool

    var body: some View {
        HStack(spacing: 12) {
            switch mode {
            case .progress:
                item(.accentColor, "Downloaded")
                partialItem("Downloading")
                item(Color.primary.opacity(0.09), "Missing")
                item(Color.primary.opacity(0.035), "Skipped")
            case .availability:
                if tracksAvailability {
                    let p = PieceMapRenderer.Palette.self
                    item(p.availability[0].opacity(p.availabilityOpacity[0]), "No peers")
                    item(p.availability[1].opacity(p.availabilityOpacity[1]), "1 peer")
                    item(p.availability[2].opacity(p.availabilityOpacity[2]), "2–4")
                    item(p.availability[3].opacity(p.availabilityOpacity[3]), "5+")
                } else {
                    Text("Not tracked while seeding").foregroundStyle(.secondary)
                }
            case .priority:
                let p = PieceMapRenderer.Palette.priority
                item(p.highest, "Highest")
                item(p.normal, "Normal")
                item(p.lowest, "Lowest")
                item(Color.primary.opacity(0.035), "Skip")
            }
        }
        .foregroundStyle(.secondary)
    }

    /// Drawn like a piece being downloaded: filled from the bottom, so it reads differently from
    /// "Downloaded" even where the two colors are close (dark mode).
    private func partialItem(_ title: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.primary.opacity(0.09))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.accentColor.opacity(0.55)).frame(height: 4.5)
                }
                .clipShape(.rect(cornerRadius: 2, style: .continuous))
                .frame(width: 9, height: 9)
            Text(title)
        }
    }

    private func item(_ color: Color, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 9, height: 9)
            Text(title)
        }
    }
}

#Preview("Piece map card") {
    @Previewable @State var simulator = PieceMapSimulator(pieceCount: 25_000)
    PieceMapCard(map: simulator.map) { range, priority in simulator.setPriority(priority, pieces: range) }
        .padding()
        .frame(width: 560)
        .task { await simulator.run() }
}
