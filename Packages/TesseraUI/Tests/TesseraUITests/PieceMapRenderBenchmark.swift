import SwiftUI
import Testing
@testable import TesseraUI

/// Rough frame-cost check. Real frames are rasterized on the GPU; ImageRenderer rasterizes on
/// the CPU, so these numbers are an upper bound for the drawing work.
@MainActor
struct PieceMapRenderBenchmark {
    /// One 60 fps frame. Debug builds are unoptimized and share the CPU with builds and
    /// simulators, so they only guard against gross regressions; the real budget is for release.
    #if DEBUG
    let frameBudget = 50.0
    #else
    let frameBudget = 16.7
    #endif

    func milliseconds(_ runs: Int, _ body: () -> Void) -> Double {
        body() // warm up
        let clock = ContinuousClock()
        let elapsed = clock.measure { for _ in 0..<runs { body() } }
        return Double(elapsed.components.attoseconds) / 1e15 / Double(runs) + Double(elapsed.components.seconds) * 1000 / Double(runs)
    }

    func renderCost(pieces: Int, zoom: CGFloat) -> (build: Double, render: Double, cells: Int) {
        let map = PieceMapSimulator(pieceCount: pieces).map
        let layout = PieceGridLayout(pieceCount: pieces, width: 560, fitHeight: 160, zoom: zoom)
        let size = layout.contentSize
        let canvas = Canvas { context, _ in
            PieceMapRenderer.draw(map, layout: layout, mode: .progress, palette: .init(tint: .blue), in: context)
        }
        .frame(width: size.width, height: size.height)

        let build = milliseconds(20) {
            _ = PieceMapRenderer.activeCells(map, layout: layout)
            for i in 0..<layout.cellCount { _ = map.cell(for: layout.pieces(inCell: i)) }
        }
        let render = milliseconds(10) {
            let renderer = ImageRenderer(content: canvas)
            renderer.scale = 2
            _ = renderer.cgImage
        }
        return (build, render, layout.cellCount)
    }

    @Test(arguments: [25_000, 100_000])
    func fitsFrameBudgetAtDefaultZoom(pieces: Int) {
        let cost = renderCost(pieces: pieces, zoom: 1)
        print("[bench] \(pieces) pieces, zoom 1: \(cost.cells) cells, of which aggregation \(String(format: "%.2f", cost.build)) ms; full redraw \(String(format: "%.2f", cost.render)) ms")
        #expect(cost.render < frameBudget, "one full redraw (aggregation + paths + raster) must fit in a frame")
    }

    @Test func fullyZoomedTwentyFiveThousandPieces() {
        let pieces = 25_000
        let maxZoom = PieceGridLayout(pieceCount: pieces, width: 560, fitHeight: 160).maxZoom
        let cost = renderCost(pieces: pieces, zoom: maxZoom)
        print("[bench] \(pieces) pieces, max zoom: \(cost.cells) cells, of which aggregation \(String(format: "%.2f", cost.build)) ms; full redraw \(String(format: "%.2f", cost.render)) ms")
        // Only redrawn when data changes (about once per second) or on zoom; animation uses the overlay.
        #expect(cost.render < 100)
    }
}
