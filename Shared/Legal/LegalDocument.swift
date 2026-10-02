import SwiftUI
import WebKit

/// The legal documents bundled with the app as local HTML (Shared/Legal/*.html).
enum LegalDocument: String, CaseIterable, Identifiable, Codable, Hashable {
    case privacy, terms, acknowledgements

    var id: Self { self }

    var title: String {
        switch self {
        case .privacy: String(localized: "Privacy Policy")
        case .terms: String(localized: "Terms of Use")
        case .acknowledgements: String(localized: "Acknowledgements")
        }
    }

    var systemImage: String {
        switch self {
        case .privacy: "hand.raised"
        case .terms: "doc.text"
        case .acknowledgements: "heart.text.square"
        }
    }

    /// The bundled file. The documents link to each other by these names.
    var url: URL? {
        Bundle.main.url(forResource: rawValue, withExtension: "html")
    }
}

/// Shows a bundled legal document. Links to the other documents open in place;
/// web links open in the browser.
struct LegalDocumentView: View {
    var document: LegalDocument

    var body: some View {
        Group {
            if let url = document.url {
                LegalWebView(url: url)
            } else {
                ContentUnavailableView("Document Missing", systemImage: "doc.questionmark",
                                       description: Text("\(document.title) isn't included in this build."))
            }
        }
        .navigationTitle(document.title)
    }
}

#if os(macOS)
private typealias PlatformViewRepresentable = NSViewRepresentable
#else
private typealias PlatformViewRepresentable = UIViewRepresentable
#endif

private struct LegalWebView: PlatformViewRepresentable {
    var url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { makeWebView(context) }
    func updateNSView(_ view: WKWebView, context: Context) { load(view) }
    #else
    func makeUIView(context: Context) -> WKWebView { makeWebView(context) }
    func updateUIView(_ view: WKWebView, context: Context) { load(view) }
    #endif

    private func makeWebView(_ context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Lets the stylesheet hide the page heading, which the window or navigation bar already shows.
        configuration.userContentController.addUserScript(WKUserScript(
            source: "document.documentElement.classList.add('in-app')",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        #if os(macOS)
        view.setValue(false, forKey: "drawsBackground") // no white flash in dark mode before the page loads
        #else
        view.isOpaque = false
        view.backgroundColor = .clear
        #endif
        return view
    }

    private func load(_ view: WKWebView) {
        guard view.url?.lastPathComponent != url.lastPathComponent || view.url == nil else { return }
        // Read access to the folder so the shared stylesheet and the other documents load too.
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let target = action.request.url else { return .cancel }
            if target.isFileURL { return .allow }
            if action.navigationType == .linkActivated {
                #if os(macOS)
                NSWorkspace.shared.open(target)
                #else
                await UIApplication.shared.open(target)
                #endif
            }
            return .cancel
        }
    }
}
