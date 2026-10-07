import SwiftUI
import UniformTypeIdentifiers

struct OutputListView: View {
    let cell: NotebookCell
    let baseDirectory: URL?
    @State private var outputs: [CellOutput]

    init(cell: NotebookCell, baseDirectory: URL? = nil) {
        self.cell = cell
        self.baseDirectory = baseDirectory
        _outputs = State(initialValue: cell.outputs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(outputs) { output in
                OutputItemView(output: output, baseDirectory: baseDirectory)
            }
        }
        .environment(\.outputCellID, cell.id)
        .padding(.bottom, 2)
        .onReceive(cell.$outputs) { outputs = $0 }
    }
}

struct OutputItemView: View {
    let output: CellOutput
    var baseDirectory: URL? = nil
    @ObservedObject private var presentation = AppState.shared.outputPresentation
    @Environment(\.monoFontSize) private var monoSize

    @ViewBuilder
    var body: some View {
        if !presentation.usesEnhancedDataOutputs, let text = output.enhancedDataText {
            plainResult(text)
        } else {
            formattedOutput
        }
    }

    @ViewBuilder
    private var formattedOutput: some View {
        switch output.kind {
        case .stream(let name, let text):
            StreamOutputView(name: name, text: text)

        case .executeResult(let text):
            plainResult(text)

        case .image(let data, let image):
            if let image {
                ImageOutputView(data: data, image: image)
                    .padding(.leading, DS.Layout.cellTextInset)
            } else {
                Label("Could not decode image output", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, DS.Layout.cellTextInset)
            }

        case .plotlyFigure(let html, let jsPath, let data, let image, let height):
            PlotlyFigureView(html: html, jsPath: jsPath, image: image, imageData: data,
                             height: height, cacheKey: output.id)
                .padding(.leading, DS.Layout.cellTextInset)

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
            if RichOutput.renderedTextMIME(bundle) != nil {
                if let latex = bundle["text/latex"] {
                    DisplayMathView(tex: RichOutput.latexExpression(latex))
                } else {
                    MarkdownView(source: RichOutput.text(bundle["text/markdown"]), baseDirectory: baseDirectory)
                }
            } else {
                RichOutputView(bundle: bundle)
                    .frame(height: DS.Layout.richOutputHeight)
                    .accessibilityLabel("Rich notebook output")
            }

        case .unsupported(let mime):
            Label("Rich output (\(mime)) — not rendered yet, preserved on save",
                  systemImage: "doc.richtext")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, DS.Layout.cellTextInset)
        }
    }

    private func plainResult(_ text: String) -> some View {
        Text(StreamOutputView.clipped(text.trimmingTrailingNewlines))
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
                .accessibilityAction(named: actualSize ? "Fit to Width" : "Actual Size") { actualSize.toggle() }
                .accessibilityAction(named: "Copy Image") { copyImage() }
                .accessibilityAction(named: "Open Image in Window") { PlotWindow.open(image: image) }
                .accessibilityAction(named: "Save Image as PNG…") { savePNG() }
            if let saveError { PlotErrorMessage(message: saveError) }
        }
        .frame(maxWidth: actualSize ? DS.Layout.outputMaxWidth : max(displayWidth, DS.Layout.plotControlsMinWidth), alignment: .leading)
        .plotControls(pinned: actualSize) { controls }
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

    @ViewBuilder
    private var controls: some View {
        IconButton(actualSize ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                   help: actualSize ? "Fit to Width" : "Actual Size",
                   isActive: actualSize) {
            actualSize.toggle()
        }
        IconButton("doc.on.doc", help: "Copy Image") { copyImage() }
        IconButton("macwindow.badge.plus", help: "Open Image in Window (⌥⌘P)") {
            PlotWindow.open(image: image)
        }
        IconButton("square.and.arrow.down", help: "Save Image as PNG…") { savePNG() }
    }

    private func copyImage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
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
    case fencedCode(language: String, source: String)
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
    case code(String)
    case math(String)
    case image(alt: String, url: String)
}

struct StyledMarkdownSegment {
    let content: InlineMarkdownSegment
    let attributes: AttributeContainer
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

    static func accessibilityHeading(_ level: Int) -> AccessibilityHeadingLevel {
        switch level {
        case 1: .h1
        case 2: .h2
        case 3: .h3
        case 4: .h4
        case 5: .h5
        default: .h6
        }
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
        var codeFence: (marker: Character, length: Int)?
        var codeLanguage = ""
        var mathEnd: String?
        var mathEnvironment = false
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
            let tex = mathLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !tex.isEmpty { result.append(.math(tex)) }
            mathLines = []
            mathEnd = nil
            mathEnvironment = false
        }
        func flushCode() {
            let code = codeLines.joined(separator: "\n")
            result.append(codeLanguage.isEmpty ? .code(code) : .fencedCode(language: codeLanguage, source: code))
            codeLines = []
            codeFence = nil
        }

        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var inTable = false
        for (lineIndex, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = codeFence {
                let run = trimmed.prefix(while: { $0 == fence.marker }).count
                if run >= fence.length, trimmed.dropFirst(run).trimmingCharacters(in: .whitespaces).isEmpty {
                    flushCode()
                } else {
                    codeLines.append(line)
                }
                continue
            }
            if let closing = mathEnd {
                let ending = mathEnvironment ? texBeforeComment(trimmed) : trimmed
                if ending.hasSuffix(closing) {
                    mathLines.append(mathEnvironment ? trimmed : String(trimmed.dropLast(closing.count)))
                    flushMath()
                } else {
                    mathLines.append(trimmed)
                }
                continue
            }
            if let marker = trimmed.first, marker == "`" || marker == "~",
               trimmed.prefix(while: { $0 == marker }).count >= 3 {
                flushParagraph()
                inTable = false
                codeFence = (marker, trimmed.prefix(while: { $0 == marker }).count)
                codeLanguage = trimmed.dropFirst(codeFence!.length).split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased() ?? ""
                continue
            }
            if let environment = displayEnvironment(in: trimmed) {
                flushParagraph()
                inTable = false
                let closing = "\\end{\(environment)}"
                mathLines = [trimmed]
                if texBeforeComment(trimmed).hasSuffix(closing) {
                    flushMath()
                } else {
                    mathEnd = closing
                    mathEnvironment = true
                }
                continue
            }
            if trimmed.hasPrefix("$$") || trimmed.hasPrefix(#"\["#) {
                flushParagraph()
                inTable = false
                let closing = trimmed.hasPrefix("$$") ? "$$" : #"\]"#
                let rest = String(trimmed.dropFirst(2))
                if rest.hasSuffix(closing), rest.count >= 2 {
                    mathLines = [String(rest.dropLast(2))]
                    flushMath()
                } else {
                    mathEnd = closing
                    mathLines = rest.isEmpty ? [] : [rest]
                }
                continue
            }
            if let image = imageMarkup(in: trimmed, wholeLine: true) {
                flushParagraph()
                inTable = false
                result.append(.image(alt: image.alt, url: image.url))
                continue
            }
            if let html = htmlBlock(trimmed) {
                flushParagraph()
                inTable = false
                result.append(.html(level: html.level, alignment: html.alignment, text: html.text))
                continue
            }
            let nextIsSeparator = lineIndex + 1 < lines.count && isTableSeparator(lines[lineIndex + 1])
            if trimmed.contains("|"), inTable || nextIsSeparator {
                let cells = tableCells(trimmed)
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
        if codeFence != nil { flushCode() }
        if mathEnd != nil { flushMath() }
        flushParagraph()
        return result
    }

    private static func displayEnvironment(in line: String) -> String? {
        guard line.hasPrefix(#"\begin{"#), let end = line.firstIndex(of: "}") else { return nil }
        let name = String(line[line.index(line.startIndex, offsetBy: 7)..<end])
        let supported: Set<String> = ["equation", "equation*", "align", "align*", "alignat", "alignat*",
                                      "gather", "gather*", "aligned", "alignedat", "gathered", "displaymath"]
        return supported.contains(name) ? name : nil
    }

    private static func texBeforeComment(_ line: String) -> String {
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if character == "%", !escaped {
                return line[..<index].trimmingCharacters(in: .whitespaces)
            }
            escaped = character == "\\" && !escaped
        }
        return line
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let cells = tableCells(line)
        return cells.count >= 2 && cells.allSatisfy {
            $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil
        }
    }

    static func tableCells(_ line: String) -> [String] {
        let chars = Array(line)
        var cells: [String] = []
        var current = ""
        var i = 0
        while i < chars.count {
            if let span = inlineCode(in: chars, at: i) {
                current += String(chars[i..<span.end])
                i = span.end
            } else if let math = inlineMath(in: chars, at: i) {
                current += String(chars[i..<math.end])
                i = math.end
            } else if chars[i] == "\\", i + 1 < chars.count {
                current += String(chars[i...i + 1])
                i += 2
            } else if chars[i] == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                i += 1
            } else {
                current.append(chars[i])
                i += 1
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells
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
        func flush() {
            if !current.isEmpty {
                segments.append(.text(current))
                current = ""
            }
        }
        while i < chars.count {
            if let span = inlineCode(in: chars, at: i) {
                flush()
                segments.append(.code(span.text))
                i = span.end
                continue
            }
            if let math = inlineMath(in: chars, at: i) {
                flush()
                segments.append(.math(math.tex))
                i = math.end
                continue
            }
            if chars[i] == "\\", i + 1 < chars.count, chars[i + 1] == "$" {
                current.append("$")
                i += 2
                continue
            }
            if chars[i] == "\\", i + 1 < chars.count {
                current += String(chars[i...i + 1])
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
            current.append(chars[i])
            i += 1
        }
        if !current.isEmpty { segments.append(.text(current)) }
        return segments
    }

    static func inlineCode(in chars: [Character], at start: Int) -> (text: String, end: Int)? {
        guard chars[start] == "`", start == 0 || chars[start - 1] != "`" else { return nil }
        var begin = start
        while begin < chars.count, chars[begin] == "`" { begin += 1 }
        let length = begin - start
        var i = begin
        while i < chars.count {
            guard chars[i] == "`" else { i += 1; continue }
            let close = i
            while i < chars.count, chars[i] == "`" { i += 1 }
            if i - close == length {
                var text = String(chars[begin..<close]).replacingOccurrences(of: "\n", with: " ")
                if text.hasPrefix(" "), text.hasSuffix(" "), text.contains(where: { $0 != " " }) {
                    text = String(text.dropFirst().dropLast())
                }
                return (text, i)
            }
        }
        return nil
    }

    static func inlineMath(in chars: [Character], at start: Int) -> (tex: String, end: Int)? {
        let parenthesized = chars[start] == "\\" && start + 1 < chars.count && chars[start + 1] == "("
        guard parenthesized || chars[start] == "$" else { return nil }
        let doubleDollar = !parenthesized && start + 1 < chars.count && chars[start + 1] == "$"
        let width = parenthesized || doubleDollar ? 2 : 1
        let begin = start + width
        guard begin < chars.count, parenthesized || doubleDollar || !chars[begin].isWhitespace else { return nil }
        var i = begin
        while i < chars.count, chars[i] != "\n" {
            let closing: Bool
            if parenthesized {
                closing = chars[i] == "\\" && i + 1 < chars.count && chars[i + 1] == ")"
            } else {
                closing = chars[i] == "$" && (!doubleDollar || i + 1 < chars.count && chars[i + 1] == "$")
            }
            if closing {
                guard i > begin, parenthesized || doubleDollar || !chars[i - 1].isWhitespace,
                      parenthesized || i + width == chars.count || !chars[i + width].isNumber else { return nil }
                return (String(chars[begin..<i]), i + width)
            }
            i += chars[i] == "\\" && i + 1 < chars.count ? 2 : 1
        }
        return nil
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
        let leading = text.prefix(while: \.isWhitespace)
        let trailing = text.dropFirst(leading.count).reversed().prefix(while: \.isWhitespace).reversed()
        let clean = String(leading) + htmlToMarkdown(text) + String(trailing)
        let attributed = (try? AttributedString(
            markdown: clean,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(clean)
        attributedCache[text] = attributed
        attributedOrder.append(text)
        if attributedOrder.count > 800 { attributedCache[attributedOrder.removeFirst()] = nil }
        return attributed
    }

    static func styledInlineSegments(_ source: String) -> [StyledMarkdownSegment] {
        var prefix = "QUANTAINLINE"
        while source.contains(prefix) { prefix += "X" }
        var template = ""
        var replacements: [(token: String, content: InlineMarkdownSegment)] = []
        for segment in cachedInlineSegments(source) {
            if case .text(let text) = segment {
                template += text
            } else {
                let token = prefix + String(replacements.count) + "TOKEN"
                replacements.append((token, segment))
                template += token
            }
        }
        let attributed = inlineAttributed(template)
        var result: [StyledMarkdownSegment] = []
        for run in attributed.runs {
            var rest = String(attributed[run.range].characters)
            while !rest.isEmpty {
                let match = replacements.compactMap { replacement in
                    rest.range(of: replacement.token).map { (range: $0, content: replacement.content) }
                }.min { $0.range.lowerBound < $1.range.lowerBound }
                guard let match else {
                    result.append(StyledMarkdownSegment(content: .text(rest), attributes: run.attributes))
                    break
                }
                if match.range.lowerBound > rest.startIndex {
                    result.append(StyledMarkdownSegment(content: .text(String(rest[..<match.range.lowerBound])),
                                                        attributes: run.attributes))
                }
                result.append(StyledMarkdownSegment(content: match.content, attributes: run.attributes))
                rest = String(rest[match.range.upperBound...])
            }
        }
        return result
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            InlineMathText(source: text, attachments: attachments, baseDirectory: baseDirectory,
                           fontSize: headingSize(level))
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 4 : 2)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(Self.accessibilityHeading(level))
        case .code(let code):
            Text(code)
                .font(.system(size: monoSize, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: DS.Radius.small).fill(.quaternary))
        case .fencedCode(let language, let code):
            Text(Self.highlightedCode(code, language: language))
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
                                InlineMathText(source: rows[rowIndex][columnIndex], attachments: attachments,
                                               baseDirectory: baseDirectory)
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
                    InlineMathText(source: text, attachments: attachments, baseDirectory: baseDirectory,
                                   fontSize: headingSize(level))
                        .font(headingFont(level))
                } else {
                    InlineMathText(source: text, attachments: attachments, baseDirectory: baseDirectory)
                }
            }
            .frame(maxWidth: .infinity, alignment: frameAlignment(alignment))
        }
    }

    static func highlightedCode(_ source: String, language: String) -> AttributedString {
        guard ["python", "py", "python3"].contains(language) else { return AttributedString(source) }
        let storage = NSTextStorage(string: source)
        PythonHighlighter.applyColors(to: storage)
        return AttributedString(storage)
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
        .system(size: headingSize(level), weight: level == 1 ? .bold : .semibold)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 22
        case 2: return 18
        case 3: return 15
        default: return 14
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
    var fontSize: CGFloat = 13
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.monoFontSize) private var monoSize
    @StateObject private var rendered = NotebookMathRenderState()

    private var segments: [InlineMarkdownSegment] { MarkdownView.cachedInlineSegments(source) }

    private var request: NotebookMathRequest {
        NotebookMathRequest(expressions: segments.compactMap {
            if case .math(let tex) = $0 { return tex }
            return nil
        }, display: false, fontSize: fontSize, color: MathPalette.hex(for: colorScheme))
    }

    var body: some View {
        composed
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(Text(spoken))
            .task(id: request) { rendered.load(request) }
    }

    private var spoken: String {
        MarkdownView.styledInlineSegments(source).map { segment in
            switch segment.content {
            case .text(let text): text
            case .code(let code): code
            case .math(let tex): tex
            case .image(let alt, _): alt
            }
        }.joined()
    }

    private var composed: Text {
        var out = Text(verbatim: "")
        for segment in MarkdownView.styledInlineSegments(source) {
            let part: Text
            switch segment.content {
            case .text(let text):
                part = Text(AttributedString(text, attributes: segment.attributes))
            case .code(let code):
                part = Text(AttributedString(code, attributes: segment.attributes))
                    .font(.system(size: monoSize, design: .monospaced))
            case .math(let tex):
                if case .image(let image, let depth)? = rendered.results[tex] {
                    part = Text(Image(nsImage: image)).baselineOffset(-depth)
                } else {
                    part = Text(verbatim: "$\(tex)$")
                        .font(.system(size: monoSize, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            case .image(let alt, let url):
                if let (_, image) = MarkdownView.loadImage(url: url, attachments: attachments,
                                                           baseDirectory: baseDirectory) {
                    part = Text(Image(nsImage: image))
                } else {
                    part = Text(verbatim: alt.isEmpty ? url : alt)
                        .foregroundStyle(.secondary)
                }
            }
            out = Text("\(out)\(part)")
        }
        return out
    }

}

struct DisplayMathView: View {
    let tex: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.monoFontSize) private var monoSize
    @StateObject private var rendered = NotebookMathRenderState()

    private var request: NotebookMathRequest {
        NotebookMathRequest(expressions: [tex], display: true, fontSize: 16,
                            color: MathPalette.hex(for: colorScheme))
    }

    var body: some View {
        Group {
            switch rendered.results[tex] {
            case .image(let image, _)?:
                GeometryReader { geometry in
                    ScrollView(.horizontal) {
                        Image(nsImage: image)
                            .frame(minWidth: geometry.size.width, alignment: .center)
                    }
                }
                    .frame(height: image.size.height)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(tex))
        .task(id: request) { rendered.load(request) }
    }

}
