import SwiftUI
import TorrentUI

/// A simulated 25,000-piece download, for checking the piece map without a network.
struct PieceMapDemoView: View {
    @State private var simulator = PieceMapSimulator(pieceCount: 25_000)
    @State private var selectedFiles: Set<Int> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Piece Map Demo").font(.title2.weight(.semibold))
                    Text("25,000 simulated pieces. Nothing is downloaded.")
                        .foregroundStyle(.secondary)
                }
                PieceMapCard(
                    map: simulator.map,
                    highlightedRanges: simulator.map.files.filter { selectedFiles.contains($0.id) }.compactMap(\.pieces)
                ) { range, priority in
                    simulator.setPriority(priority, pieces: range)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Files").font(.headline)
                        Spacer()
                        if !selectedFiles.isEmpty {
                            PriorityMenu(current: PiecePriority.common(simulator.map.files.filter { selectedFiles.contains($0.id) }.map(priority(of:)))) {
                                simulator.setPriority($0, files: selectedFiles)
                            }
                            .fixedSize()
                            Button("Clear") { selectedFiles = [] }.buttonStyle(.borderless)
                        }
                    }
                    ForEach(simulator.map.files) { file in
                        FileListRow(
                            name: file.name, path: file.path, size: file.size, progress: progress(of: file),
                            pieces: file.pieces, priority: priority(of: file), isSelected: selectedFiles.contains(file.id),
                            onSetPriority: { simulator.setPriority($0, files: selectedFiles.contains(file.id) ? selectedFiles : [file.id]) }
                        ) {
                            if selectedFiles.contains(file.id) { selectedFiles.remove(file.id) } else { selectedFiles.insert(file.id) }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Piece Map Demo")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await simulator.run() }
    }

    /// A file's priority is its pieces' priority when they all agree, else Normal.
    private func priority(of file: PieceMap.File) -> PiecePriority {
        guard let pieces = file.pieces else { return .normal }
        let levels = Set(simulator.map.priority[pieces].map { PiecePriority(level: Int($0)) })
        return levels.count == 1 ? levels.first! : .normal
    }

    private func progress(of file: PieceMap.File) -> Double {
        guard let pieces = file.pieces else { return 1 }
        return simulator.map.cell(for: pieces.lowerBound..<(pieces.upperBound + 1)).fraction
    }
}
