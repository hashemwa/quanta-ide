import AppKit
import WebKit

final class NotebookPDFRenderer: NSObject, WKNavigationDelegate {
    private let completion: (NotebookPDFRenderer, Data?) -> Void
    private var finished = false
    private var timeout: DispatchWorkItem?
    private let webView: WKWebView
    private var window: NSWindow?

    init(completion: @escaping (NotebookPDFRenderer, Data?) -> Void) {
        self.completion = completion
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 960), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func start(html: String) {
        let window = NSWindow(contentRect: webView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        self.window = window
        let timeout = DispatchWorkItem { [weak self] in self?.finish(nil) }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 35, execute: timeout)
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let script = #"""
        if (window.quantaExportReady) await window.quantaExportReady;
        const style = document.createElement('style');
        style.textContent = `:root{color-scheme:light}body{width:720px;max-width:720px;margin:0;padding:0;background:white;color:black}
          pre,.code{white-space:pre-wrap;overflow-wrap:anywhere}.code,.md code{background:#f5f5f7}
          .cell{display:block}.prompt{float:left;padding-right:8px}.code{margin-left:42px}
          .err{color:#a00;background:#fff1f0}img{max-width:calc(100% - 42px);max-height:900px;object-fit:contain}
          .md img,.rich-output img{max-width:100%}`;
        document.head.appendChild(style);
        await document.fonts.ready;
        const height = Math.ceil(document.body.getBoundingClientRect().bottom + window.scrollY);
        const ranges = [];
        for (const element of document.querySelectorAll('tr,img,iframe,math,h1,h2,h3,h4,h5,h6')) {
          const rect = element.getBoundingClientRect();
          ranges.push([rect.top + window.scrollY, rect.bottom + window.scrollY]);
        }
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        while (walker.nextNode()) {
          const node = walker.currentNode;
          if (!node.textContent.trim() || ['SCRIPT','STYLE'].includes(node.parentElement.tagName)) continue;
          const range = document.createRange();
          range.selectNodeContents(node);
          for (const rect of range.getClientRects()) ranges.push([rect.top + window.scrollY, rect.bottom + window.scrollY]);
        }
        return {height, ranges};
        """#
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self, !self.finished else { return }
            guard case .success(let value) = result, let layout = value as? [String: Any],
                  let height = layout["height"] as? Double, height.isFinite, height > 0, height <= 480_000 else {
                self.finish(nil)
                return
            }
            let ranges = (layout["ranges"] as? [[Double]] ?? []).compactMap { pair -> ClosedRange<Double>? in
                guard pair.count == 2, pair[0].isFinite, pair[1].isFinite, pair[1] >= pair[0] else { return nil }
                return pair[0]...pair[1]
            }
            let rects = Self.pageRects(height: height, ranges: ranges)
            guard rects.count <= 500 else { self.finish(nil); return }
            let data = NSMutableData()
            var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
            guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
                self.finish(nil)
                return
            }
            self.capture(rects, index: 0, context: context, data: data)
        }
    }

    static func pageRects(height: Double, ranges: [ClosedRange<Double>]) -> [CGRect] {
        guard height.isFinite, height > 0, height <= 480_000 else { return [] }
        let pageHeight = 960.0
        var result: [CGRect] = []
        var top = 0.0
        while top < height, result.count <= 500 {
            var bottom = min(top + pageHeight, height)
            for _ in 0..<100 {
                let crossing = ranges.filter { $0.lowerBound > top + 1 && $0.lowerBound < bottom && $0.upperBound > bottom && $0.upperBound - $0.lowerBound <= pageHeight }
                guard let start = crossing.map(\.lowerBound).min() else { break }
                bottom = start
            }
            result.append(CGRect(x: 0, y: top, width: 720, height: bottom - top))
            top = bottom
        }
        return result
    }

    private func capture(_ rects: [CGRect], index: Int, context: CGContext, data: NSMutableData) {
        guard !finished else { context.closePDF(); return }
        guard index < rects.count else {
            context.closePDF()
            finish(data as Data)
            return
        }
        let configuration = WKPDFConfiguration()
        configuration.rect = rects[index]
        webView.createPDF(configuration: configuration) { [weak self] result in
            guard let self, !self.finished else { context.closePDF(); return }
            guard case .success(let pageData) = result,
                  let provider = CGDataProvider(data: pageData as CFData),
                  let document = CGPDFDocument(provider), let page = document.page(at: 1) else {
                context.closePDF()
                self.finish(nil)
                return
            }
            context.beginPDFPage(nil)
            context.saveGState()
            let height = rects[index].height * 0.75
            let destination = CGRect(x: 36, y: 756 - height, width: 540, height: height)
            context.clip(to: destination)
            context.concatenate(page.getDrawingTransform(.mediaBox, rect: destination, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            context.restoreGState()
            context.endPDFPage()
            self.capture(rects, index: index + 1, context: context, data: data)
        }
    }

    private func finish(_ data: Data?) {
        guard !finished else { return }
        finished = true
        timeout?.cancel()
        webView.stopLoading()
        webView.navigationDelegate = nil
        window?.close()
        window = nil
        completion(self, data)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(nil) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(nil) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(nil) }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url?.absoluteString ?? ""
        decisionHandler(navigationAction.navigationType == .other && ["about:blank", "about:srcdoc"].contains(url) ? .allow : .cancel)
    }
}
