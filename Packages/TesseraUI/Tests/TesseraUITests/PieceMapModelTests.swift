import CoreGraphics
import Testing
@testable import TesseraUI

struct PieceMapModelTests {
    func map(fill: [UInt8], priority: [UInt8]? = nil, availability: [UInt16]? = nil) -> PieceMap {
        PieceMap(
            pieceLength: 16_384, totalSize: Int64(fill.count) * 16_384, fill: fill,
            priority: priority ?? Array(repeating: 4, count: fill.count),
            availability: availability ?? Array(repeating: 1, count: fill.count),
            tracksAvailability: true
        )
    }

    @Test func deltaContainsOnlyChangedPieces() throws {
        let old = map(fill: [0, 0, 255, 100, 0])
        var newer = old
        newer.fill[1] = 40
        newer.fill[3] = 255
        newer.priority[4] = 7

        let delta = try #require(old.delta(to: newer))
        #expect(delta.indices == [1, 3, 4])
        var applied = old
        applied.apply(delta)
        #expect(applied == newer)
        #expect(old.delta(to: old)?.isEmpty == true)
    }

    @Test func deltaIsNilWhenPieceCountChanges() {
        #expect(PieceMap.empty.delta(to: map(fill: [0, 255])) == nil)
    }

    @Test func cellAggregatesPieces() {
        let m = map(fill: [255, 255, 0, 128], priority: [4, 7, 4, 4], availability: [3, 0, 2, 5])
        let cell = m.cell(for: 0..<4)
        #expect(abs(cell.fraction - (2 + PieceMap.fraction(128)) / 4) < 0.0001)
        #expect(cell.isActive)
        #expect(cell.maxPriority == 7)
        #expect(!cell.isSkipped)
        #expect(cell.minAvailability == 0)
        #expect(map(fill: [0, 0], priority: [0, 0]).cell(for: 0..<2).isSkipped)
    }

    @Test func partialFillNeverLooksEmptyOrComplete() {
        #expect(PieceMap.fraction(1) > 0)
        #expect(PieceMap.fraction(254) < 1)
        #expect(PieceMap.fraction(PieceMap.missing) == 0)
        #expect(PieceMap.fraction(PieceMap.have) == 1)
    }

    @Test func summaryCountsStates() {
        let s = map(fill: [255, 10, 0, 255], priority: [4, 4, 0, 4]).summary
        #expect(s == .init(downloaded: 2, downloading: 1, skipped: 1))
    }
}

struct PieceGridLayoutTests {
    @Test func fewPiecesGetLargeCells() {
        let layout = PieceGridLayout(pieceCount: 50, width: 400, fitHeight: 160)
        #expect(layout.piecesPerCell == 1)
        #expect(layout.cellSize == PieceGridLayout.maxFitCellSize)
        #expect(layout.cellCount == 50)
        #expect(layout.contentSize.height <= 160)
    }

    @Test func manyPiecesAreBucketedToFitHeight() {
        let layout = PieceGridLayout(pieceCount: 100_000, width: 500, fitHeight: 160)
        #expect(layout.cellSize == PieceGridLayout.minCellSize)
        #expect(layout.piecesPerCell > 1)
        #expect(layout.cellCount * layout.piecesPerCell >= 100_000)
        #expect(layout.contentSize.height <= 160)
        #expect(layout.contentSize.width <= 500)
    }

    @Test func zoomReducesPiecesPerCellThenGrowsCells() {
        let base = PieceGridLayout(pieceCount: 100_000, width: 500, fitHeight: 160)
        let zoomed = PieceGridLayout(pieceCount: 100_000, width: 500, fitHeight: 160, zoom: 2)
        #expect(zoomed.piecesPerCell < base.piecesPerCell)
        let max = PieceGridLayout(pieceCount: 100_000, width: 500, fitHeight: 160, zoom: base.maxZoom)
        #expect(max.piecesPerCell == 1)
        #expect(abs(max.cellSize - PieceGridLayout.maxZoomedCellSize) < 0.01)
        #expect(max.contentSize.height > 160) // scrolls
    }

    @Test func hitTestingAndRangesRoundTrip() {
        let layout = PieceGridLayout(pieceCount: 1_000, width: 300, fitHeight: 100)
        for cell in [0, 1, layout.columns, layout.cellCount - 1] {
            let rect = layout.rect(forCell: cell)
            #expect(layout.cell(at: CGPoint(x: rect.midX, y: rect.midY)) == cell)
            let pieces = layout.pieces(inCell: cell)
            #expect(layout.cells(forPieces: pieces.lowerBound...(pieces.upperBound - 1)) == cell...cell)
        }
        #expect(layout.cell(at: CGPoint(x: -1, y: 5)) == nil)
        #expect(layout.cell(at: CGPoint(x: 5, y: layout.contentSize.height + 50)) == nil)
    }

    @Test func emptyTorrentHasNoCells() {
        let layout = PieceGridLayout(pieceCount: 0, width: 300, fitHeight: 100)
        #expect(layout.cellCount == 0)
        #expect(layout.contentSize == .zero)
    }
}
