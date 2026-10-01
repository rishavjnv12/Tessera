import SwiftUI
import TesseraKit

struct TorrentRow: View {
    var torrent: TorrentStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(torrent.name)
                .lineLimit(1)
                .truncationMode(.middle)
            ProgressView(value: torrent.progress)
                .progressViewStyle(.linear)
                .tint(torrent.isPaused || torrent.isQueued ? .secondary : .accentColor)
                .controlSize(.small)
            HStack(spacing: 6) {
                Text(Format.state(torrent))
                Text(Format.percent(torrent.progress))
                if torrent.downloadRate > 0 {
                    Label(Format.rate(torrent.downloadRate), systemImage: "arrow.down")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(CompactLabelStyle())
            .monospacedDigit()
            .lineLimit(1)
        }
        .padding(.vertical, 3)
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}
