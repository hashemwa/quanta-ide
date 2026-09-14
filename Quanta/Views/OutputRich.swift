import AppKit
import SwiftUI

enum ANSIRenderer {
    private static let palette: [Int: Color] = [
        30: Color(nsColor: .labelColor), 31: .red, 32: .green, 33: .orange,
        34: .blue, 35: .purple, 36: .cyan, 37: Color(nsColor: .secondaryLabelColor),
        90: Color(nsColor: .secondaryLabelColor), 91: .red, 92: .green, 93: .yellow,
        94: .blue, 95: .pink, 96: .teal, 97: Color(nsColor: .labelColor),
    ]

    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString()
        var color: Color?
        var bold = false
        var index = text.startIndex

        func flush(_ chunk: Substring) {
            guard !chunk.isEmpty else { return }
            var piece = AttributedString(String(chunk))
            if let color { piece.foregroundColor = color }
            if bold { piece.inlinePresentationIntent = .stronglyEmphasized }
            result.append(piece)
        }

        while let escape = text.range(of: "\u{1B}[", range: index..<text.endIndex) {
            flush(text[index..<escape.lowerBound])
            guard let end = text[escape.upperBound...].firstIndex(where: { $0.isLetter }) else {
                index = text.endIndex
                break
            }
            if text[end] == "m" {
                let codes = text[escape.upperBound..<end].split(separator: ";").compactMap { Int($0) }
                for code in codes.isEmpty ? [0] : codes {
                    switch code {
                    case 0: color = nil; bold = false
                    case 1: bold = true
                    case 22: bold = false
                    case 39: color = nil
                    default: if let c = palette[code] { color = c }
                    }
                }
            }
            index = text.index(after: end)
        }
        flush(text[index...])
        return result
    }
}

struct StreamOutputView: View {
    let name: String
    let text: String
    @State private var expanded = false
    @Environment(\.monoFontSize) private var monoSize

    private static let collapseThreshold = 40
    private static let tailCount = 15
    private static let warningPattern = try! NSRegularExpression(
        pattern: #"^(.*?):(\d+): (\w*Warning): (.*)$"#)

    private var lineCount: Int {
        var count = 1
        for ch in text.trimmingTrailingNewlines.utf8 where ch == 10 { count += 1 }
        return count
    }

    private func tailLines(_ n: Int) -> [String] {
        let trimmed = text.trimmingTrailingNewlines
        var lines: [String] = []
        var end = trimmed.endIndex
        while lines.count < n, let nl = trimmed[..<end].lastIndex(of: "\n") {
            lines.insert(String(trimmed[trimmed.index(after: nl)..<end]), at: 0)
            end = nl
        }
        if lines.count < n { lines.insert(String(trimmed[..<end]), at: 0) }
        return lines
    }

    var body: some View {
        let count = lineCount
        VStack(alignment: .leading, spacing: 2) {
            if count > Self.collapseThreshold && !expanded {
                Button {
                    expanded = true
                } label: {
                    Label("Show all \(count) lines", systemImage: "chevron.down")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                lineViews(tailLines(Self.tailCount))
            } else {
                lineViews(text.trimmingTrailingNewlines.components(separatedBy: "\n"))
                if count > Self.collapseThreshold {
                    Button {
                        expanded = false
                    } label: {
                        Label("Collapse", systemImage: "chevron.up")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 4)
    }

    private static let maximumChunkLength = 50_000

    static func clipped(_ chunk: String) -> String {
        guard chunk.count > maximumChunkLength else { return chunk }
        let head = String(chunk.prefix(maximumChunkLength))
        return head + "\n… \(chunk.count - head.count) more characters"
    }

    @ViewBuilder
    private func lineViews(_ lines: [String]) -> some View {
        let grouped = Self.groupWarnings(lines, isStderr: name == "stderr")
        ForEach(grouped.indices, id: \.self) { i in
            switch grouped[i] {
            case .text(let chunk):
                Text(ANSIRenderer.attributed(Self.clipped(chunk)))
                    .font(.system(size: monoSize, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .stderrRule(name == "stderr")
            case .warning(let category, let message, let count):
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                    Text(category).fontWeight(.semibold)
                    Text(message).lineLimit(2)
                    if count > 1 {
                        Text("×\(count)")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.primary)
                .padding(DS.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .outputCard(.warning)
                .textSelection(.enabled)
            }
        }
    }

    enum StreamPiece {
        case text(String)
        case warning(category: String, message: String, count: Int)
    }

    static func groupWarnings(_ lines: [String], isStderr: Bool) -> [StreamPiece] {
        guard isStderr else {
            return lines.isEmpty ? [] : [.text(lines.joined(separator: "\n"))]
        }
        var pieces: [StreamPiece] = []
        var textRun: [String] = []
        func flushText() {
            if !textRun.isEmpty {
                pieces.append(.text(textRun.joined(separator: "\n")))
                textRun = []
            }
        }
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if let m = warningPattern.firstMatch(in: line, range: range),
               let catRange = Range(m.range(at: 3), in: line),
               let msgRange = Range(m.range(at: 4), in: line) {
                flushText()
                let category = String(line[catRange])
                let message = String(line[msgRange])
                if case .warning(let c, let msg, let n)? = pieces.last,
                   c == category, msg == message {
                    pieces[pieces.count - 1] = .warning(category: c, message: msg, count: n + 1)
                } else {
                    pieces.append(.warning(category: category, message: message, count: 1))
                }
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty,
                      case .warning? = pieces.last, textRun.isEmpty {
                continue
            } else {
                textRun.append(line)
            }
        }
        flushText()
        return pieces
    }
}

struct TracebackView: View {
    let ename: String
    let evalue: String
    let traceback: String
    let frames: [TraceFrame]
    @Environment(\.monoFontSize) private var monoSize
    @State private var showLibraryFrames = false
    @Environment(\.outputCellID) private var cellID

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(ename): \(evalue)")
                .font(.system(size: monoSize, weight: .semibold, design: .monospaced))
                .foregroundStyle(.red)
            if frames.isEmpty {
                if !traceback.isEmpty {
                    Text(traceback.trimmingTrailingNewlines)
                        .font(.system(size: monoSize - 1, design: .monospaced))
                        .foregroundStyle(.primary)
                }
            } else {
                let libraryCount = frames.filter { !$0.isUser }.count
                if libraryCount > 0 {
                    Button {
                        showLibraryFrames.toggle()
                    } label: {
                        Label("\(libraryCount) library frame\(libraryCount == 1 ? "" : "s")",
                              systemImage: showLibraryFrames ? "chevron.down" : "chevron.right")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                ForEach(frames) { frame in
                    if frame.isUser || showLibraryFrames {
                        frameView(frame)
                    }
                }
            }
        }
        .textSelection(.enabled)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .outputCard(.error)
    }

    private func frameView(_ frame: TraceFrame) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                AppState.shared.navigateTo(file: frame.file, line: frame.line,
                                           cellID: frame.file.hasPrefix("<cell") ? cellID : nil)
            } label: {
            HStack(spacing: 4) {
                Text(frame.file.hasPrefix("<cell") ? "cell" : URL(fileURLWithPath: frame.file).lastPathComponent)
                    .fontWeight(frame.isUser ? .semibold : .regular)
                Text("line \(frame.line)")
                if frame.function != "<module>" {
                    Text("· \(frame.function)")
                }
            }
            .font(.subheadline)
            .foregroundStyle(frame.isUser ? Color.primary : Color.secondary)
            }
            .buttonStyle(.link)
            .help("Go to \(frame.file), line \(frame.line)")
            if !frame.code.isEmpty {
                Text(frame.code)
                    .font(.system(size: monoSize - 1, design: .monospaced))
                    .foregroundStyle(frame.isUser ? Color.primary : Color.secondary)
                    .padding(.leading, 10)
            }
        }
    }
}

struct NDArrayView: View {
    let payload: NDArrayPayload
    @Environment(\.monoFontSize) private var monoSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                badge("ndarray \(payload.shapeLabel)", emphasized: true)
                    .help("shape (\(payload.shape.map(String.init).joined(separator: ", "))) · \(payload.dtype)")
                badge(payload.dtype, emphasized: false)
                    .help("dtype \(payload.dtype)")
                ForEach(["min", "max", "mean", "std"], id: \.self) { key in
                    if let v = payload.stats[key] {
                        badge("\(key) \(Self.compact(v))", emphasized: false)
                            .help("\(key) \(v)")
                    }
                }
            }
            if let series = payload.series {
                SparklineView(values: series)
                    .frame(maxWidth: DS.Layout.outputMaxWidth)
                    .frame(height: 56)
            } else if let grid = payload.grid, let image = Self.heatmapImage(grid) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: DS.Layout.outputMaxWidth, maxHeight: 320, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
            } else {
                Text(payload.text.trimmingTrailingNewlines)
                    .font(.system(size: monoSize, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }

    private func badge(_ text: String, emphasized: Bool) -> some View {
        Text(text)
            .font(.system(size: monoSize - 2, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(emphasized
                ? Color.accentColor.opacity(0.18)
                : Color.secondary.opacity(0.12)))
            .foregroundStyle(emphasized ? Color.accentColor : Color.secondary)
    }

    static func compact(_ v: Double) -> String {
        if abs(v) >= 1000 || (abs(v) < 0.01 && v != 0) {
            return String(format: "%.3g", v)
        }
        return String(format: "%.3f", v)
    }

    static func heatmapImage(_ grid: [[Double?]]) -> NSImage? {
        let height = grid.count
        let width = grid.map(\.count).max() ?? 0
        guard height > 0, width > 0 else { return nil }
        let stops: [(Double, (Double, Double, Double))] = [
            (0.0, (0.267, 0.005, 0.329)), (0.25, (0.229, 0.322, 0.546)),
            (0.5, (0.128, 0.567, 0.551)), (0.75, (0.369, 0.789, 0.383)),
            (1.0, (0.993, 0.906, 0.144)),
        ]
        func colormap(_ t: Double) -> (UInt8, UInt8, UInt8) {
            let t = min(max(t, 0), 1)
            for i in 1..<stops.count where t <= stops[i].0 {
                let (t0, c0) = stops[i - 1]
                let (t1, c1) = stops[i]
                let f = (t - t0) / (t1 - t0)
                return (UInt8((c0.0 + (c1.0 - c0.0) * f) * 255),
                        UInt8((c0.1 + (c1.1 - c0.1) * f) * 255),
                        UInt8((c0.2 + (c1.2 - c0.2) * f) * 255))
            }
            return (253, 231, 37)
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for (y, row) in grid.enumerated() {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if x < row.count, let v = row[x] {
                    let (r, g, b) = colormap(v)
                    pixels[offset] = r
                    pixels[offset + 1] = g
                    pixels[offset + 2] = b
                    pixels[offset + 3] = 255
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(width: width, height: height,
                                    bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                    provider: provider, decode: nil,
                                    shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: width * 4, height: height * 4))
    }
}

struct SparklineView: View {
    let values: [Double?]

    var body: some View {
        Canvas { context, size in
            let finite = values.compactMap { $0 }
            guard finite.count > 1, let lo = finite.min(), let hi = finite.max() else { return }
            let span = hi - lo == 0 ? 1 : hi - lo
            var path = Path()
            var started = false
            for (i, value) in values.enumerated() {
                guard let value else { started = false; continue }
                let x = size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1))
                let y = size.height * (1 - CGFloat((value - lo) / span)) * 0.92 + size.height * 0.04
                if started {
                    path.addLine(to: CGPoint(x: x, y: y))
                } else {
                    path.move(to: CGPoint(x: x, y: y))
                    started = true
                }
            }
            context.stroke(path, with: .color(.accentColor), lineWidth: 1.5)
        }
        .outputCard()
    }
}

struct JSONTreeView: View {
    let payload: JSONTreePayload

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(payload.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            JSONNodeView(key: nil, value: payload.value, depth: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .outputCard()
        .textSelection(.enabled)
    }
}

struct JSONNodeView: View {
    let key: String?
    let value: Any
    let depth: Int
    @State private var expanded: Bool
    @Environment(\.monoFontSize) private var monoSize

    init(key: String?, value: Any, depth: Int) {
        self.key = key
        self.value = value
        self.depth = depth
        _expanded = State(initialValue: depth < 1)
    }

    var body: some View {
        if let dict = value as? [String: Any] {
            containerView(count: dict.count, label: "{…}") {
                ForEach(dict.keys.sorted(), id: \.self) { k in
                    JSONNodeView(key: k, value: dict[k] ?? "", depth: depth + 1)
                }
            }
        } else if let array = value as? [Any] {
            containerView(count: array.count, label: "[…]") {
                ForEach(array.indices, id: \.self) { i in
                    JSONNodeView(key: "\(i)", value: array[i], depth: depth + 1)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 4) {
                keyView
                Text(Self.scalarText(value))
                    .font(.system(size: monoSize, design: .monospaced))
                    .foregroundStyle(Self.scalarColor(value))
            }
        }
    }

    @ViewBuilder
    private var keyView: some View {
        if let key {
            Text("\(key):")
                .font(.system(size: monoSize, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(nsColor: EditorTheme.defName))
        }
    }

    private func containerView<Content: View>(count: Int, label: String,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    keyView
                    Text("\(label) \(count) item\(count == 1 ? "" : "s")")
                        .font(.system(size: monoSize - 1, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help(expanded ? "Collapse \(count) item\(count == 1 ? "" : "s")"
                           : "Expand \(count) item\(count == 1 ? "" : "s")")
            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    content()
                }
                .padding(.leading, 14)
            }
        }
    }

    static func scalarText(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "True" : "False"
        }
        if let s = value as? String { return "\"\(s)\"" }
        return "\(value)"
    }

    static func scalarColor(_ value: Any) -> Color {
        if value is NSNull { return Color(nsColor: EditorTheme.keyword) }
        if let number = value as? NSNumber {
            return Color(nsColor: CFGetTypeID(number) == CFBooleanGetTypeID()
                         ? EditorTheme.keyword : EditorTheme.number)
        }
        if value is String { return Color(nsColor: EditorTheme.string) }
        return .primary
    }
}

struct ObjectCardView: View {
    let payload: ObjectCardPayload
    @Environment(\.monoFontSize) private var monoSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "cube")
                    .foregroundStyle(Color.accentColor)
                Text(payload.title)
                    .font(.system(size: monoSize + 1, weight: .semibold, design: .monospaced))
                Text(payload.subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if !payload.badges.isEmpty {
                HStack(spacing: 4) {
                    Text("fitted:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(payload.badges.prefix(8), id: \.self) { badge in
                        Text(badge)
                            .font(.system(size: monoSize - 2, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.green.opacity(0.15)))
                            .foregroundStyle(.green)
                    }
                }
            }
            let columns = [GridItem(.adaptive(minimum: 190), alignment: .leading)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 3) {
                ForEach(payload.fields, id: \.name) { field in
                    HStack(spacing: 4) {
                        Text(field.name)
                            .foregroundStyle(.secondary)
                        Text("= \(field.value)")
                            .foregroundStyle(.primary)
                    }
                    .font(.system(size: monoSize - 1, design: .monospaced))
                    .lineLimit(1)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .outputCard()
        .textSelection(.enabled)
    }
}
