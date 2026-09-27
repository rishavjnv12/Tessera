import CoreGraphics

/// Places pieces in a grid of square cells that fits a given width.
///
/// When there are more pieces than cells that fit in `fitHeight`, several consecutive pieces
/// share one cell. Zooming first lowers the pieces per cell, then grows the cells. Content
/// taller than `fitHeight` scrolls.
public struct PieceGridLayout: Equatable, Sendable {
    public static let minCellSize: CGFloat = 4
    public static let maxFitCellSize: CGFloat = 14
    public static let maxZoomedCellSize: CGFloat = 28

    public let pieceCount: Int
    public let piecesPerCell: Int
    public let cellCount: Int
    public let columns: Int
    public let rows: Int
    public let cellSize: CGFloat
    public let spacing: CGFloat
    /// Pieces per cell at zoom 1, used to bound the zoom range.
    public let basePiecesPerCell: Int

    public var contentSize: CGSize {
        guard rows > 0 else { return .zero }
        let width = CGFloat(columns) * (cellSize + spacing) - spacing
        let height = CGFloat(rows) * (cellSize + spacing) - spacing
        return CGSize(width: width, height: height)
    }

    /// Largest useful zoom: one piece per cell at the largest cell size.
    public var maxZoom: CGFloat {
        CGFloat(basePiecesPerCell) * Self.maxZoomedCellSize / baseCellSize
    }

    private let baseCellSize: CGFloat

    public init(pieceCount: Int, width: CGFloat, fitHeight: CGFloat, zoom: CGFloat = 1, spacing: CGFloat = 1) {
        self.pieceCount = max(0, pieceCount)
        self.spacing = spacing
        let width = max(width, Self.minCellSize)
        let fitHeight = max(fitHeight, Self.minCellSize)

        func columns(for size: CGFloat) -> Int { max(1, Int((width + spacing) / (size + spacing))) }
        func rowsThatFit(for size: CGFloat) -> Int { max(1, Int((fitHeight + spacing) / (size + spacing))) }

        // Largest cell size that fits every piece in its own cell, else the smallest cell.
        var size = Self.maxFitCellSize
        while size > Self.minCellSize, columns(for: size) * rowsThatFit(for: size) < self.pieceCount {
            size -= 0.5
        }
        size = max(size, Self.minCellSize)
        let capacity = columns(for: size) * rowsThatFit(for: size)
        let basePPC = max(1, Int((Double(self.pieceCount) / Double(capacity)).rounded(.up)))
        self.basePiecesPerCell = basePPC
        self.baseCellSize = size

        let zoom = max(1, zoom)
        let zoomedPPC = CGFloat(basePPC) / zoom
        if zoomedPPC >= 1 {
            self.piecesPerCell = max(1, Int(zoomedPPC.rounded(.up)))
            self.cellSize = size
        } else {
            self.piecesPerCell = 1
            self.cellSize = min(Self.maxZoomedCellSize, size / zoomedPPC)
        }
        self.cellCount = self.pieceCount == 0 ? 0 : (self.pieceCount + piecesPerCell - 1) / piecesPerCell
        self.columns = columns(for: cellSize)
        self.rows = cellCount == 0 ? 0 : (cellCount + self.columns - 1) / self.columns
    }

    public func rect(forCell cell: Int) -> CGRect {
        let row = cell / columns
        let column = cell % columns
        return CGRect(
            x: CGFloat(column) * (cellSize + spacing),
            y: CGFloat(row) * (cellSize + spacing),
            width: cellSize,
            height: cellSize
        )
    }

    /// Cell under a point in content coordinates, or nil when outside every cell.
    public func cell(at point: CGPoint) -> Int? {
        guard point.x >= 0, point.y >= 0 else { return nil }
        let column = Int(point.x / (cellSize + spacing))
        let row = Int(point.y / (cellSize + spacing))
        guard column < columns else { return nil }
        let cell = row * columns + column
        return cell < cellCount ? cell : nil
    }

    /// Pieces shown by a cell.
    public func pieces(inCell cell: Int) -> Range<Int> {
        let start = cell * piecesPerCell
        return start..<min(pieceCount, start + piecesPerCell)
    }

    /// Cells that show any of `pieces`.
    public func cells(forPieces pieces: ClosedRange<Int>) -> ClosedRange<Int> {
        let first = max(0, pieces.lowerBound) / piecesPerCell
        let last = min(pieceCount - 1, pieces.upperBound) / piecesPerCell
        return first...max(first, last)
    }
}
