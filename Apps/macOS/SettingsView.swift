import SwiftUI
import TorrentKit

struct SettingsView: View {
    @Bindable var store: TorrentStore

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings(store: store) }
            Tab("Transfers", systemImage: "arrow.up.arrow.down") { TransferSettings(store: store) }
            Tab("Network", systemImage: "network") { NetworkSettings(store: store) }
            Tab("Remote", systemImage: "iphone.gen3.radiowaves.left.and.right") { RemoteSettings(store: store) }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @Bindable var store: TorrentStore

    var body: some View {
        Form {
            Section {
                LabeledContent("Download folder") {
                    VStack(alignment: .trailing, spacing: 6) {
                        Label(store.downloadFolder.path.abbreviatingHome, systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.downloadFolder]) }
                            Button("Choose…", action: chooseFolder)
                            if store.settings.downloadFolderPath != nil {
                                Button("Use ~/Torrent") { store.settings.downloadFolderPath = nil }
                            }
                        }
                        .controlSize(.small)
                    }
                }
                Toggle("Ask where to save and which files to download", isOn: $store.settings.askBeforeAdding)
            } footer: {
                Text("New torrents go here. Torrents you already added stay where they are.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Notify when a download finishes", isOn: $store.settings.notifyWhenFinished)
                Toggle("Show in menu bar", isOn: $store.settings.showInMenuBar)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = store.downloadFolder
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url {
            FolderAccess.remember(url)
            let resolved = url.resolvingSymlinksInPath()
            store.settings.downloadFolderPath = resolved.path == DownloadFolders.defaultFolder.path ? nil : resolved.path
        }
    }
}

private struct TransferSettings: View {
    @Bindable var store: TorrentStore

    var body: some View {
        Form {
            Section("Speed limits") {
                LimitField(title: "Download", value: $store.settings.downloadLimitKB)
                LimitField(title: "Upload", value: $store.settings.uploadLimitKB)
            }
            Section {
                Stepper("Active downloads: \(store.settings.activeDownloads)", value: $store.settings.activeDownloads, in: 1...20)
                Stepper("Active seeds: \(store.settings.activeSeeds)", value: $store.settings.activeSeeds, in: 1...50)
            } header: {
                Text("Queue")
            } footer: {
                Text("Torrents beyond these numbers wait their turn.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct LimitField: View {
    var title: LocalizedStringKey
    @Binding var value: Int

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Toggle("Limit", isOn: Binding(get: { value > 0 }, set: { value = $0 ? max(value, 1000) : 0 }))
                    .labelsHidden()
                TextField("", value: $value, format: .number)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                    .disabled(value == 0)
                Text("KB/s").foregroundStyle(.secondary)
            }
        }
    }
}

private struct NetworkSettings: View {
    @Bindable var store: TorrentStore
    @State private var portText = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Incoming port") {
                    HStack(spacing: 6) {
                        Toggle("Random", isOn: Binding(
                            get: { store.settings.listenPort == 0 },
                            set: { store.settings.listenPort = $0 ? 0 : (store.session?.listenPort ?? 51413) }
                        ))
                        .toggleStyle(.checkbox)
                        TextField("", value: $store.settings.listenPort, format: .number.grouping(.never))
                            .frame(width: 70)
                            .disabled(store.settings.listenPort == 0)
                    }
                }
                Toggle("Forward the port on my router (UPnP, NAT-PMP)", isOn: $store.settings.enablePortForwarding)
            } footer: {
                Text("Now listening on port \(store.session.map { String($0.listenPort) } ?? "–").")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Section {
                Toggle("Distributed hash table (DHT)", isOn: $store.settings.enableDHT)
                Toggle("Peer exchange (PEX)", isOn: $store.settings.enablePeerExchange)
                Toggle("Local peer discovery", isOn: $store.settings.enableLocalDiscovery)
            } header: {
                Text("Finding peers")
            } footer: {
                Text("These find peers without a tracker. Private torrents never use them.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
