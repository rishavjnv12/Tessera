import SwiftUI
import TorrentKit

struct IOSSettingsView: View {
    @Bindable var store: TorrentStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Keep screen awake while downloading", isOn: $store.settings.keepScreenAwake)
                    Toggle("Ask before adding", isOn: $store.settings.askBeforeAdding)
                } footer: {
                    Text("iOS pauses downloads soon after Torrent leaves the screen. Keeping the screen awake lets long downloads finish.")
                }
                Section("Speed limits") {
                    limitRow("Download", value: $store.settings.downloadLimitKB)
                    limitRow("Upload", value: $store.settings.uploadLimitKB)
                }
                Section("Queue") {
                    Stepper("Active downloads: \(store.settings.activeDownloads)", value: $store.settings.activeDownloads, in: 1...10)
                    Stepper("Active seeds: \(store.settings.activeSeeds)", value: $store.settings.activeSeeds, in: 1...20)
                }
                Section {
                    Toggle("Distributed hash table (DHT)", isOn: $store.settings.enableDHT)
                    Toggle("Peer exchange (PEX)", isOn: $store.settings.enablePeerExchange)
                    Toggle("Forward port on router (UPnP)", isOn: $store.settings.enablePortForwarding)
                } header: {
                    Text("Finding peers")
                } footer: {
                    Text("Listening on port \(store.session.map { String($0.listenPort) } ?? "–").")
                }
                Section {
                    Button("Show Downloads in Files", systemImage: "folder") {
                        FilesApp.open(store.downloadFolder.appending(path: "x"))
                    }
                    LabeledContent("Engine", value: "libtorrent \(store.engineVersion)")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func limitRow(_ title: LocalizedStringKey, value: Binding<Int>) -> some View {
        HStack {
            Toggle(title, isOn: Binding(get: { value.wrappedValue > 0 }, set: { value.wrappedValue = $0 ? max(value.wrappedValue, 1000) : 0 }))
            if value.wrappedValue > 0 {
                TextField("KB/s", value: value, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                Text("KB/s").foregroundStyle(.secondary)
            }
        }
    }
}
