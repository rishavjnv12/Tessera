import SwiftUI

/// Settings › Remote: which phones may control this Mac.
struct RemoteSettings: View {
    @Bindable var store: TorrentStore
    @State private var devices: [PairedPeer] = []
    @State private var connected: [String] = []

    var body: some View {
        Form {
            Section {
                Toggle("Allow iPhone and iPad to control this Mac", isOn: $store.settings.allowRemoteControl)
            } footer: {
                Text("On your iPhone, open Tessera, tap the device button and choose Pair with a Mac. Both need to be on the same network. After you allow a device here, everything it sends is encrypted.")
                    .foregroundStyle(.secondary)
            }
            Section("Paired devices") {
                if devices.isEmpty {
                    Text("No devices yet").foregroundStyle(.secondary)
                }
                ForEach(devices) { device in
                    HStack {
                        Label(device.name, systemImage: "iphone")
                        Spacer()
                        Text(connected.contains(device.name)
                             ? String(localized: "Connected")
                             : String(localized: "Paired \\(device.pairedAt.formatted(date: .abbreviated, time: .omitted))"))
                            .foregroundStyle(.secondary)
                        Button("Remove") {
                            if let server = store.server { server.unpair(device.id) } else { store.pairedDevices.remove(id: device.id) }
                            refresh()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func refresh() {
        devices = store.pairedDevices.all()
        connected = store.server?.connectedDevices ?? []
    }
}
