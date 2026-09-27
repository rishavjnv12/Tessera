import SwiftUI
import TorrentKit
import TorrentUI

/// iPhone: a list that pushes the detail screen. iPad: list and detail side by side.
struct IOSContentView: View {
    @Bindable var store: TorrentStore
    @State private var selection: String?
    @State private var filter: TorrentFilter = .all
    @State private var search = ""
    @State private var importing = false
    @State private var addingMagnet = false
    @State private var showingSettings = false
    @State private var showingDemo = false
    @State private var removal: TorrentStatus?

    private var rows: [TorrentStatus] {
        store.torrents.filter { filter.includes($0) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
    }

    var body: some View {
        NavigationSplitView {
            list
                .navigationTitle(filter == .all ? String(localized: "Torrents") : filter.title)
                .searchable(text: $search, prompt: "Search Torrents")
                .toolbar { toolbar }
                .navigationSplitViewColumnWidth(min: 320, ideal: 380)
        } detail: {
            if let selection, store.status(of: selection) != nil {
                NavigationStack {
                    TorrentDetailView(store: store, torrentID: selection)
                }
                .id(selection)
            } else {
                ContentUnavailableView("No Torrent Selected", systemImage: "arrow.down.circle",
                                       description: Text("Choose a torrent to see its pieces and files."))
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.torrentFile], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { store.open(urls) }
        }
        .sheet(isPresented: $addingMagnet) {
            AddMagnetSheet { store.open(magnet: $0) }
                .presentationDetents([.medium])
        }
        .sheet(item: pendingAdd) { add in
            IOSAddSheet(store: store, add: add)
        }
        .sheet(isPresented: $showingSettings) {
            IOSSettingsView(store: store)
        }
        .sheet(isPresented: $showingDemo) {
            NavigationStack { PieceMapDemoView() }
        }
        .confirmationDialog("Remove “\(removal?.name ?? "")”?", isPresented: removalBinding, titleVisibility: .visible, presenting: removal) { t in
            Button("Remove from List") { store.remove(t.id, deleteFiles: false) }
            Button("Remove and Delete Files", role: .destructive) { store.remove(t.id, deleteFiles: true) }
        } message: { _ in
            Text("Removing keeps downloaded files unless you choose to delete them.")
        }
        .alert("Couldn’t Complete the Action", isPresented: errorBinding) {
            Button("OK") {}
        } message: {
            Text(store.lastError ?? "")
        }
        .onChange(of: store.selectionRequest) { _, id in
            guard let id else { return }
            filter = .all
            selection = id
            store.selectionRequest = nil
        }
        .onAppear {
            #if DEBUG
            if let id = store.addFromLaunchArguments() { selection = id }
            if UserDefaults.standard.bool(forKey: "openDemo") { showingDemo = true }
            #endif
        }
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        if let startError = store.startError {
            ContentUnavailableView("The Engine Couldn’t Start", systemImage: "exclamationmark.triangle", description: Text(startError))
        } else if store.torrents.isEmpty {
            NoTorrentsView(engineVersion: store.engineVersion,
                           onOpenFile: { importing = true }, onAddMagnet: { addingMagnet = true })
        } else {
            List(selection: $selection) {
                Section {
                    ForEach(rows) { torrent in
                        NavigationLink(value: torrent.id) {
                            TorrentRow(torrent: torrent)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Remove", systemImage: "trash") { removal = torrent }
                                .tint(.red)
                            if torrent.isPaused {
                                Button("Resume", systemImage: "play.fill") { store.resume(torrent.id) }.tint(.accentColor)
                            } else {
                                Button("Pause", systemImage: "pause.fill") { store.pause(torrent.id) }.tint(.orange)
                            }
                        }
                        .contextMenu {
                            if torrent.isPaused {
                                Button("Resume", systemImage: "play.fill") { store.resume(torrent.id) }
                            } else {
                                Button("Pause", systemImage: "pause.fill") { store.pause(torrent.id) }
                            }
                            Button("Show in Files", systemImage: "folder") { FilesApp.open(torrent.contentURL) }
                            Divider()
                            Button("Remove…", systemImage: "trash", role: .destructive) { removal = torrent }
                        }
                    }
                } footer: {
                    if store.count(.downloading) > 0 {
                        Label("iOS pauses downloads when Torrent isn’t on screen. They continue when you come back.",
                              systemImage: "info.circle")
                            .font(.footnote)
                    }
                }
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "No \(filter.title) Torrents" : "No Results",
                                           systemImage: search.isEmpty ? filter.systemImage : "magnifyingglass")
                }
            }
            .refreshable { store.resumeAll() } // pull down to wake everything up
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu("Filter", systemImage: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill") {
                Picker("Show", selection: $filter) {
                    ForEach(TorrentFilter.allCases) { f in
                        Label("\(f.title) (\(store.count(f)))", systemImage: f.systemImage).tag(f)
                    }
                }
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu("Add", systemImage: "plus") {
                Button("Open Torrent File…", systemImage: "doc") { importing = true }
                Button("Add Magnet Link…", systemImage: "link") { addingMagnet = true }
            }
            Button("Settings", systemImage: "gearshape") { showingSettings = true }
        }
    }

    // MARK: Bindings

    private var pendingAdd: Binding<PendingAdd?> {
        Binding(get: { store.pendingAdds.first }, set: { value in
            if value == nil, let first = store.pendingAdds.first { store.dismiss(first) }
        })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })
    }

    private var removalBinding: Binding<Bool> {
        Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })
    }
}
