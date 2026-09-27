import SwiftUI
import Testing
@testable import TorrentUI

/// Writes PNGs of the piece map for visual review when PIECEMAP_SNAPSHOT_DIR is set.
@MainActor
struct PieceMapSnapshots {
    @Test func writeSnapshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["PIECEMAP_SNAPSHOT_DIR"] else { return }
        let simulator = PieceMapSimulator(pieceCount: 25_000)
        for _ in 0..<6 { simulator.step() }
        let map = simulator.map
        for scheme in [ColorScheme.light, .dark] {
            for mode in PieceMapMode.allCases {
                // ScrollView does not render offscreen, so draw the layers the view stacks.
                let layout = PieceGridLayout(pieceCount: map.pieceCount, width: 532, fitHeight: 160)
                let view = VStack(alignment: .leading) {
                    ZStack(alignment: .topLeading) {
                        PieceGridCanvas(map: map, layout: layout, mode: mode)
                        RangeHighlight(cells: layout.cells(forPieces: map.files[3].pieces!), layout: layout)
                        RangeHighlight(ranges: [layout.cells(forPieces: 9_000...10_500)], layout: layout, style: .selection)
                    }
                    PieceMapLegend(mode: mode, tracksAvailability: true).font(.caption)
                }
                .padding(14)
                .frame(width: 560)
                .background(scheme == .dark ? Color.black : Color.white)
                .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let cgImage = try #require(renderer.cgImage)
                let data = try #require(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
                try data.write(to: URL(filePath: dir).appending(path: "piecemap-\(mode.rawValue)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }
}
