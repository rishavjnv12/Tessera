import Network
import SwiftUI
import UIKit

/// Finds Macs running Tessera nearby and pairs with one: both screens show the same code, and
/// the user allows it on the Mac.
struct PairMacSheet: View {
    var store: TorrentStore
    var browser: RemoteBrowser
    var onPaired: (PairedPeer, NWEndpoint) -> Void

    private enum Phase {
        case choosing
        case pairing(mac: String, code: String?)
        case failed(String)
    }

    @State private var phase: Phase = .choosing
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Pair with a Mac")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
        }
        .onAppear { browser.start() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .choosing:
            List {
                Section {
                    if browser.macs.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking for Macs running Tessera…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(browser.macs) { mac in
                        Button {
                            pair(with: mac)
                        } label: {
                            Label(mac.name, systemImage: "laptopcomputer")
                        }
                    }
                } footer: {
                    Text("On the Mac, open Tessera and keep Settings › Remote › “Allow iPhone and iPad to control this Mac” on. Both devices need to be on the same network.")
                }
            }
        case .pairing(let mac, let code):
            VStack(spacing: 20) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.tint)
                Text("Pairing with \(mac)").font(.headline)
                if let code {
                    Text(code)
                        .font(.system(size: 48, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .textSelection(.enabled)
                    Text("Check that your Mac shows the same code, then click Allow on the Mac.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn’t Pair", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { phase = .choosing }
            }
        }
    }

    private func pair(with mac: RemoteBrowser.Mac) {
        phase = .pairing(mac: mac.name, code: nil)
        let store = store.pairedMacs
        Task {
            do {
                let peer = try await RemotePairing.pair(with: mac.endpoint, deviceName: UIDevice.current.name, store: store) { code in
                    Task { @MainActor in phase = .pairing(mac: mac.name, code: code) }
                }
                onPaired(peer, mac.endpoint)
                dismiss()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
