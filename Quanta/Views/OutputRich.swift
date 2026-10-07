import AppKit
import SwiftUI

enum ANSIRenderer {
    private static let palette: [Int: Color] = [
        30: Color(nsColor: .labelColor), 31: .red, 32: .green, 33: .orange,
        34: .blue, 35: .purple, 36: .cyan, 37: Color(nsColor: .secondaryLabelColor),
        90: Color(nsColor: .secondaryLabelColor), 91: .red, 92: .green, 93: .yellow,
        94: .blue, 95: .pink, 96: .teal, 97: Color(nsColor: .labelColor),
    ]

    struct Segment {
        let text: String
        let color: Color?
        let bold: Bool
    }

    static func segments(_ text: String) -> [Segment] {
        var result: [Segment] = []
        var color: Color?
        var bold = false
        var index = text.startIndex

        func flush(_ chunk: Substring) {
            guard !chunk.isEmpty else { return }
            result.append(Segment(text: String(chunk), color: color, bold: bold))
        }

        while let escape = text.range(of: "\u{1B}[", range: index..<text.endIndex) {
            flush(text[index..<escape.lowerBound])
            guard let end = text[escape.upperBound...].firstIndex(where: { $0.isLetter }) else {
                index = text.endIndex
                break
            }
            if text[end] == "m" {
                let raw = text[escape.upperBound..<end].split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
                let codes = raw.isEmpty ? [0] : raw
                var i = 0
                while i < codes.count {
                    let code = codes[i]
                    switch code {
                    case 0: color = nil; bold = false
                    case 1: bold = true
                    case 22: bold = false
                    case 39: color = nil
                    case 38, 48:
                        if i + 2 < codes.count, codes[i + 1] == 5 {
                            if code == 38 { color = indexedColor(codes[i + 2]) }
                            i += 2
                        } else if i + 4 < codes.count, codes[i + 1] == 2 {
                            let values = Array(codes[(i + 2)...(i + 4)])
                            if code == 38, values.allSatisfy({ (0...255).contains($0) }) {
                                color = Color(nsColor: NSColor(hex: values[0] << 16 | values[1] << 8 | values[2]))
                            }
                            i += 4
                        }
                    default: if let c = palette[code] { color = c }
                    }
                    i += 1
                }
            }
            index = text.index(after: end)
        }
        flush(text[index...])
        return result
    }

    private static func indexedColor(_ index: Int) -> Color? {
        guard (0...255).contains(index) else { return nil }
        if index < 16 { return palette[index < 8 ? 30 + index : 90 + index - 8] }
        if index >= 232 {
            let value = 8 + (index - 232) * 10
            return Color(nsColor: NSColor(hex: value << 16 | value << 8 | value))
        }
        let cube = index - 16
        func level(_ value: Int) -> Int { value == 0 ? 0 : 55 + value * 40 }
        return Color(nsColor: NSColor(hex: level(cube / 36) << 16 | level(cube / 6 % 6) << 8 | level(cube % 6)))
    }

    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString()
        for segment in segments(text) {
            var piece = AttributedString(segment.text)
            piece.foregroundColor = segment.color
            if segment.bold { piece.inlinePresentationIntent = .stronglyEmphasized }
            result.append(piece)
        }
        return result
    }

    static func html(_ text: String) -> String {
        guard let light = NSAppearance(named: .aqua) else { return markup(text) }
        var html = ""
        light.performAsCurrentDrawingAppearance { html = markup(text) }
        return html
    }

    private static func markup(_ text: String) -> String {
        segments(text).map { segment in
            var styles: [String] = []
            if let color = segment.color, let rgb = NSColor(color).usingColorSpace(.sRGB) {
                styles.append(String(format: "color:#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                                     Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded())))
            }
            if segment.bold { styles.append("font-weight:600") }
            let escaped = RichOutput.escape(segment.text)
            return styles.isEmpty ? escaped : "<span style=\"\(styles.joined(separator: ";"))\">\(escaped)</span>"
        }.joined()
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
        .padding(.leading, DS.Layout.cellTextInset)
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
                let detail = Self.detail(of: traceback, ename: ename, evalue: evalue)
                if !detail.isEmpty {
                    Text(detail)
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

    static func detail(of traceback: String, ename: String, evalue: String) -> String {
        let text = traceback.trimmingTrailingNewlines
        let header = "\(ename): \(evalue)"
        if text == header { return "" }
        guard text.hasSuffix("\n" + header) else { return text }
        return String(text.dropLast(header.count)).trimmingTrailingNewlines
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
