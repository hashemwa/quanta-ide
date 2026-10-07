import AppKit

enum NotebookOutputExport {
    static func html(_ output: CellOutput) -> String? {
        switch output.kind {
        case .ndarray(let array): arrayHTML(array)
        case .objectCard(let card): objectHTML(card)
        default: nil
        }
    }

    private static func arrayHTML(_ array: NDArrayPayload) -> String {
        let stats = ["min", "max", "mean", "std"].compactMap { key -> String? in
            guard let value = array.stats[key], value.isFinite else { return nil }
            return "<span>\(key) \(RichOutput.escape(NDArrayView.compact(value)))</span>"
        }.joined(separator: " · ")
        var preview = ""
        if let values = array.series {
            var path = ""
            var started = false
            for point in SparklineView.normalizedPoints(values) {
                guard let point else { started = false; continue }
                path += "\(started ? "L" : "M")\(point.x * 600),\(point.y * 80) "
                started = true
            }
            if !path.isEmpty {
                let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 600 80\"><path d=\"\(path)\" fill=\"none\" stroke=\"#5d6c79\" stroke-width=\"1.5\"/></svg>"
                preview = "<img class=\"array-preview\" alt=\"Array sparkline\" src=\"data:image/svg+xml;base64,\(Data(svg.utf8).base64EncodedString())\">"
            }
        } else if let image = NDArrayView.cachedHeatmapImage(array),
                  let bitmap = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
                  let data = bitmap.representation(using: .png, properties: [:]) {
            preview = "<img class=\"array-preview heatmap\" alt=\"Array heatmap\" src=\"data:image/png;base64,\(data.base64EncodedString())\">"
        }
        return """
        <div class="rich-output output-card"><p><strong>ndarray \(RichOutput.escape(array.shapeLabel))</strong> · <code>\(RichOutput.escape(array.dtype))</code></p><p>\(stats)</p>\(preview)<pre>\(RichOutput.escape(array.text))</pre></div>
        """
    }

    private static func objectHTML(_ card: ObjectCardPayload) -> String {
        let badges = card.badges.map { "<code>\(RichOutput.escape($0))</code>" }.joined(separator: " ")
        let fields = card.fields.map { "<dt>\(RichOutput.escape($0.name))</dt><dd>\(RichOutput.escape($0.value))</dd>" }.joined()
        return """
        <div class="rich-output output-card"><h3>\(RichOutput.escape(card.title))</h3><p>\(RichOutput.escape(card.subtitle))</p><p>\(badges)</p><dl>\(fields)</dl><pre>\(RichOutput.escape(card.text))</pre></div>
        """
    }
}
