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
    @State private var browser = RemoteBrowser()
    @State private var pairedMacs: [PairedPeer] = []
    @State private var pairing = false

    private var rows: [TorrentStatus] {
        store.torrents.filter { filter.includes($0) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
    }

    var body: some View {
        NavigationSplitView {
            list
                .navigationTitle(title)
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
        .sheet(isPresented: $pairing) {
            PairMacSheet(store: store, browser: browser) { peer, endpoint in
                pairedMacs = store.pairedMacs.all()
                selection = nil
                store.connect(to: peer, at: endpoint)
            }
        }
        .onChange(of: browser.macs) { _, _ in reconnectToLastMac() }
        #if DEBUG
        .onChange(of: store.remoteState) { _, state in
            // Debug launch option -addToMac <path>: once connected, add that .torrent file to the Mac.
            if state == .connected, let path = UserDefaults.standard.string(forKey: "addToMac") {
                UserDefaults.standard.removeObject(forKey: "addToMac")
                store.addTorrent(fileAt: URL(filePath: path))
            }
        }
        .onChange(of: store.torrents.map(\.id)) { _, ids in
            // Debug launch option -openFirstTorrent YES.
            if UserDefaults.standard.bool(forKey: "openFirstTorrent"), selection == nil, let first = ids.first { selection = first }
        }
        #endif
        .onChange(of: store.remoteState) { _, state in
            // The Mac forgot this device: drop the stale pairing so it can be paired again.
            if state == .needsPairing, let peer = store.remote?.peer {
                store.pairedMacs.remove(id: peer.id)
                pairedMacs = store.pairedMacs.all()
            }
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
            pairedMacs = store.pairedMacs.all()
            browser.start()
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
        } else if store.isRemote, store.remoteState != .connected, store.torrents.isEmpty {
            remoteStatusView
        } else if store.torrents.isEmpty {
            NoTorrentsView(engineVersion: store.engineVersion,
                           onOpenFile: { importing = true }, onAddMagnet: { addingMagnet = true })
        } else {
            List(selection: $selection) {
                if store.isRemote, store.remoteState != .connected {
                    Section { remoteStatusLine }
                }
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
                            if !store.isRemote {
                                Button("Show in Files", systemImage: "folder") { FilesApp.open(torrent.contentURL) }
                            }
                            Divider()
                            Button("Remove…", systemImage: "trash", role: .destructive) { removal = torrent }
                        }
                    }
                } footer: {
                    if !store.isRemote, store.count(.downloading) > 0 {
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

    private var title: String {
        if let remote = store.remote { return remote.displayName }
        return filter == .all ? String(localized: "Torrents") : filter.title
    }

    // MARK: Remote Mac

    private func reconnectToLastMac() {
        #if DEBUG
        // Debug launch option -autoPairMac YES: pair with the first Mac found (it must auto-approve).
        if UserDefaults.standard.bool(forKey: "autoPairMac"), !store.isRemote, pairedMacs.isEmpty, let mac = browser.macs.first {
            let macStore = store.pairedMacs
            Task {
                if let peer = try? await RemotePairing.pair(with: mac.endpoint, deviceName: "Simulator", store: macStore, showCode: { _ in }) {
                    pairedMacs = macStore.all()
                    store.connect(to: peer, at: mac.endpoint)
                }
            }
            return
        }
        #endif
        guard !store.isRemote, let id = store.lastRemoteMacID,
              let mac = browser.macs.first(where: { $0.id == id }),
              let peer = pairedMacs.first(where: { $0.id == id }) else { return }
        store.connect(to: peer, at: mac.endpoint)
    }

    private var deviceMenu: some View {
        Menu {
            Section("Show downloads on") {
                Button {
                    selection = nil
                    store.useThisDevice()
                } label: {
                    Label("This iPhone", systemImage: store.isRemote ? "iphone" : "checkmark")
                }
                ForEach(pairedMacs) { peer in
                    let nearby = browser.macs.first { $0.id == peer.id }
                    Button {
                        guard let nearby else { return }
                        selection = nil
                        store.connect(to: peer, at: nearby.endpoint)
                    } label: {
                        Label(nearby == nil ? String(localized: "\(peer.name) (not nearby)") : peer.name,
                              systemImage: store.remote?.peer.id == peer.id ? "checkmark" : "laptopcomputer")
                    }
                    .disabled(nearby == nil)
                }
            }
            Button("Pair with a Mac…", systemImage: "plus") { pairing = true }
            if !pairedMacs.isEmpty {
                Menu("Forget a Mac", systemImage: "minus.circle") {
                    ForEach(pairedMacs) { peer in
                        Button(peer.name, role: .destructive) {
                            if store.remote?.peer.id == peer.id { store.useThisDevice() }
                            store.pairedMacs.remove(id: peer.id)
                            pairedMacs = store.pairedMacs.all()
                        }
                    }
                }
            }
        } label: {
            Label("Device", systemImage: store.isRemote ? "laptopcomputer" : "iphone")
        }
    }

    private var remoteStatusText: String {
        let name = store.remote?.displayName ?? ""
        switch store.remoteState {
        case .connecting, nil: return String(localized: "Connecting to \(name)…")
        case .connected: return ""
        case .needsPairing: return String(localized: "\(name) no longer knows this iPhone. Pair again to control it.")
        case .unreachable: return String(localized: "\(name) isn’t reachable. Trying again…")
        }
    }

    private var remoteStatusLine: some View {
        HStack(spacing: 10) {
            if store.remoteState == .needsPairing {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            } else {
                ProgressView()
            }
            Text(remoteStatusText).font(.callout).foregroundStyle(.secondary)
            Spacer()
            if store.remoteState == .needsPairing {
                Button("Pair") { pairing = true }
            }
        }
    }

    private var remoteStatusView: some View {
        ContentUnavailableView {
            Label(store.remote?.displayName ?? "", systemImage: "laptopcomputer")
        } description: {
            Text(remoteStatusText)
        } actions: {
            if store.remoteState == .needsPairing {
                Button("Pair Again") { pairing = true }.buttonStyle(.borderedProminent)
            }
            Button("Use This iPhone") { store.useThisDevice() }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            deviceMenu
        }
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
