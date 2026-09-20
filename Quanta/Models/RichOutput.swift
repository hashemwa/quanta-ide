import AppKit

enum RichOutput {
    static let plotlyMIME = "application/vnd.plotly.v1+json"
    static let dataframeMIME = "application/vnd.quanta.dataframe+json"

    static func text(_ value: Any?) -> String {
        (value as? String) ?? (value as? [String])?.joined() ?? ""
    }

    static func raw(_ bundle: [String: Any], metadata: [String: Any] = [:]) -> [String: Any] {
        ["output_type": "display_data", "data": bundle, "metadata": metadata]
    }

    static func kind(_ bundle: [String: Any]) -> CellOutput.Kind {
        if var payload = bundle[dataframeMIME] as? [String: Any] {
            payload.removeValue(forKey: "name")
            if let frame = DataFramePayload(dict: payload) { return .dataFrame(frame) }
        }
        if let payload = bundle["application/vnd.quanta.ndarray+json"] as? [String: Any],
           let array = NDArrayPayload(dict: payload) { return .ndarray(array) }
        if let payload = bundle["application/vnd.quanta.objectcard+json"] as? [String: Any],
           let card = ObjectCardPayload(dict: payload) { return .objectCard(card) }
        if let figure = bundle[plotlyMIME] as? [String: Any], let html = plotlyHTML(figure),
           let js = bundledPlotlyPath {
            let png = Data(base64Encoded: text(bundle["image/png"]), options: .ignoreUnknownCharacters) ?? Data()
            return .plotlyFigure(html: html, jsPath: js, data: png, image: NSImage(data: png), height: 450)
        }
        for mime in ["image/png", "image/jpeg", "image/gif", "image/webp"] {
            if let data = Data(base64Encoded: text(bundle[mime]), options: .ignoreUnknownCharacters),
               let image = NSImage(data: data) { return .image(data: data, image: image) }
        }
        if bundle["text/html"] != nil || bundle["image/svg+xml"] != nil { return .rich(bundle) }
        if let json = bundle["application/json"] {
            return .jsonTree(JSONTreePayload(value: json, summary: "JSON", text: text(bundle["text/plain"])))
        }
        if bundle["text/plain"] != nil { return .executeResult(text: text(bundle["text/plain"]).strippingANSI) }
        return .unsupported(mime: bundle.keys.sorted().first ?? "empty")
    }

    static var bundledPlotlyPath: String? {
        (Bundle.main.url(forResource: "plotly.min", withExtension: "js", subdirectory: "Plotly")
            ?? Bundle.main.url(forResource: "plotly.min", withExtension: "js"))?.path
    }

    static func plotlyHTML(_ figure: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(figure),
              let bytes = try? JSONSerialization.data(withJSONObject: figure) else { return nil }
        return """
        <div id="quanta-figure"></div><script>
        const figure = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('\(bytes.base64EncodedString())'), c => c.charCodeAt(0))));
        Plotly.newPlot('quanta-figure', figure.data || [], figure.layout || {}, {responsive:true,displayModeBar:false});
        </script>
        """
    }

    static func plotlyDocument(_ figure: [String: Any]) -> String? {
        guard let path = bundledPlotlyPath, let html = plotlyHTML(figure),
              let script = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; base-uri 'none'; form-action 'none'">
        <script>\(script.replacingOccurrences(of: "</script", with: "<\\/script"))</script>
        </head><body>\(html)</body></html>
        """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func tableHTML(_ frame: DataFramePayload) -> String {
        let headers = (["Index"] + frame.columns).map { "<th>\(escape($0))</th>" }.joined()
        let rows = frame.rows.enumerated().map { index, row in
            let label = index < frame.index.count ? frame.index[index] : String(index)
            return "<tr>" + ([label] + row).map { "<td>\(escape($0))</td>" }.joined() + "</tr>"
        }.joined()
        return "<table><caption>\(escape(frame.rowSummary)) · \(escape(frame.columnSummary)) (display preview)</caption><thead><tr>\(headers)</tr></thead><tbody>\(rows)</tbody></table>"
    }

    static func bundle(_ output: CellOutput) -> [String: Any]? {
        if let data = output.raw?["data"] as? [String: Any] { return data }
        switch output.kind {
        case .rich(let bundle): return bundle
        case .dataFrame(let frame): return ["text/html": tableHTML(frame), "text/plain": frame.text]
        case .jsonTree(let tree): return ["application/json": tree.value, "text/plain": tree.text]
        default: return nil
        }
    }

    static func staticHTML(_ bundle: [String: Any]) -> String {
        if bundle["text/html"] != nil { return text(bundle["text/html"]) }
        if bundle["image/svg+xml"] != nil {
            let svg = Data(text(bundle["image/svg+xml"]).utf8).base64EncodedString()
            return "<img alt=\"SVG output\" src=\"data:image/svg+xml;base64,\(svg)\">"
        }
        for mime in ["image/png", "image/jpeg", "image/gif", "image/webp"] {
            if let bytes = Data(base64Encoded: text(bundle[mime]), options: .ignoreUnknownCharacters), !bytes.isEmpty {
                return "<img alt=\"Image output\" src=\"data:\(mime);base64,\(bytes.base64EncodedString())\">"
            }
        }
        if let json = bundle["application/json"],
           let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
           let text = String(data: data, encoding: .utf8) { return "<pre>\(escape(text))</pre>" }
        let fallback = bundle["text/plain"].map { text($0) }
            ?? "Unsupported rich output: " + bundle.keys.sorted().joined(separator: ", ")
        return "<pre>\(escape(fallback))</pre>"
    }

    static func safeDocument(_ body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; base-uri 'none'; form-action 'none'; frame-src 'none'">
        <style>:root{color-scheme:light dark}body{font:13px -apple-system,system-ui;margin:8px}table{border-collapse:collapse}td,th{padding:5px 9px;border:1px solid #8886;text-align:left}caption{padding:6px;text-align:left}img{max-width:100%}pre{white-space:pre-wrap}</style>
        </head><body>\(body)</body></html>
        """
    }
}
