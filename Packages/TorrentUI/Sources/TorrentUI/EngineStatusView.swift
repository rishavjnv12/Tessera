import SwiftUI

/// Phase 0 placeholder: shows that the engine is linked and working.
public struct EngineStatusView: View {
    public var info: EngineInfo

    public init(info: EngineInfo) {
        self.info = info
    }

    public var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.tint)
                Text("Torrent")
                    .font(.largeTitle.weight(.semibold))
                selfTestLabel
                    .font(.subheadline)
            }

            Form {
                LabeledContent("libtorrent", value: info.libtorrentVersion)
                LabeledContent("OpenSSL", value: info.opensslVersion)
                LabeledContent("Boost", value: info.boostVersion)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 420, maxHeight: 200)
            .scrollDisabled(true)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var selfTestLabel: some View {
        switch info.selfTest {
        case .running:
            Label("Checking engine…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        case .passed:
            Label("Engine ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}

#Preview {
    EngineStatusView(info: .preview)
}
