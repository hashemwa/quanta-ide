import AppKit
import JavaScriptCore
import WebKit

enum NotebookMath {
    private static let context: JSContext? = {
        guard let url = Bundle.main.url(forResource: "katex.min", withExtension: "js", subdirectory: "KaTeX")
                ?? Bundle.main.url(forResource: "katex.min", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8),
              let context = JSContext() else { return nil }
        context.evaluateScript(script)
        return context
    }()

    static func html(_ tex: String, display: Bool) -> String {
        let options: [String: Any] = ["output": "mathml", "displayMode": display,
                                     "throwOnError": false, "trust": false, "maxExpand": 1000, "maxSize": 20]
        if let context, let katex = context.objectForKeyedSubscript("katex"),
           let result = katex.invokeMethod("renderToString", withArguments: [tex, options]),
           !result.isUndefined, let html = result.toString() { return html }
        return "<code class=\"math-error\">\(RichOutput.escape(tex))</code>"
    }
}

@MainActor
final class NotebookMathRenderer: NSObject, WKNavigationDelegate {
    static let shared = NotebookMathRenderer()

    private struct Request {
        let tex: String
        let display: Bool
        let fontSize: CGFloat
        let color: String
        let completion: (NSImage?, CGFloat, String?) -> Void
    }

    private let webView: WKWebView
    private let window: NSWindow
    private var ready = false
    private var requests: [Request] = []
    private var current: Request?
    private var timeout: DispatchWorkItem?

    private override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 2400, height: 600),
                            configuration: configuration)
        window = NSWindow(contentRect: webView.frame, styleMask: .borderless,
                          backing: .buffered, defer: false)
        super.init()
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        window.isReleasedWhenClosed = false
        window.contentView = webView
        webView.loadHTMLString(Self.document, baseURL: nil)
    }

    func render(_ tex: String, display: Bool, fontSize: CGFloat, color: String,
                completion: @escaping (NSImage?, CGFloat, String?) -> Void) {
        requests.append(Request(tex: tex, display: display, fontSize: fontSize,
                                color: color, completion: completion))
        startNext()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        startNext()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failAll(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        failAll(error.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        finish(nil, depth: 0, error: "Math renderer stopped")
        webView.loadHTMLString(Self.document, baseURL: nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let initial = navigationAction.navigationType == .other
            && navigationAction.request.url?.absoluteString == "about:blank"
        decisionHandler(initial ? .allow : .cancel)
    }

    private func startNext() {
        guard ready, current == nil, !requests.isEmpty else { return }
        let request = requests.removeFirst()
        current = request
        let work = DispatchWorkItem { [weak self] in
            self?.finish(nil, depth: 0, error: "Math rendering timed out")
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        let markup = NotebookMath.html(request.tex, display: request.display)
        webView.callAsyncJavaScript(Self.layoutScript,
                                    arguments: ["markup": markup,
                                                "fontSize": Double(request.fontSize),
                                                "color": request.color],
                                    in: nil, in: .page) { [weak self] result in
            guard let self, self.current != nil else { return }
            guard case .success(let value) = result,
                  let layout = value as? [String: Any],
                  let x = layout["x"] as? Double,
                  let y = layout["y"] as? Double,
                  let width = layout["width"] as? Double,
                  let height = layout["height"] as? Double,
                  let depth = layout["depth"] as? Double,
                  [x, y, width, height, depth].allSatisfy(\.isFinite),
                  width > 0, height > 0, width <= 2200, height <= 500 else {
                self.finish(nil, depth: 0, error: "Math layout failed")
                return
            }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(x: x, y: y, width: width, height: height)
            self.webView.takeSnapshot(with: configuration) { [weak self] image, error in
                guard let self, self.current != nil else { return }
                if let image {
                    image.size = NSSize(width: width, height: height)
                    self.finish(image, depth: CGFloat(depth), error: nil)
                } else {
                    self.finish(nil, depth: 0,
                                error: error?.localizedDescription ?? "Math snapshot failed")
                }
            }
        }
    }

    private func finish(_ image: NSImage?, depth: CGFloat, error: String?) {
        guard let request = current else { return }
        timeout?.cancel()
        timeout = nil
        current = nil
        request.completion(image, depth, error)
        startNext()
    }

    private func failAll(_ message: String) {
        ready = false
        if current != nil { finish(nil, depth: 0, error: message) }
        let pending = requests
        requests = []
        for request in pending { request.completion(nil, 0, message) }
    }

    private static let document = #"""
    <!doctype html><html><head><meta charset="utf-8"><style>
    html,body{margin:0;padding:0;background:transparent;overflow:hidden}
    #math{display:inline-block;box-sizing:border-box;padding:2px;white-space:nowrap;line-height:normal}
    math{font-family:"STIX Two Math","STIXGeneral","Times New Roman",serif}
    #baseline{display:inline-block;width:0;height:0;margin:0;padding:0;vertical-align:baseline}
    </style></head><body><span id="math"></span></body></html>
    """#

    private static let layoutScript = #"""
    const root = document.getElementById('math');
    root.style.fontSize = `${fontSize}px`;
    root.style.color = color;
    root.innerHTML = markup;
    const marker = document.createElement('span');
    marker.id = 'baseline';
    root.appendChild(marker);
    await document.fonts.ready;
    const rect = root.getBoundingClientRect();
    const markerRect = marker.getBoundingClientRect();
    return {
      x: Math.floor(rect.x),
      y: Math.floor(rect.y),
      width: Math.ceil(rect.width),
      height: Math.ceil(rect.height),
      depth: Math.max(0, rect.bottom - markerRect.top)
    };
    """#
}
