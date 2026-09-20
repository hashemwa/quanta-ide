import SwiftUI
import WebKit

struct RichOutputView: NSViewRepresentable {
    let bundle: [String: Any]

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        return configuration
    }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: Self.configuration())
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let document = RichOutput.safeDocument(RichOutput.staticHTML(bundle))
        guard context.coordinator.document != document else { return }
        context.coordinator.document = document
        view.loadHTMLString(document, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var document = ""

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let initial = navigationAction.navigationType == .other
                && navigationAction.request.url?.absoluteString == "about:blank"
            decisionHandler(initial ? .allow : .cancel)
        }
    }
}
