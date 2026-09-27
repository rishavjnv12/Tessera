import SwiftUI
import TorrentKit

enum Route: Hashable {
    case torrent(String)
    case demo
}

struct IOSContentView: View {
    var store: TorrentStore
    @State private var path: [Route] = []
    @State private var importing = false
    @State private var addingMagnet = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(store.torrents) { torrent in
                    NavigationLink(value: Route.torrent(torrent.id)) {
                        TorrentRow(torrent: torrent)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            store.remove(torrent.id, deleteFiles: false)
                        }
                        if torrent.isPaused {
                            Button("Resume", systemImage: "play.fill") { store.resume(torrent.id) }.tint(.accentColor)
                        } else {
                            Button("Pause", systemImage: "pause.fill") { store.pause(torrent.id) }.tint(.orange)
                        }
                    }
                }
            }
            .overlay {
                if let startError = store.startError {
                    ContentUnavailableView("The Engine Couldn’t Start", systemImage: "exclamationmark.triangle", description: Text(startError))
                } else if store.torrents.isEmpty {
                    NoTorrentsView(engineVersion: store.engineVersion,
                                   onOpenFile: { importing = true }, onAddMagnet: { addingMagnet = true })
                }
            }
            .navigationTitle("Torrents")
            .toolbar {
                #if DEBUG
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(value: Route.demo) {
                        Label("Piece Map Demo", systemImage: "square.grid.3x3")
                    }
                }
                #endif
                ToolbarItem(placement: .primaryAction) {
                    Menu("Add", systemImage: "plus") {
                        Button("Open Torrent File…", systemImage: "doc") { importing = true }
                        Button("Add Magnet Link…", systemImage: "link") { addingMagnet = true }
                    }
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .torrent(let id): TorrentDetailView(store: store, torrentID: id)
                case .demo: PieceMapDemoView()
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.torrentFile], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                if let id = store.addTorrent(fileAt: url) { path = [.torrent(id)] }
            }
        }
        .sheet(isPresented: $addingMagnet) {
            AddMagnetSheet { link in
                if let id = store.addMagnet(link) { path = [.torrent(id)] }
            }
            .presentationDetents([.medium])
        }
        .alert("Couldn’t Complete the Action", isPresented: errorBinding) {
            Button("OK") {}
        } message: {
            Text(store.lastError ?? "")
        }
        .onAppear {
            #if DEBUG
            if let id = store.addFromLaunchArguments() { path = [.torrent(id)] }
            #endif
            if UserDefaults.standard.bool(forKey: "openDemo") { path = [.demo] }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })
    }
}
