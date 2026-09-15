import AppKit
import WebKit

enum NotebookExporter {
    static func pythonScript(from notebook: Notebook) -> String {
        var parts: [String] = []
        for cell in notebook.cells {
            switch cell.cellType {
            case .code:
                parts.append("# %%\n" + cell.source)
            case .markdown:
                let commented = cell.source
                    .components(separatedBy: "\n")
                    .map { "# " + $0 }
                    .joined(separator: "\n")
                parts.append("# %% [markdown]\n" + commented)
            case .raw:
                let commented = cell.source
                    .components(separatedBy: "\n")
                    .map { "# " + $0 }
                    .joined(separator: "\n")
                parts.append("# %% [raw]\n" + commented)
            }
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    static func html(from notebook: Notebook, title: String, baseDirectory: URL? = nil) -> String {
        var body = ""
        for cell in notebook.cells {
            switch cell.cellType {
            case .markdown:
                let attachments = Notebook.attachmentData(cell.extraKeys["attachments"])
                body += "<div class=\"md\">\(markdownToHTML(cell.source, attachments: attachments, baseDirectory: baseDirectory))</div>\n"
            case .code:
                let count = cell.executionCount.map(String.init) ?? " "
                body += "<div class=\"cell\"><div class=\"prompt\">[\(count)]</div>"
                body += "<pre class=\"code\">\(escape(cell.source))</pre></div>\n"
                for output in cell.outputs {
                    body += outputHTML(output)
                }
            case .raw:
                body += "<pre class=\"raw\">\(escape(cell.source))</pre>\n"
            }
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(title))</title><style>
        body { font: 14px -apple-system, system-ui, sans-serif; max-width: 860px;
               margin: 40px auto; padding: 0 20px; color: #1d1d1f; background: #fff; }
        pre { font: 12px ui-monospace, SFMono-Regular, Menlo, monospace;
              overflow-x: auto; border-radius: 6px; padding: 10px 12px; }
        .cell { display: flex; gap: 8px; margin-top: 14px; }
        .prompt { color: #8e8e93; font: 11px ui-monospace, monospace; padding-top: 12px;
                  min-width: 34px; text-align: right; }
        .code { background: #f5f5f7; flex: 1; margin: 0; }
        .out { background: none; padding: 4px 12px 4px 54px; margin: 0; white-space: pre-wrap; }
        .err { color: #d70015; background: #fff1f0; margin-left: 42px; }
        img { max-width: 100%; margin: 8px 0 8px 42px; }
        .md { margin-top: 18px; line-height: 1.5; }
        .md img { margin: 8px 0; }
        .md code { background: #f5f5f7; padding: 1px 5px; border-radius: 4px;
                   font: 12px ui-monospace, monospace; }
        h1, h2, h3 { margin: 18px 0 6px; }
        @media (prefers-color-scheme: dark) {
          body { background: #1e1e1e; color: #e8e8e8; }
          .code, .md code { background: #2a2a2c; }
          .err { background: #3a2426; color: #ff6b62; }
        }
        </style></head><body>\(body)</body></html>
        """
    }

    private static func outputHTML(_ output: CellOutput) -> String {
        switch output.kind {
        case .stream(_, let text), .executeResult(let text):
            return "<pre class=\"out\">\(escape(String(text.prefix(20_000))))</pre>\n"
        case .image(let data, _), .plotlyFigure(_, _, let data, _, _):
            guard !data.isEmpty else {
                return "<pre class=\"out\">[interactive plotly figure]</pre>\n"
            }
            return "<img src=\"data:image/png;base64,\(data.base64EncodedString())\">\n"
        case .error(let ename, let evalue, let traceback, _):
            let text = traceback.isEmpty ? "\(ename): \(evalue)" : traceback
            return "<pre class=\"out err\">\(escape(text))</pre>\n"
        case .dataFrame(let payload):
            return "<pre class=\"out\">\(escape(payload.text))</pre>\n"
        case .ndarray(let payload):
            return "<pre class=\"out\">\(escape(payload.text))</pre>\n"
        case .jsonTree(let payload):
            return "<pre class=\"out\">\(escape(payload.text))</pre>\n"
        case .objectCard(let payload):
            return "<pre class=\"out\">\(escape(payload.text))</pre>\n"
        case .unsupported:
            return ""
        }
    }

    static func markdownToHTML(_ source: String,
                               attachments: [String: Data] = [:],
                               baseDirectory: URL? = nil) -> String {
        var html = ""
        var inCodeFence = false
        var inList = false
        func closeList() {
            if inList { html += "</ul>\n"; inList = false }
        }
        for rawLine in source.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                closeList()
                html += inCodeFence ? "</code></pre>\n" : "<pre><code>"
                inCodeFence.toggle()
                continue
            }
            if inCodeFence {
                html += escape(rawLine) + "\n"
                continue
            }
            if line.isEmpty {
                closeList()
                continue
            }
            if MarkdownView.imageMarkup(in: line, wholeLine: true) != nil {
                closeList()
                html += imageTag(from: line, attachments: attachments, baseDirectory: baseDirectory) + "\n"
                continue
            }
            var content = line
            var wrapper = "p"
            let hashes = line.prefix { $0 == "#" }.count
            if hashes >= 1, hashes <= 6, line.dropFirst(hashes).hasPrefix(" ") {
                wrapper = "h\(hashes)"
                content = String(line.dropFirst(hashes + 1))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                if !inList { html += "<ul>\n"; inList = true }
                html += "<li>\(inline(String(line.dropFirst(2)), attachments: attachments, baseDirectory: baseDirectory))</li>\n"
                continue
            }
            closeList()
            html += "<\(wrapper)>\(inline(content, attachments: attachments, baseDirectory: baseDirectory))</\(wrapper)>\n"
        }
        closeList()
        if inCodeFence { html += "</code></pre>\n" }
        return html
    }

    private static func inline(_ text: String,
                               attachments: [String: Data] = [:],
                               baseDirectory: URL? = nil) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "`"),
              let close = rest[rest.index(after: open)...].firstIndex(of: "`") {
            out += decorated(String(rest[..<open]), attachments: attachments, baseDirectory: baseDirectory)
            out += "<code>" + escape(String(rest[rest.index(after: open)..<close])) + "</code>"
            rest = rest[rest.index(after: close)...]
        }
        out += decorated(String(rest), attachments: attachments, baseDirectory: baseDirectory)
        return out
    }

    private static func decorated(_ text: String,
                                  attachments: [String: Data],
                                  baseDirectory: URL?) -> String {
        var out = ""
        for segment in MarkdownView.splitInlineMath(text) {
            switch segment {
            case .text(let s):
                out += emphasis(escape(s))
            case .math(let tex):
                out += "$" + escape(tex) + "$"
            case .image(let alt, let url):
                out += imageTag(alt: alt, url: url, attachments: attachments, baseDirectory: baseDirectory)
            }
        }
        return out
    }

    private static func imageTag(from line: String,
                                 attachments: [String: Data],
                                 baseDirectory: URL?) -> String {
        guard let markup = MarkdownView.imageMarkup(in: line, wholeLine: true) else {
            return "<p>\(inline(line, attachments: attachments, baseDirectory: baseDirectory))</p>"
        }
        return imageTag(alt: markup.alt, url: markup.url, attachments: attachments, baseDirectory: baseDirectory)
    }

    private static func imageTag(alt: String, url: String,
                                 attachments: [String: Data],
                                 baseDirectory: URL?) -> String {
        if let data = MarkdownView.imageData(url: url, attachments: attachments, baseDirectory: baseDirectory) {
            return "<img alt=\"\(escapeAttribute(alt))\" src=\"\(MarkdownView.dataURI(for: data))\">"
        }
        return alt.isEmpty ? escape(url) : escape(alt)
    }

    private static func emphasis(_ text: String) -> String {
        var out = regexReplace(text, pattern: "\\*\\*([^*]+)\\*\\*", template: "<b>$1</b>")
        out = regexReplace(out, pattern: "\\*([^*]+)\\*", template: "<i>$1</i>")
        return out
    }

    private static func regexReplace(_ text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: template)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ text: String) -> String {
        escape(text)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static var activePDFExports: [ObjectIdentifier: PDFRenderer] = [:]

    static func renderPDF(html: String, completion: @escaping (Data?) -> Void) {
        var key: ObjectIdentifier?
        let renderer = PDFRenderer(html: html) { data in
            if let key { activePDFExports[key] = nil }
            completion(data)
        }
        key = ObjectIdentifier(renderer)
        activePDFExports[ObjectIdentifier(renderer)] = renderer
    }

    private final class PDFRenderer: NSObject, WKNavigationDelegate {
        private let webView: WKWebView
        private let completion: (Data?) -> Void

        init(html: String, completion: @escaping (Data?) -> Void) {
            self.webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 820, height: 1060))
            self.completion = completion
            super.init()
            webView.navigationDelegate = self
            webView.loadHTMLString(html, baseURL: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                let config = WKPDFConfiguration()
                webView.createPDF(configuration: config) { result in
                    switch result {
                    case .success(let data): self.completion(data)
                    case .failure: self.completion(nil)
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            completion(nil)
        }
    }
}
