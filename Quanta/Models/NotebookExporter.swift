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
                body += "<pre class=\"code\">\(highlightedPython(cell.source))</pre></div>\n"
                for output in cell.outputs {
                    body += outputHTML(output)
                }
            case .raw:
                body += "<pre class=\"raw\">\(escape(cell.source))</pre>\n"
            }
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; style-src 'unsafe-inline'; img-src data:; font-src data:; frame-src about:; base-uri 'none'; form-action 'none'"><title>\(escape(title))</title><style>
        body { font: 14px -apple-system, system-ui, sans-serif; max-width: 860px;
               margin: 40px auto; padding: 0 20px; color: #1d1d1f; background: #fff; }
        pre { font: 12px ui-monospace, SFMono-Regular, Menlo, monospace;
              overflow-x: auto; border-radius: 6px; padding: 10px 12px; }
        .cell { display: flex; gap: 8px; margin-top: 14px; }
        .prompt { color: #8e8e93; font: 11px ui-monospace, monospace; padding-top: 12px;
                  min-width: 34px; text-align: right; }
        .code { background: #f5f5f7; flex: 1; margin: 0; }
        \(syntaxStyles)
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
        table { border-collapse: collapse; width: 100%; margin: 12px 0; font-size: 12px; }
        th, td { padding: 6px 8px; border-bottom: 1px solid #ccc; text-align: left; overflow-wrap: anywhere; }
        th { background: #f5f5f7; color: #1d1d1f; }
        caption { text-align: left; color: #666; padding: 6px 0; }
        .rich-output { margin: 8px 0 8px 42px; }
        .rich-output img { margin-left: 0; }
        .rich-output pre { white-space: pre-wrap; overflow-wrap: anywhere; }
        math { font-size: 1.1em; }
        iframe { display: block; }
        @media print {
          @page { size: letter; margin: 0.5in; }
          body { max-width: none; margin: 0; padding: 0; background: white; color: black; }
          pre, .code { white-space: pre-wrap; overflow-wrap: anywhere; }
          .code, .md code { background: #f5f5f7; }
          .code { \(syntaxVariables(dark: false)) }
          .err { color: #a00; background: #fff1f0; }
          .cell { display: block; }
          .prompt { float: left; padding-right: 8px; }
          .code { margin-left: 42px; }
          h1, h2, h3, h4, h5, h6 { break-after: avoid; }
          tr, img, iframe, math { break-inside: avoid; }
          thead { display: table-header-group; }
          img { max-height: 8in; object-fit: contain; }
        }
        </style><script>\(preparationScript)</script></head><body>\(body)</body></html>
        """
    }

    static func highlightedPython(_ source: String) -> String {
        let key = NSAttributedString.Key("QuantaSyntaxKind")
        let styled = NSMutableAttributedString(string: source)
        for token in PythonHighlighter.tokens(source) {
            styled.addAttribute(key, value: token.kind.rawValue, range: token.range)
        }
        var html = ""
        styled.enumerateAttribute(key, in: NSRange(location: 0, length: styled.length)) { value, range, _ in
            let text = escape((source as NSString).substring(with: range))
            if let kind = value as? String { html += "<span class=\"syntax-\(kind)\">\(text)</span>" }
            else { html += text }
        }
        return html
    }

    private static func syntaxVariables(dark: Bool) -> String {
        PythonHighlighter.Kind.allCases.map {
            "--syntax-\($0.rawValue):\(EditorTheme.syntaxHex($0, dark: dark));"
        }.joined()
    }

    private static var syntaxStyles: String {
        let rules = PythonHighlighter.Kind.allCases.map {
            ".code .syntax-\($0.rawValue){color:var(--syntax-\($0.rawValue))}"
        }.joined()
        return """
        .code { \(syntaxVariables(dark: false)) print-color-adjust:exact; -webkit-print-color-adjust:exact; }
        \(rules)
        @media (prefers-color-scheme: dark) { .code { \(syntaxVariables(dark: true)) } }
        :root[data-quanta-print] .code { \(syntaxVariables(dark: false)) }
        """
    }

    private static func outputHTML(_ output: CellOutput) -> String {
        if let bundle = RichOutput.bundle(output) {
            if let figure = bundle[RichOutput.plotlyMIME] as? [String: Any],
               let document = RichOutput.plotlyDocument(figure) {
                return "<iframe data-quanta-plot sandbox=\"allow-scripts\" referrerpolicy=\"no-referrer\" style=\"width:100%;height:500px;border:0\" srcdoc=\"\(RichOutput.escape(document))\"></iframe>\n"
            }
            let document = RichOutput.safeDocument(RichOutput.staticHTML(bundle))
            let encoded = Data(RichOutput.staticHTML(bundle).utf8).base64EncodedString()
            return "<iframe data-quanta-static=\"\(encoded)\" sandbox=\"\" referrerpolicy=\"no-referrer\" style=\"width:100%;height:360px;border:0\" srcdoc=\"\(RichOutput.escape(document))\"></iframe>\n"
        }
        switch output.kind {
        case .stream(_, let text), .executeResult(let text):
            return "<pre class=\"out\">\(escape(text))</pre>\n"
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
        case .rich(let bundle):
            return "<pre class=\"out\">\(escape(RichOutput.text(bundle["text/plain"])))</pre>\n"
        case .unsupported(let mime):
            return "<pre class=\"out\">Unsupported output: \(escape(mime))</pre>\n"
        }
    }

    static func markdownToHTML(_ source: String,
                               attachments: [String: Data] = [:],
                               baseDirectory: URL? = nil) -> String {
        var html = ""
        var inList = false
        func content(_ text: String) -> String {
            inline(text, attachments: attachments, baseDirectory: baseDirectory)
        }
        for block in MarkdownView.parse(source) {
            if case .bullet = block {} else if inList { html += "</ul>\n"; inList = false }
            switch block {
            case .heading(let level, let text): html += "<h\(level)>\(content(text))</h\(level)>\n"
            case .paragraph(let text): html += "<p>\(content(text))</p>\n"
            case .code(let code): html += "<pre><code>\(escape(code))</code></pre>\n"
            case .bullet(let text):
                if !inList { html += "<ul>\n"; inList = true }
                html += "<li>\(content(text))</li>\n"
            case .math(let tex): html += "<div class=\"math\">\(NotebookMath.html(tex, display: true))</div>\n"
            case .image(let alt, let url):
                html += imageTag(alt: alt, url: url, attachments: attachments, baseDirectory: baseDirectory) + "\n"
            case .table(let rows):
                guard let header = rows.first else { continue }
                html += "<table><thead><tr>" + header.map { "<th>\(content($0))</th>" }.joined() + "</tr></thead><tbody>"
                for row in rows.dropFirst() {
                    html += "<tr>" + row.map { "<td>\(content($0))</td>" }.joined() + "</tr>"
                }
                html += "</tbody></table>\n"
            }
        }
        if inList { html += "</ul>\n" }
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
                out += linkedText(s)
            case .math(let tex):
                out += NotebookMath.html(tex, display: false)
            case .image(let alt, let url):
                out += imageTag(alt: alt, url: url, attachments: attachments, baseDirectory: baseDirectory)
            }
        }
        return out
    }

    private static func imageTag(alt: String, url: String,
                                 attachments: [String: Data],
                                 baseDirectory: URL?) -> String {
        if let data = MarkdownView.imageData(url: url, attachments: attachments, baseDirectory: baseDirectory) {
            return "<img alt=\"\(escapeAttribute(alt))\" src=\"\(MarkdownView.dataURI(for: data))\">"
        }
        return alt.isEmpty ? escape(url) : escape(alt)
    }

    private static func linkedText(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^\s)]+)\)"#) else { return emphasis(escape(text)) }
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += emphasis(escape(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))))
            let label = source.substring(with: match.range(at: 1))
            let target = source.substring(with: match.range(at: 2))
            if let url = URL(string: target), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                result += "<a href=\"\(escapeAttribute(target))\" rel=\"noreferrer\">\(emphasis(escape(label)))</a>"
            } else { result += emphasis(escape(label)) }
            cursor = NSMaxRange(match.range)
        }
        return result + emphasis(escape(source.substring(from: cursor)))
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

    private static var activePDFExports: [ObjectIdentifier: NotebookPDFRenderer] = [:]

    static func renderPDF(html: String, completion: @escaping (Data?) -> Void) {
        let renderer = NotebookPDFRenderer { renderer, data in
            activePDFExports[ObjectIdentifier(renderer)] = nil
            completion(data)
        }
        activePDFExports[ObjectIdentifier(renderer)] = renderer
        renderer.start(html: html)
    }
}
