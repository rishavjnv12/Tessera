import SwiftUI
import TesseraKit

/// The window that opens from the menu bar item: speeds, active torrents, pause and resume.
struct MenuBarContent: View {
    var store: TorrentStore
    @Environment(\.openWindow) private var openWindow

    private var active: [TorrentStatus] {
        store.torrents
            .filter { !$0.isPaused && ($0.state != .seeding || $0.uploadRate > 0) && $0.state != .finished }
            .sorted { $0.downloadRate + $0.uploadRate > $1.downloadRate + $1.uploadRate }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tessera").font(.headline)
                Spacer()
                Label(Format.rate(store.downloadRate), systemImage: "arrow.down")
                Label(Format.rate(store.uploadRate), systemImage: "arrow.up")
            }
            .labelStyle(CompactLabelStyle())
            .monospacedDigit()

            Divider()

            if active.isEmpty {
                Text(store.torrents.isEmpty ? "No torrents" : "Nothing is transferring")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(active.prefix(6)) { t in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(t.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(t.state == .seeding ? Format.rate(t.uploadRate) : Format.rate(t.downloadRate))
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        ProgressView(value: t.progress)
                            .controlSize(.small)
                            .tint(t.state == .seeding ? .green : .accentColor)
                    }
                    .monospacedDigit()
                }
                if active.count > 6 {
                    Text("and \(active.count - 6) more").font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                Button("Pause All") { store.pauseAll() }
                    .disabled(!store.torrents.contains { !$0.isPaused })
                Button("Resume All") { store.resumeAll() }
                    .disabled(!store.torrents.contains(where: \.isPaused))
                Spacer()
                Button("Open Tessera") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 320)
    }
}
