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
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .outputCard()
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
    @State private var hovering = false

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: displayWidth, maxHeight: DS.Layout.outputMaxHeight,
                   alignment: .leading)
            .accessibilityLabel(accessibilityDescription)
            .overlay(alignment: .topTrailing) { controls }
            .padding(.vertical, 2)
            .scrollAwareHover($hovering)
    }

    private var accessibilityDescription: String {
        let natural = image.size
        guard natural.width > 0, natural.height > 0 else { return "Plot output" }
        return "Plot output, \(Int(natural.width)) by \(Int(natural.height)) pixels"
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
        FloatingToolbar(visible: hovering) {
            IconButton("doc.on.doc", help: "Copy image") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
            }
            IconButton("macwindow.badge.plus", help: "Open in separate window (⇧⌘P)") {
                PlotWindow.open(image: image)
            }
            IconButton("square.and.arrow.down", help: "Save as PNG…") { savePNG() }
        }
        .padding(DS.Space.m)
    }

    private func savePNG() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = [.png]
        if panel.runModal() == .OK, let url = panel.url {
            try? pngData.write(to: url)
        }
    }

    private var pngData: Data {
        if !data.isEmpty { return data }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return data }
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
}

enum InlineMarkdownSegment: Equatable {
    case text(String)
    case math(String)
}

enum MathPalette {
    static func hex(for scheme: ColorScheme) -> String {
        scheme == .dark ? "#E8E8E8" : "#1D1D1F"
    }
}

struct MarkdownView: View {
    let source: String
    var selectable = true
    @Environment(\.monoFontSize) private var monoSize

    private static var parseCache: [String: [MarkdownBlock]] = [:]
    private static var parseOrder: [String] = []

    static func cachedParse(_ source: String) -> [MarkdownBlock] {
        if let hit = parseCache[source] { return hit }
        let parsed = parse(source)
        parseCache[source] = parsed
        parseOrder.append(source)
        if parseOrder.count > 400 { parseCache[parseOrder.removeFirst()] = nil }
        return parsed
    }

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 6) {
            let parsed = MarkdownView.cachedParse(source)
            ForEach(parsed.indices, id: \.self) { i in
                blockView(parsed[i])
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

        for line in source.components(separatedBy: "\n") {
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
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if trimmed.hasPrefix("#") {
                flushParagraph()
                let level = trimmed.prefix(while: { $0 == "#" }).count
                let text = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                result.append(.heading(min(level, 4), text))
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

    static func inlineAttributed(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
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
                .outputCard()
        case .bullet(let text):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                InlineMathText(source: text)
            }
        case .paragraph(let text):
            InlineMathText(source: text)
        case .math(let tex):
            DisplayMathView(tex: tex)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 24, weight: .bold)
        case 2: return .system(size: 20, weight: .semibold)
        case 3: return .system(size: 16, weight: .semibold)
        default: return .system(size: 14, weight: .semibold)
        }
    }
}

struct InlineMathText: View {
    @ObservedObject private var latex = AppState.shared.latex
    let source: String
    private var app: AppState { AppState.shared }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.monoFontSize) private var monoSize
    @State private var rendered: [String: AppState.LatexResult] = [:]

    private var segments: [InlineMarkdownSegment] { MarkdownView.splitInlineMath(source) }

    var body: some View {
        composed
            .onAppear { fetch() }
            .onChange(of: latex.generation) { _, _ in fetch() }
            .onChange(of: colorScheme) { _, _ in
                rendered = [:]
                fetch()
            }
    }

    private var composed: Text {
        var out = Text(verbatim: "")
        for segment in segments {
            switch segment {
            case .text(let s):
                out = out + Text(MarkdownView.inlineAttributed(s))
            case .math(let tex):
                if case .image(let image, let depth)? = rendered[tex] {
                    out = out + Text(Image(nsImage: image)).baselineOffset(-depth)
                } else {
                    out = out + Text(verbatim: "$\(tex)$")
                        .font(.system(size: monoSize, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        return out
    }

    private func fetch() {
        for case .math(let tex) in segments {
            if case .image? = rendered[tex] { continue }
            app.renderLatex(tex, fontSize: 13, colorHex: MathPalette.hex(for: colorScheme)) { result in
                rendered[tex] = result
            }
        }
    }
}

struct DisplayMathView: View {
    @ObservedObject private var latex = AppState.shared.latex
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
        .onChange(of: latex.generation) { _, _ in fetch() }
        .onChange(of: colorScheme) { _, _ in
            rendered = nil
            fetch()
        }
    }

    private func fetch() {
        app.renderLatex(tex, fontSize: 16, colorHex: MathPalette.hex(for: colorScheme)) { result in
            rendered = result
        }
    }
}
