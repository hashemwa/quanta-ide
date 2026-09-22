import SwiftUI
import UniformTypeIdentifiers

struct OutputListView: View {
    @ObservedObject var cell: NotebookCell

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(cell.outputs) { output in
                OutputItemView(output: output)
            }
        }
        .environment(\.outputCellID, cell.id)
        .padding(.bottom, 2)
    }
}

struct OutputItemView: View {
    let output: CellOutput
    @Environment(\.monoFontSize) private var monoSize

    var body: some View {
        switch output.kind {
        case .stream(let name, let text):
            StreamOutputView(name: name, text: text)

        case .executeResult(let text):
            Text(text.trimmingTrailingNewlines)
                .font(.system(size: monoSize, design: .monospaced))
                .textSelection(.enabled)
                .padding(.leading, DS.Layout.cellTextInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu {
                    Button("Copy Text") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }

        case .image(let data, let image):
            if let image {
                ImageOutputView(data: data, image: image)
            } else {
                Label("Could not decode image output", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .plotlyFigure(let html, let jsPath, let data, let image, let height):
            PlotlyFigureView(html: html, jsPath: jsPath, image: image, imageData: data,
                             height: height, cacheKey: output.id)

        case .error(let ename, let evalue, let traceback, let frames):
            TracebackView(ename: ename, evalue: evalue, traceback: traceback,
                          frames: frames)

        case .dataFrame(let payload):
            DataFrameOutputView(payload: payload, cacheKey: output.id)

        case .ndarray(let payload):
            NDArrayView(payload: payload)

        case .jsonTree(let payload):
            JSONTreeView(payload: payload)

        case .objectCard(let payload):
            ObjectCardView(payload: payload)

        case .rich(let bundle):
            RichOutputView(bundle: bundle)
                .frame(height: DS.Layout.richOutputHeight)
                .accessibilityLabel("Rich notebook output")

        case .unsupported(let mime):
            Label("Rich output (\(mime)) — not rendered yet, preserved on save",
                  systemImage: "doc.richtext")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
    }
}

struct ImageOutputView: View {
    let data: Data
    let image: NSImage
    var fileName = "output.png"
    @State private var actualSize = false
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            plot
                .accessibilityLabel(accessibilityDescription)
            controls
            if let saveError { PlotErrorMessage(message: saveError) }
        }
        .frame(maxWidth: actualSize ? DS.Layout.outputMaxWidth : max(displayWidth, DS.Layout.plotControlsMinWidth), alignment: .leading)
        .padding(.vertical, DS.Space.xxs)
    }

    @ViewBuilder
    private var plot: some View {
            if actualSize {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: image.size.width, height: image.size.height)
                }
                .frame(maxWidth: DS.Layout.outputMaxWidth,
                       maxHeight: DS.Layout.outputMaxHeight, alignment: .leading)
            } else {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: displayWidth, maxHeight: DS.Layout.outputMaxHeight,
                           alignment: .leading)
            }
    }

    private var accessibilityDescription: String {
        if let bitmap = NSBitmapImageRep(data: data) {
            return "Plot output, \(bitmap.pixelsWide) by \(bitmap.pixelsHigh) pixels"
        }
        let natural = image.size
        guard natural.width > 0, natural.height > 0 else { return "Plot output" }
        return "Plot output, \(Int(natural.width)) by \(Int(natural.height)) points"
    }

    private var displayWidth: CGFloat {
        let natural = image.size
        guard natural.width > 0, natural.height > 0 else { return DS.Layout.outputMaxWidth }
        let width = min(DS.Layout.outputMaxWidth, natural.width)
        guard width * natural.height / natural.width > DS.Layout.outputMaxHeight else {
            return width
        }
        return DS.Layout.outputMaxHeight * natural.width / natural.height
    }

    private var controls: some View {
        PlotControlBar {
            IconButton(actualSize ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       help: actualSize ? "Fit to Width" : "Actual Size",
                       isActive: actualSize) {
                actualSize.toggle()
            }
            IconButton("doc.on.doc", help: "Copy image") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
            }
            IconButton("macwindow.badge.plus", help: "Open in separate window (⌥⌘P)") {
                PlotWindow.open(image: image)
            }
            IconButton("square.and.arrow.down", help: "Save as PNG…") { savePNG() }
        }
    }

    private func savePNG() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = [.png]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try PlotImageExport.pngData(image: image, original: data).write(to: url, options: .atomic)
                saveError = nil
            } catch {
                saveError = "Couldn’t save image: \(error.localizedDescription)"
            }
        }
    }

}

enum PlotImageExport {
    enum Failure: LocalizedError {
        case encoding
        var errorDescription: String? { "The image could not be encoded as PNG." }
    }

    static func pngData(image: NSImage, original: Data) throws -> Data {
        let representation = NSBitmapImageRep(data: original)
            ?? image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }
        guard let png = representation?.representation(using: .png, properties: [:]) else {
            throw Failure.encoding
        }
        return png
    }
}

struct DataFrameOutputView: View {
    let payload: DataFramePayload
    let cacheKey: UUID
    private var app: AppState { AppState.shared }
    @Environment(\.monoFontSize) private var monoFontSize

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DataFrameNSTable(payload: payload, cacheKey: cacheKey, isInline: true)
                .frame(height: DataFrameNSTable.inlineHeight(rowCount: payload.displayRowCount,
                                                             monoSize: monoFontSize))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                .outputCard()
                .contextMenu {
                    Button("Copy as TSV") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(payload.tsv, forType: .string)
                    }
                    Button("Copy as Text") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(payload.text, forType: .string)
                    }
                    if let name = payload.name {
                        Button("Open Full Table") { app.openDataFrame(named: name) }
                    }
                }
            HStack(spacing: 8) {
                Text("\(payload.rowSummary) · \(payload.columnSummary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let name = payload.name {
                    Button("Open full table") { app.openDataFrame(named: name) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
    }
}

enum MarkdownBlock: Equatable {
    case heading(Int, String)
    case code(String)
    case bullet(String)
    case paragraph(String)
    case math(String)
    case image(alt: String, url: String)
    case table([[String]])
    case html(level: Int?, alignment: MarkdownTextAlignment, text: String)
}

enum MarkdownTextAlignment: Equatable {
    case leading
    case center
    case trailing
}

enum InlineMarkdownSegment: Equatable {
    case text(String)
    case math(String)
    case image(alt: String, url: String)
}

enum MathPalette {
    static func hex(for scheme: ColorScheme) -> String {
        scheme == .dark ? "#E8E8E8" : "#1D1D1F"
    }
}

struct MarkdownView: View {
    let source: String
    var selectable = true
    var attachments: [String: Data] = [:]
    var baseDirectory: URL? = nil
    @Environment(\.monoFontSize) private var monoSize

    private static var parseCache: [String: [MarkdownBlock]] = [:]
    private static var parseOrder: [String] = []
    private static var inlineCache: [String: [InlineMarkdownSegment]] = [:]
    private static var inlineOrder: [String] = []
    private static var attributedCache: [String: AttributedString] = [:]
    private static var attributedOrder: [String] = []

    static func cachedParse(_ source: String) -> [MarkdownBlock] {
        if let hit = parseCache[source] { return hit }
        let parsed = parse(source)
        parseCache[source] = parsed
        parseOrder.append(source)
        if parseOrder.count > 400 { parseCache[parseOrder.removeFirst()] = nil }
        return parsed
    }

    static func cachedInlineSegments(_ source: String) -> [InlineMarkdownSegment] {
        if let hit = inlineCache[source] { return hit }
        let parsed = splitInlineMath(source)
        inlineCache[source] = parsed
        inlineOrder.append(source)
        if inlineOrder.count > 800 { inlineCache[inlineOrder.removeFirst()] = nil }
        return parsed
    }

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 6) {
            let parsed = MarkdownView.cachedParse(source)
            ForEach(parsed.indices, id: \.self) { index in
                blockView(parsed[index])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if selectable {
            content.textSelection(.enabled)
        } else {
            content.textSelection(.disabled)
        }
    }

    static func parse(_ source: String) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        var inCode = false
        var inMath = false
        var codeLines: [String] = []
        var mathLines: [String] = []
        var paragraph: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                result.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }
        func flushMath() {
            let tex = mathLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !tex.isEmpty { result.append(.math(tex)) }
            mathLines = []
            inMath = false
        }

        let lines = source.components(separatedBy: "\n")
        var inTable = false
        for (lineIndex, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inCode {
                if trimmed.hasPrefix("```") {
                    result.append(.code(codeLines.joined(separator: "\n")))
                    codeLines = []
                    inCode = false
                } else {
                    codeLines.append(line)
                }
                continue
            }
            if inMath {
                if trimmed.hasSuffix("$$") {
                    mathLines.append(String(trimmed.dropLast(2)))
                    flushMath()
                } else {
                    mathLines.append(trimmed)
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flushParagraph()
                inCode = true
                continue
            }
            if trimmed.hasPrefix("$$") {
                flushParagraph()
                let rest = String(trimmed.dropFirst(2))
                if rest.hasSuffix("$$"), rest.count >= 2 {
                    mathLines = [String(rest.dropLast(2))]
                    flushMath()
                } else {
                    inMath = true
                    mathLines = rest.isEmpty ? [] : [rest]
                }
                continue
            }
            if let image = imageMarkup(in: trimmed, wholeLine: true) {
                flushParagraph()
                result.append(.image(alt: image.alt, url: image.url))
                continue
            }
            if let html = htmlBlock(trimmed) {
                flushParagraph()
                result.append(.html(level: html.level, alignment: html.alignment, text: html.text))
                continue
            }
            let nextIsSeparator = lineIndex + 1 < lines.count && isTableSeparator(lines[lineIndex + 1])
            if trimmed.contains("|"), inTable || nextIsSeparator {
                var cells = trimmed.split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.first?.isEmpty == true { cells.removeFirst() }
                if cells.last?.isEmpty == true { cells.removeLast() }
                if cells.count >= 2 {
                    flushParagraph()
                    inTable = true
                    let separator = cells.allSatisfy {
                        !$0.isEmpty && $0.trimmingCharacters(in: CharacterSet(charactersIn: "-: ")).isEmpty
                    }
                    if !separator {
                        if case .table(var rows)? = result.last {
                            rows.append(Array(cells))
                            result[result.count - 1] = .table(rows)
                        } else {
                            result.append(.table([Array(cells)]))
                        }
                    }
                    continue
                }
            }
            inTable = false
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            let level = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(level), trimmed.dropFirst(level).hasPrefix(" ") {
                flushParagraph()
                let text = trimmed.dropFirst(level + 1).trimmingCharacters(in: .whitespaces)
                if let html = htmlBlock(String(text)) {
                    result.append(.html(level: level, alignment: html.alignment, text: html.text))
                } else {
                    result.append(.heading(level, text))
                }
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                result.append(.bullet(String(trimmed.dropFirst(2))))
                continue
            }
            paragraph.append(trimmed)
        }
        if inCode { result.append(.code(codeLines.joined(separator: "\n"))) }
        if inMath { flushMath() }
        flushParagraph()
        return result
    }

    static func isTableSeparator(_ line: String) -> Bool {
        var cells = line.trimmingCharacters(in: .whitespaces)
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells.count >= 2 && cells.allSatisfy {
            $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil
        }
    }

    static func htmlBlock(_ line: String) -> (level: Int?, alignment: MarkdownTextAlignment, text: String)? {
        let pattern = #"^<(p|div|h[1-6])\b([^>]*)>(.*)</\1>\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let source = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: source.length)) else { return nil }
        let name = source.substring(with: match.range(at: 1)).lowercased()
        let attributes = source.substring(with: match.range(at: 2))
        let inner = source.substring(with: match.range(at: 3))
        let alignment: MarkdownTextAlignment
        if attributes.range(of: #"(?i)(text-align\s*:\s*right\b|align\s*=\s*[\"']?right\b)"#, options: .regularExpression) != nil {
            alignment = .trailing
        } else if attributes.range(of: #"(?i)(text-align\s*:\s*center\b|align\s*=\s*[\"']?center\b)"#, options: .regularExpression) != nil {
            alignment = .center
        } else {
            alignment = .leading
        }
        let level = name.first == "h" ? Int(name.dropFirst()) : nil
        return (level, alignment, htmlToMarkdown(inner))
    }

    static func htmlToMarkdown(_ html: String) -> String {
        var text = decodedHTMLEntities(html)
        let replacements = [
            (#"(?i)<br\s*/?>"#, "\n"),
            (#"(?i)</?(b|strong)\b[^>]*>"#, "**"),
            (#"(?i)</?(i|em)\b[^>]*>"#, "*"),
            (#"(?i)</?code\b[^>]*>"#, "`"),
            (#"(?i)</?(s|del)\b[^>]*>"#, "~~"),
        ]
        for (pattern, replacement) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: replacement)
        }
        if let tags = try? NSRegularExpression(pattern: #"</?[A-Za-z][^>]*>"#) {
            text = tags.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodedHTMLEntities(_ text: String) -> String {
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}"]
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "&", let end = text[index...].firstIndex(of: ";") else {
                result.append(text[index])
                index = text.index(after: index)
                continue
            }
            let valueStart = text.index(after: index)
            let entity = String(text[valueStart..<end])
            let replacement: String?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                replacement = UInt32(entity.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init).map(String.init)
            } else if entity.hasPrefix("#") {
                replacement = UInt32(entity.dropFirst(), radix: 10).flatMap(UnicodeScalar.init).map(String.init)
            } else {
                replacement = named[entity.lowercased()]
            }
            if let replacement {
                result += replacement
                index = text.index(after: end)
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return result
    }

    static func imageMarkup(in text: String, wholeLine: Bool) -> (alt: String, url: String)? {
        let chars = Array(text)
        guard let parsed = markdownImage(in: chars, at: 0) else { return nil }
        if wholeLine {
            var end = parsed.end
            while end < chars.count, chars[end].isWhitespace { end += 1 }
            guard end == chars.count else { return nil }
        }
        return (parsed.alt, parsed.url)
    }

    static func markdownImage(in chars: [Character], at i: Int)
        -> (alt: String, url: String, end: Int)? {
        guard i + 1 < chars.count, chars[i] == "!", chars[i + 1] == "[" else { return nil }
        var j = i + 2
        var alt = ""
        while j < chars.count {
            if chars[j] == "\n" { return nil }
            if chars[j] == "]" { break }
            alt.append(chars[j])
            j += 1
        }
        guard j < chars.count, chars[j] == "]" else { return nil }
        j += 1
        guard j < chars.count, chars[j] == "(" else { return nil }
        j += 1
        while j < chars.count, chars[j].isWhitespace { j += 1 }
        var url = ""
        while j < chars.count, chars[j] != ")", !chars[j].isWhitespace {
            url.append(chars[j])
            j += 1
        }
        while j < chars.count, chars[j].isWhitespace { j += 1 }
        if j < chars.count, chars[j] == "\"" {
            j += 1
            while j < chars.count, chars[j] != "\"" { j += 1 }
            guard j < chars.count else { return nil }
            j += 1
            while j < chars.count, chars[j].isWhitespace { j += 1 }
        }
        guard j < chars.count, chars[j] == ")", !url.isEmpty else { return nil }
        return (alt, url, j + 1)
    }

    static func splitInlineMath(_ text: String) -> [InlineMarkdownSegment] {
        var segments: [InlineMarkdownSegment] = []
        var current = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count, chars[i + 1] == "$" {
                current.append("$")
                i += 2
                continue
            }
            if chars[i] == "!", let parsed = markdownImage(in: chars, at: i) {
                if !current.isEmpty {
                    segments.append(.text(current))
                    current = ""
                }
                segments.append(.image(alt: parsed.alt, url: parsed.url))
                i = parsed.end
                continue
            }
            if chars[i] == "$" {
                var j = i + 1
                var content = ""
                var closed = false
                while j < chars.count {
                    if chars[j] == "\\", j + 1 < chars.count, chars[j + 1] == "$" {
                        content.append("$")
                        j += 2
                        continue
                    }
                    if chars[j] == "$" { closed = true; break }
                    content.append(chars[j])
                    j += 1
                }
                let tex = content.trimmingCharacters(in: .whitespaces)
                if closed, !tex.isEmpty {
                    if !current.isEmpty {
                        segments.append(.text(current))
                        current = ""
                    }
                    segments.append(.math(tex))
                    i = j + 1
                    continue
                }
            }
            current.append(chars[i])
            i += 1
        }
        if !current.isEmpty { segments.append(.text(current)) }
        return segments
    }

    static func imageData(url: String, attachments: [String: Data], baseDirectory: URL?) -> Data? {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("attachment:") {
            let raw = String(trimmed.dropFirst("attachment:".count))
            let name = raw.removingPercentEncoding ?? raw
            if let data = attachments[name] { return data }
            return attachments[URL(fileURLWithPath: name).lastPathComponent]
        }
        if trimmed.lowercased().hasPrefix("data:image") {
            guard let comma = trimmed.firstIndex(of: ",") else { return nil }
            return Data(base64Encoded: String(trimmed[trimmed.index(after: comma)...]),
                        options: .ignoreUnknownCharacters)
        }
        if let parsed = URL(string: trimmed),
           let scheme = parsed.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return nil
        }
        let fileURL: URL
        if trimmed.hasPrefix("/") {
            fileURL = URL(fileURLWithPath: trimmed)
        } else if let parsed = URL(string: trimmed), parsed.isFileURL {
            fileURL = parsed
        } else if let baseDirectory {
            fileURL = baseDirectory.appendingPathComponent(trimmed)
        } else {
            return nil
        }
        return try? Data(contentsOf: fileURL)
    }

    static func loadImage(url: String, attachments: [String: Data],
                          baseDirectory: URL?) -> (Data, NSImage)? {
        guard let data = imageData(url: url, attachments: attachments, baseDirectory: baseDirectory),
              let image = NSImage(data: data) else { return nil }
        return (data, image)
    }

    static func dataURI(for data: Data) -> String {
        let mime: String
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            mime = "image/png"
        } else if data.starts(with: [0xFF, 0xD8]) {
            mime = "image/jpeg"
        } else if data.starts(with: [0x47, 0x49, 0x46]) {
            mime = "image/gif"
        } else {
            mime = "image/png"
        }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    static func fileName(for url: String) -> String {
        if url.lowercased().hasPrefix("attachment:") {
            let raw = String(url.dropFirst("attachment:".count))
            return URL(fileURLWithPath: raw.removingPercentEncoding ?? raw).lastPathComponent
        }
        return URL(fileURLWithPath: url).lastPathComponent
    }

    static func inlineAttributed(_ text: String) -> AttributedString {
        if let hit = attributedCache[text] { return hit }
        let clean = htmlToMarkdown(text)
        let attributed = (try? AttributedString(
            markdown: clean,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(clean)
        attributedCache[text] = attributed
        attributedOrder.append(text)
        if attributedOrder.count > 800 { attributedCache[attributedOrder.removeFirst()] = nil }
        return attributed
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownView.inlineAttributed(text))
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 4 : 2)
        case .code(let code):
            Text(code)
                .font(.system(size: monoSize, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: DS.Radius.small).fill(.quaternary))
        case .bullet(let text):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                InlineMathText(source: text, attachments: attachments, baseDirectory: baseDirectory)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .paragraph(let text):
            InlineMathText(source: text, attachments: attachments, baseDirectory: baseDirectory)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .math(let tex):
            DisplayMathView(tex: tex)
        case .image(let alt, let url):
            markdownImageView(alt: alt, url: url)
        case .table(let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: DS.Space.l, verticalSpacing: DS.Space.xs) {
                    ForEach(rows.indices, id: \.self) { rowIndex in
                        GridRow {
                            ForEach(rows[rowIndex].indices, id: \.self) { columnIndex in
                                Text(MarkdownView.inlineAttributed(rows[rowIndex][columnIndex]))
                                    .font(rowIndex == 0 ? .callout.weight(.semibold) : .callout)
                                    .padding(.horizontal, DS.Space.xs)
                                    .padding(.vertical, DS.Space.xxs)
                            }
                        }
                        if rowIndex == 0 { Divider() }
                    }
                }
                .padding(DS.Space.s)
            }
            .background(RoundedRectangle(cornerRadius: DS.Radius.small).fill(.quaternary.opacity(0.5)))
        case .html(let level, let alignment, let text):
            Group {
                if let level {
                    Text(MarkdownView.inlineAttributed(text)).font(headingFont(level))
                } else {
                    InlineMathText(source: text, attachments: attachments, baseDirectory: baseDirectory)
                }
            }
            .frame(maxWidth: .infinity, alignment: frameAlignment(alignment))
        }
    }

    @ViewBuilder
    private func markdownImageView(alt: String, url: String) -> some View {
        if let (data, image) = MarkdownView.loadImage(url: url, attachments: attachments,
                                                      baseDirectory: baseDirectory) {
            ImageOutputView(data: data, image: image, fileName: MarkdownView.fileName(for: url))
                .accessibilityLabel(alt.isEmpty ? MarkdownView.fileName(for: url) : alt)
        } else {
            Text(alt.isEmpty ? url : alt)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 22, weight: .bold)
        case 2: return .system(size: 18, weight: .semibold)
        case 3: return .system(size: 15, weight: .semibold)
        default: return .system(size: 14, weight: .semibold)
        }
    }

    private func frameAlignment(_ alignment: MarkdownTextAlignment) -> Alignment {
        switch alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

}

struct InlineMathText: View {
    let source: String
    var attachments: [String: Data] = [:]
    var baseDirectory: URL? = nil
    private var app: AppState { AppState.shared }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.monoFontSize) private var monoSize
    @State private var rendered: [String: AppState.LatexResult] = [:]

    private var segments: [InlineMarkdownSegment] { MarkdownView.cachedInlineSegments(source) }

    var body: some View {
        composed
            .fixedSize(horizontal: false, vertical: true)
            .onAppear { fetch() }
            .onChange(of: colorScheme) { _, _ in
                rendered = [:]
                fetch()
            }
    }

    private var composed: Text {
        var out = Text(verbatim: "")
        for segment in segments {
            switch segment {
            case .text(let text):
                out = out + Text(MarkdownView.inlineAttributed(text))
            case .math(let tex):
                if case .image(let image, let depth)? = rendered[tex] {
                    out = out + Text(Image(nsImage: image)).baselineOffset(-depth)
                } else {
                    out = out + Text(verbatim: "$\(tex)$")
                        .font(.system(size: monoSize, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            case .image(let alt, let url):
                if let (_, image) = MarkdownView.loadImage(url: url, attachments: attachments,
                                                           baseDirectory: baseDirectory) {
                    out = out + Text(Image(nsImage: image))
                } else {
                    out = out + Text(verbatim: alt.isEmpty ? url : alt)
                        .foregroundStyle(.secondary)
                }
            }
        }
        return out
    }

    private func fetch() {
        for case .math(let tex) in segments {
            if case .image? = rendered[tex] { continue }
            app.renderLatex(tex, display: false, fontSize: 13,
                            colorHex: MathPalette.hex(for: colorScheme)) { result in
                rendered[tex] = result
            }
        }
    }
}

struct DisplayMathView: View {
    let tex: String
    private var app: AppState { AppState.shared }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.monoFontSize) private var monoSize
    @State private var rendered: AppState.LatexResult?

    var body: some View {
        Group {
            switch rendered {
            case .image(let image, _)?:
                Image(nsImage: image)
                    .frame(maxWidth: .infinity, alignment: .center)
            case .failure(let message)?:
                Text(verbatim: "$$\(tex)$$")
                    .font(.system(size: monoSize, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help(message)
            case nil:
                Text(verbatim: "$$\(tex)$$")
                    .font(.system(size: monoSize, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .onAppear { fetch() }
        .onChange(of: colorScheme) { _, _ in
            rendered = nil
            fetch()
        }
    }

    private func fetch() {
        app.renderLatex(tex, display: true, fontSize: 16,
                        colorHex: MathPalette.hex(for: colorScheme)) { result in
            rendered = result
        }
    }

}
