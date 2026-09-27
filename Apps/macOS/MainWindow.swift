import SwiftUI
import TorrentKit
import TorrentUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case filter(TorrentFilter)
    case demo
}

/// Mail-style window: filters in the sidebar, torrents in a table, details in the inspector.
struct MainWindow: View {
    @Bindable var store: TorrentStore
    @State private var sidebar: SidebarItem? = .filter(.all)
    @State private var selection: Set<String> = []
    @State private var search = ""
    @State private var showInspector = true
    @State private var importing = false
    @State private var addingMagnet = false
    @State private var removal: Removal?
    @State private var dropTargeted = false
    @State private var actions = TorrentActions()

    struct Removal: Identifiable {
        let id = UUID()
        var ids: Set<String>
        var deleteFiles: Bool
    }

    private var filter: TorrentFilter {
        if case .filter(let f) = sidebar { return f }
        return .all
    }

    private var selectedTorrents: [TorrentStatus] {
        store.torrents.filter { selection.contains($0.id) }
    }

    var body: some View {
        NavigationSplitView {
            sidebarList
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
        } detail: {
            content
                .inspector(isPresented: $showInspector) {
                    InspectorView(store: store, selection: selection)
                        .inspectorColumnWidth(min: 340, ideal: 420, max: 680)
                }
        }
        .navigationTitle(sidebar == .demo ? "Piece Map Demo" : filter.title)
        .navigationSubtitle(subtitle)
        .searchable(text: $search, placement: .toolbar, prompt: "Search Torrents")
        .toolbar { toolbar }
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $dropTargeted, perform: handleDrop)
        .overlay { if dropTargeted { dropHighlight } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.torrentFile], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { store.open(urls) }
        }
        .sheet(isPresented: $addingMagnet) {
            AddMagnetSheet { store.open(magnet: $0) }
        }
        .sheet(item: pendingAdd) { add in
            AddTorrentSheet(store: store, add: add)
        }
        .confirmationDialog(removalTitle, isPresented: removalBinding, presenting: removal) { removal in
            Button(removal.deleteFiles ? "Remove and Delete Files" : "Remove", role: removal.deleteFiles ? .destructive : nil) {
                store.remove(removal.ids, deleteFiles: removal.deleteFiles)
                selection.subtract(removal.ids)
            }
        } message: { removal in
            Text(removal.deleteFiles
                 ? "The downloaded files are moved out of the download folder and deleted. This can’t be undone."
                 : "Downloaded files stay in the download folder.")
        }
        .alert("Couldn’t Complete the Action", isPresented: errorBinding) {
            Button("OK") {}
        } message: {
            Text(store.lastError ?? "")
        }
        .onChange(of: store.selectionRequest) { _, id in
            guard let id else { return }
            if sidebar == .demo { sidebar = .filter(.all) }
            if let torrent = store.status(of: id), !filter.includes(torrent) { sidebar = .filter(.all) }
            selection = [id]
            store.selectionRequest = nil
        }
        .onChange(of: store.torrents.map(\.id)) { _, ids in
            selection.formIntersection(ids) // drop removed torrents
        }
        .focusedSceneValue(\.torrentActions, actions)
        .onChange(of: selectedTorrents.map(\.menuState), initial: true) { _, _ in
            actions.update(selected: selectedTorrents)
        }
        .onAppear {
            wireActions()
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "openDemo") { sidebar = .demo }
            if let id = store.addFromLaunchArguments() { selection = [id] }
            #endif
        }
    }

    // MARK: Sidebar

    private var sidebarList: some View {
        List(selection: $sidebar) {
            Section("Torrents") {
                ForEach(TorrentFilter.allCases) { f in
                    Label(f.title, systemImage: f.systemImage)
                        .badge(store.count(f))
                        .tag(SidebarItem.filter(f))
                }
            }
            // Developer section, hidden for now. The demo still opens with the -openDemo YES launch option.
            // #if DEBUG
            // Section("Developer") {
            //     Label("Piece Map Demo", systemImage: "square.grid.3x3.fill")
            //         .tag(SidebarItem.demo)
            // }
            // #endif
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Label(Format.rate(store.downloadRate), systemImage: "arrow.down")
                Label(Format.rate(store.uploadRate), systemImage: "arrow.up")
                Spacer()
            }
            .labelStyle(CompactLabelStyle())
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let startError = store.startError {
            ContentUnavailableView("The Engine Couldn’t Start", systemImage: "exclamationmark.triangle", description: Text(startError))
        } else if sidebar == .demo {
            PieceMapDemoView()
        } else if store.torrents.isEmpty {
            ContentUnavailableView {
                Label("No Torrents", systemImage: "arrow.down.circle")
            } description: {
                Text("Open a torrent file, add a magnet link, or drop either here.\nDownloads go to \(store.downloadFolder.path.replacingOccurrences(of: NSHomeDirectoryForUser(NSUserName()) ?? "~", with: "~")).")
            } actions: {
                Button("Open Torrent File…") { importing = true }
                    .buttonStyle(.borderedProminent)
                Button("Add Magnet Link…") { addingMagnet = true }
            }
        } else {
            TorrentTable(store: store, rows: rows, selection: $selection, onRemove: { ids, delete in
                removal = Removal(ids: ids, deleteFiles: delete)
            })
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "No \(filter.title) Torrents" : "No Results",
                                           systemImage: search.isEmpty ? filter.systemImage : "magnifyingglass")
                }
            }
        }
    }

    private var rows: [TorrentStatus] {
        store.torrents.filter { filter.includes($0) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
    }

    private var subtitle: String {
        guard sidebar != .demo else { return "" }
        let count = rows.count
        let text = count == 1 ? String(localized: "1 torrent") : String(localized: "\(count) torrents")
        return selection.isEmpty ? text : String(localized: "\(selection.count) of \(count) selected")
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Open Torrent File", systemImage: "doc.badge.plus") { importing = true }
                .help("Open a .torrent file (⌘O)")
            Button("Add Magnet Link", systemImage: "link.badge.plus") { addingMagnet = true }
                .help("Add a magnet link (⇧⌘O)")
        }
        ToolbarItemGroup {
            if actions.canResume && !actions.canPause {
                Button("Resume", systemImage: "play.fill") { actions.resume() }
                    .help("Resume the selected torrents")
            } else {
                Button("Pause", systemImage: "pause.fill") { actions.pause() }
                    .help("Pause the selected torrents")
                    .disabled(!actions.canPause)
            }
            Button("Remove", systemImage: "trash") { actions.remove(false) }
                .help("Remove the selected torrents")
                .disabled(selection.isEmpty)
        }
        ToolbarItem {
            Button("Inspector", systemImage: "sidebar.trailing") { showInspector.toggle() }
                .help("Show or hide the inspector (⌥⌘I)")
        }
    }

    // MARK: Actions

    /// Points the menu commands at this window. The closures read current state when run.
    private func wireActions() {
        actions.openFile = { importing = true }
        actions.addMagnet = { addingMagnet = true }
        actions.pause = { store.pause(selection) }
        actions.resume = { store.resume(selection) }
        actions.remove = { delete in if !selection.isEmpty { removal = Removal(ids: selection, deleteFiles: delete) } }
        actions.revealInFinder = { NSWorkspace.shared.activateFileViewerSelecting(selectedTorrents.map(\.contentURL)) }
        actions.copyMagnetLink = {
            guard selection.count == 1, let id = selection.first, let link = store.session?.details(of: id)?.magnetLink else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
        }
        actions.toggleSequential = {
            guard selection.count == 1, let t = selectedTorrents.first else { return }
            store.run { try $0.setSequential(!t.isSequential, torrent: t.id) }
        }
        actions.pauseAll = { store.pauseAll() }
        actions.resumeAll = { store.resumeAll() }
        actions.toggleInspector = { showInspector.toggle() }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        if url.isFileURL || url.scheme?.lowercased() == "magnet" { store.open([url]) }
                    }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                handled = true
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text, text.lowercased().hasPrefix("magnet:") else { return }
                    Task { @MainActor in store.open(magnet: text) }
                }
            }
        }
        return handled
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 3)
            .background(Color.accentColor.opacity(0.06), in: .rect(cornerRadius: 12, style: .continuous))
            .overlay { Label("Drop to Add", systemImage: "arrow.down.doc").font(.title3.weight(.medium)).foregroundStyle(.tint) }
            .padding(8)
            .allowsHitTesting(false)
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

    private var removalTitle: String {
        guard let removal else { return "" }
        if removal.ids.count == 1, let t = store.status(of: removal.ids.first!) {
            return String(localized: "Remove “\(t.name)”?")
        }
        return String(localized: "Remove \(removal.ids.count) torrents?")
    }
}
