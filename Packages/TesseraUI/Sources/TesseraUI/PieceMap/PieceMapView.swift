import SwiftUI

/// What the pointer or finger is on, described for the info line under the map.
public struct PieceMapInspection: Equatable, Sendable {
    public var pieces: Range<Int>
    public var title: String
    public var detail: String
}

/// Grid of every piece in a torrent.
///
/// Hover (Mac, iPad pointer) or tap (iPhone) a cell to inspect it. Pinch to zoom.
/// When `selection` is bound, drag across cells (Mac) or touch and hold, then drag (iPhone)
/// to select a run of pieces; handles at both ends adjust it. Zoomed-in content scrolls
/// vertically inside `fitHeight`.
public struct PieceMapView: View {
    public var map: PieceMap
    public var mode: PieceMapMode
    /// Outlined in the accent color, e.g. the pieces of selected files.
    public var highlightedRanges: [ClosedRange<Int>]
    public var fitHeight: CGFloat
    @Binding public var zoom: CGFloat
    @Binding public var inspection: PieceMapInspection?
    /// nil disables range selection.
    public var selection: Binding<ClosedRange<Int>?>?

    @State private var width: CGFloat = 0
    @State private var inspectedCell: Int?
    @State private var zoomAtGestureStart: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let space = "PieceGrid"

    public init(
        map: PieceMap, mode: PieceMapMode = .progress, highlightedRanges: [ClosedRange<Int>] = [],
        fitHeight: CGFloat = 160, zoom: Binding<CGFloat>, inspection: Binding<PieceMapInspection?> = .constant(nil),
        selection: Binding<ClosedRange<Int>?>? = nil
    ) {
        self.map = map
        self.mode = mode
        self.highlightedRanges = highlightedRanges
        self.fitHeight = fitHeight
        self._zoom = zoom
        self._inspection = inspection
        self.selection = selection
    }

    public var body: some View {
        let layout = PieceGridLayout(pieceCount: map.pieceCount, width: width, fitHeight: fitHeight, zoom: zoom)
        let content = layout.contentSize
        let selected = selection?.wrappedValue.flatMap { validRange($0) }
        ScrollView(.vertical) {
            ZStack(alignment: .topLeading) {
                PieceGridCanvas(map: map, layout: layout, mode: mode)
                    .equatable()
                if !reduceMotion, mode == .progress {
                    ActivePiecesOverlay(cells: PieceMapRenderer.activeCells(map, layout: layout), layout: layout)
                }
                if !highlightedRanges.isEmpty, map.pieceCount > 0 {
                    RangeHighlight(ranges: highlightedRanges.compactMap { validRange($0).map(layout.cells(forPieces:)) },
                                   layout: layout, style: .accent)
                }
                if let selected {
                    RangeHighlight(ranges: [layout.cells(forPieces: selected)], layout: layout, style: .selection)
                }
                if let inspectedCell, inspectedCell < layout.cellCount {
                    let radius = PieceMapRenderer.cornerRadius(for: layout.cellSize)
                    let rect = layout.rect(forCell: inspectedCell)
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.primary, lineWidth: 1.5)
                        .frame(width: layout.cellSize + 2, height: layout.cellSize + 2)
                        .offset(x: rect.minX - 1, y: rect.minY - 1)
                        .allowsHitTesting(false)
                }
                if let selected {
                    selectionHandles(for: selected, layout: layout)
                }
            }
            .frame(width: content.width, height: content.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .coordinateSpace(.named(Self.space))
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point): inspect(layout.cell(at: point), layout: layout)
                case .ended: inspect(nil, layout: layout)
                }
            }
            .onTapGesture(coordinateSpace: .local) { point in
                if selection?.wrappedValue != nil { selection?.wrappedValue = nil }
                let cell = layout.cell(at: point)
                inspect(cell == inspectedCell ? nil : cell, layout: layout)
            }
            .gesture(selectionGesture(layout: layout), including: selection == nil ? .subviews : .all)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDisabled(content.height <= fitHeight)
        .scrollIndicators(content.height > fitHeight ? .automatic : .hidden)
        .frame(height: map.pieceCount == 0 ? fitHeight : min(fitHeight, max(content.height, layout.cellSize)))
        // Measure the width we are offered, not the grid's: the grid is drawn at the measured width,
        // so measuring it let the map grow but never shrink (it held a narrowed Mac pane wide open).
        .frame(minWidth: 0, maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let start = zoomAtGestureStart ?? zoom
                    zoomAtGestureStart = start
                    zoom = min(max(1, start * value.magnification), layout.maxZoom)
                }
                .onEnded { _ in zoomAtGestureStart = nil }
        )
        .onChange(of: layout.maxZoom) { _, maxZoom in
            if zoom > maxZoom { zoom = max(1, maxZoom) }
        }
        .onChange(of: map) { _, _ in
            if let inspectedCell { inspect(inspectedCell, layout: layout) } // keep the info line current
        }
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: selected)
        #endif
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Piece map")
        .accessibilityValue(accessibilitySummary)
    }

    // MARK: Selection

    private func validRange(_ range: ClosedRange<Int>) -> ClosedRange<Int>? {
        guard map.pieceCount > 0 else { return nil }
        let lower = max(0, range.lowerBound)
        let upper = min(map.pieceCount - 1, range.upperBound)
        return lower <= upper ? lower...upper : nil
    }

    /// Nearest cell to a point, clamped to the grid so dragging past an edge keeps selecting.
    private func clampedCell(_ point: CGPoint, layout: PieceGridLayout) -> Int {
        let size = layout.contentSize
        let clamped = CGPoint(x: min(max(point.x, 0), size.width - 0.5), y: min(max(point.y, 0), size.height - 0.5))
        return layout.cell(at: clamped) ?? max(0, layout.cellCount - 1)
    }

    private func select(from a: CGPoint, to b: CGPoint, layout: PieceGridLayout) {
        guard layout.cellCount > 0 else { return }
        let first = min(clampedCell(a, layout: layout), clampedCell(b, layout: layout))
        let last = max(clampedCell(a, layout: layout), clampedCell(b, layout: layout))
        let range = layout.pieces(inCell: first).lowerBound...(layout.pieces(inCell: last).upperBound - 1)
        if selection?.wrappedValue != range { selection?.wrappedValue = range }
    }

    private func selectionGesture(layout: PieceGridLayout) -> some Gesture {
        #if os(macOS)
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged { value in select(from: value.startLocation, to: value.location, layout: layout) }
        #else
        // A plain drag must keep scrolling the page, so selection starts with a touch and hold.
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)))
            .onChanged { value in
                if case .second(true, let drag?) = value {
                    select(from: drag.startLocation, to: drag.location, layout: layout)
                }
            }
        #endif
    }

    @ViewBuilder
    private func selectionHandles(for range: ClosedRange<Int>, layout: PieceGridLayout) -> some View {
        let cells = layout.cells(forPieces: range)
        let start = layout.rect(forCell: cells.lowerBound)
        let end = layout.rect(forCell: cells.upperBound)
        SelectionHandle()
            .position(x: start.minX, y: start.minY)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)).onChanged { value in
                guard let current = selection?.wrappedValue else { return }
                let piece = layout.pieces(inCell: clampedCell(value.location, layout: layout)).lowerBound
                selection?.wrappedValue = min(piece, current.upperBound)...max(piece, current.upperBound)
            })
        SelectionHandle()
            .position(x: end.maxX, y: end.maxY)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)).onChanged { value in
                guard let current = selection?.wrappedValue else { return }
                let piece = layout.pieces(inCell: clampedCell(value.location, layout: layout)).upperBound - 1
                selection?.wrappedValue = min(piece, current.lowerBound)...max(piece, current.lowerBound)
            })
    }

    private func inspect(_ cell: Int?, layout: PieceGridLayout) {
        inspectedCell = cell
        inspection = cell.map { describe(cell: $0, layout: layout) }
    }

    private func describe(cell index: Int, layout: PieceGridLayout) -> PieceMapInspection {
        let pieces = layout.pieces(inCell: index)
        let cell = map.cell(for: pieces)
        let number = { (i: Int) in i.formatted() }
        let title = pieces.count == 1
            ? String(localized: "Piece \(number(pieces.lowerBound))")
            : String(localized: "Pieces \(number(pieces.lowerBound))–\(number(pieces.upperBound - 1))")

        var parts: [String] = []
        if pieces.count == 1 {
            let fill = map.fill[pieces.lowerBound]
            switch fill {
            case PieceMap.have: parts.append(String(localized: "Downloaded"))
            case PieceMap.missing: parts.append(cell.isSkipped ? String(localized: "Skipped") : String(localized: "Missing"))
            default: parts.append(String(localized: "Downloading \(PieceMap.fraction(fill).formatted(.percent.precision(.fractionLength(0))))"))
            }
        } else {
            parts.append(String(localized: "\(cell.fraction.formatted(.percent.precision(.fractionLength(0)))) downloaded"))
            if cell.isActive { parts.append(String(localized: "downloading")) }
        }
        if map.tracksAvailability, cell.fraction < 1 {
            let peers = Int(cell.minAvailability)
            parts.append(pieces.count == 1
                ? String(localized: "\(peers) peers")
                : String(localized: "rarest has \(peers) peers"))
        }
        switch PiecePriority(level: Int(cell.maxPriority)) {
        case .lowest: parts.append(String(localized: "Lowest priority"))
        case .highest: parts.append(String(localized: "Highest priority"))
        case .normal, .skip: break
        }
        let files = map.files(overlapping: pieces.lowerBound...(pieces.upperBound - 1))
        if files.count == 1 {
            parts.append(files[0].name)
        } else if files.count > 1 {
            parts.append(String(localized: "\(files.count) files"))
        }
        return PieceMapInspection(pieces: pieces, title: title, detail: parts.joined(separator: " · "))
    }

    private var accessibilitySummary: String {
        let summary = map.summary
        guard map.pieceCount > 0 else { return String(localized: "No pieces yet") }
        let percent = (Double(summary.downloaded) / Double(map.pieceCount)).formatted(.percent.precision(.fractionLength(0)))
        return String(localized: "\(percent) of pieces downloaded, \(summary.downloading) downloading")
    }
}

/// Static cells. Equatable so hover and animation changes never redraw it.
struct PieceGridCanvas: View, Equatable {
    var map: PieceMap
    var layout: PieceGridLayout
    var mode: PieceMapMode

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.layout == b.layout && a.mode == b.mode && a.map == b.map
    }

    var body: some View {
        Canvas { context, _ in
            PieceMapRenderer.draw(map, layout: layout, mode: mode, palette: .init(tint: .accentColor), in: context)
        }
        .frame(width: layout.contentSize.width, height: layout.contentSize.height)
    }
}

/// Gently pulses the cells that are downloading right now.
private struct ActivePiecesOverlay: View {
    var cells: [Int]
    var layout: PieceGridLayout

    var body: some View {
        if !cells.isEmpty {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let pulse = 0.5 + 0.5 * sin(t * 2 * .pi / 1.4)
                Canvas { context, _ in
                    var path = Path()
                    let radius = PieceMapRenderer.cornerRadius(for: layout.cellSize)
                    for cell in cells {
                        let rect = layout.rect(forCell: cell)
                        path.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
                    }
                    context.fill(path, with: .color(Color.accentColor.opacity(0.12 + 0.28 * pulse)))
                }
            }
            .frame(width: layout.contentSize.width, height: layout.contentSize.height)
            .allowsHitTesting(false)
        }
    }
}

/// Outlines runs of cells, one band per row.
struct RangeHighlight: View {
    enum Style {
        /// Files selected in the list.
        case accent
        /// Pieces selected on the map.
        case selection
    }

    var ranges: [ClosedRange<Int>]
    var layout: PieceGridLayout
    var style: Style = .accent

    init(ranges: [ClosedRange<Int>], layout: PieceGridLayout, style: Style = .accent) {
        self.ranges = ranges
        self.layout = layout
        self.style = style
    }

    init(cells: ClosedRange<Int>, layout: PieceGridLayout) {
        self.init(ranges: [cells], layout: layout)
    }

    var body: some View {
        Canvas { context, _ in
            let step = layout.cellSize + layout.spacing
            var path = Path()
            for cells in ranges where layout.columns > 0 && cells.lowerBound < layout.cellCount {
                let lastCell = min(cells.upperBound, layout.cellCount - 1)
                let firstRow = cells.lowerBound / layout.columns
                let lastRow = lastCell / layout.columns
                for row in firstRow...max(firstRow, lastRow) {
                    let startColumn = row == firstRow ? cells.lowerBound % layout.columns : 0
                    let endColumn = row == lastRow ? lastCell % layout.columns : layout.columns - 1
                    let rect = CGRect(
                        x: CGFloat(startColumn) * step - 1,
                        y: CGFloat(row) * step - 1,
                        width: CGFloat(endColumn - startColumn) * step + layout.cellSize + 2,
                        height: layout.cellSize + 2
                    )
                    path.addRoundedRect(in: rect, cornerSize: CGSize(width: 2, height: 2))
                }
            }
            switch style {
            case .accent:
                context.fill(path, with: .color(Color.accentColor.opacity(0.12)))
                context.stroke(path, with: .color(.accentColor), lineWidth: 1.5)
            case .selection:
                context.fill(path, with: .color(Color.primary.opacity(0.1)))
                context.stroke(path, with: .color(.primary), style: StrokeStyle(lineWidth: 1.5, dash: [4, 2]))
            }
        }
        .frame(width: layout.contentSize.width, height: layout.contentSize.height)
        .allowsHitTesting(false)
    }
}

/// Draggable end of a piece selection.
private struct SelectionHandle: View {
    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .frame(width: 14, height: 14)
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .frame(width: 32, height: 32) // comfortable touch target
            .contentShape(Circle())
            #if os(macOS)
            .pointerStyle(.grabIdle)
            #endif
    }
}
