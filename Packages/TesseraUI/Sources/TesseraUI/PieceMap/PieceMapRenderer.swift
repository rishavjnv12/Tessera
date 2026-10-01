import SwiftUI

public enum PieceMapMode: String, CaseIterable, Identifiable, Sendable {
    case progress
    case availability
    case priority

    public var id: Self { self }

    public var title: LocalizedStringKey {
        switch self {
        case .progress: "Progress"
        case .availability: "Availability"
        case .priority: "Priority"
        }
    }
}

/// Draws the static part of the map. Cells are batched into one path per color, so a frame
/// costs a handful of fills no matter how many pieces there are.
enum PieceMapRenderer {
    struct Palette {
        var tint: Color
        var empty = Color.primary.opacity(0.09)
        var skipped = Color.primary.opacity(0.035)
        var partial: Color { tint.opacity(0.55) }

        /// Opacity of the tint for cells that are 0-25%, 25-50%, 50-75% and 75-99% done.
        static let shades: [Double] = [0.22, 0.4, 0.58, 0.76]
        static let availability: [Color] = [.red, .orange, .yellow, .green]
        static let availabilityOpacity: [Double] = [0.9, 0.8, 0.6, 0.4]
        static let priority: (lowest: Color, normal: Color, highest: Color) =
            (.teal, Color.primary.opacity(0.14), .pink)
    }

    /// Availability bucket for the legend and colors: 0 peers, 1, 2-4, 5+.
    static func availabilityLevel(_ peers: UInt16) -> Int {
        switch peers {
        case 0: 0
        case 1: 1
        case 2...4: 2
        default: 3
        }
    }

    static func cornerRadius(for size: CGFloat) -> CGFloat {
        size >= 7 ? size * 0.22 : 0
    }

    static func draw(
        _ map: PieceMap, layout: PieceGridLayout, mode: PieceMapMode, palette: Palette, in context: GraphicsContext
    ) {
        guard layout.cellCount > 0, map.pieceCount == layout.pieceCount else { return }
        let radius = cornerRadius(for: layout.cellSize)

        var empty = Path()
        var skipped = Path()
        var full = Path()
        var partial = Path()
        var colored = Array(repeating: Path(), count: 5)

        func add(_ rect: CGRect, to path: inout Path) {
            if radius > 0 {
                path.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
            } else {
                path.addRect(rect)
            }
        }

        for index in 0..<layout.cellCount {
            let rect = layout.rect(forCell: index)
            let cell = map.cell(for: layout.pieces(inCell: index))
            switch mode {
            case .progress:
                if cell.isSkipped {
                    add(rect, to: &skipped)
                    continue
                }
                if cell.fraction >= 1 {
                    add(rect, to: &full)
                    continue
                }
                add(rect, to: &empty)
                guard cell.fraction > 0 else { continue }
                if layout.piecesPerCell > 1 {
                    // Several pieces: shade by how much of the cell is done.
                    add(rect, to: &colored[min(3, Int(cell.fraction * 4))])
                } else {
                    // One piece being downloaded: fill from the bottom by blocks received.
                    let height = max(1, (rect.height * cell.fraction).rounded(.toNearestOrAwayFromZero))
                    let level = CGRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height)
                    if radius > 0 {
                        let r = min(radius, height / 2)
                        partial.addRoundedRect(in: level, cornerSize: CGSize(width: r, height: r), style: .continuous)
                    } else {
                        partial.addRect(level)
                    }
                }
            case .availability:
                if cell.fraction >= 1 || !map.tracksAvailability {
                    add(rect, to: &empty)
                } else {
                    add(rect, to: &colored[availabilityLevel(cell.minAvailability)])
                }
            case .priority:
                if cell.isSkipped {
                    add(rect, to: &skipped)
                } else {
                    switch PiecePriority(level: Int(cell.maxPriority)) {
                    case .lowest: add(rect, to: &colored[0])
                    case .highest: add(rect, to: &colored[3])
                    default: add(rect, to: &colored[1])
                    }
                }
            }
        }

        context.fill(skipped, with: .color(palette.skipped))
        context.fill(empty, with: .color(palette.empty))
        switch mode {
        case .progress:
            for (level, opacity) in Palette.shades.enumerated() {
                context.fill(colored[level], with: .color(palette.tint.opacity(opacity)))
            }
            context.fill(partial, with: .color(palette.partial))
            context.fill(full, with: .color(palette.tint))
        case .availability:
            for (level, color) in Palette.availability.enumerated() {
                context.fill(colored[level], with: .color(color.opacity(Palette.availabilityOpacity[level])))
            }
        case .priority:
            let p = Palette.priority
            context.fill(colored[0], with: .color(p.lowest))
            context.fill(colored[1], with: .color(p.normal))
            context.fill(colored[3], with: .color(p.highest))
        }
    }

    /// Cells containing at least one piece being downloaded.
    static func activeCells(_ map: PieceMap, layout: PieceGridLayout) -> [Int] {
        guard map.pieceCount == layout.pieceCount else { return [] }
        var cells: [Int] = []
        var lastCell = -1
        for i in 0..<map.pieceCount where map.fill[i] != PieceMap.have && map.fill[i] != PieceMap.missing {
            let cell = i / layout.piecesPerCell
            if cell != lastCell {
                cells.append(cell)
                lastCell = cell
            }
        }
        return cells
    }
}
