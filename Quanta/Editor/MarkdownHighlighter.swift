import AppKit

enum EditorSourceLanguage {
    case python, markdown, plain
}

enum MarkdownHighlighter {
    private static let patterns: [(NSRegularExpression, PythonHighlighter.Kind)] = [
        (try! NSRegularExpression(pattern: #"(?m)^ {0,3}(?:#{1,6}\s+.*|>\s?|[-*+]\s+|[0-9]+[.)]\s+)"#), .definition),
        (try! NSRegularExpression(pattern: #"!?\[[^\]\n]*\]\([^\)\n]*\)"#), .builtin),
        (try! NSRegularExpression(pattern: #"(?<!\\)(?:\*\*[^*\n]+\*\*|__[^_\n]+__|\*[^*\n]+\*|_[^_\n]+_)"#), .definition),
        (try! NSRegularExpression(pattern: #"(?s)<!--.*?-->"#), .comment),
        (try! NSRegularExpression(pattern: #"(?s)(?<!\\)(?:\$\$.*?\$\$|\\\[.*?\\\]|\\\(.*?\\\))|(?<![\\$])\$[^\s$\n](?:[^$\n]*?[^\s$\n])?\$(?![0-9$])"#), .number),
        (try! NSRegularExpression(pattern: #"\\(?:[A-Za-z]+\*?|[()\[\]])"#), .keyword),
        (try! NSRegularExpression(pattern: #"(`+)(?!`)([^\n]*?[^`])?\1(?!`)"#), .string),
    ]

    static func tokens(_ source: String) -> [PythonHighlighter.Token] {
        let text = source as NSString
        let full = NSRange(location: 0, length: text.length)
        var result = patterns.flatMap { expression, kind in
            expression.matches(in: source, range: full).map { PythonHighlighter.Token(range: $0.range, kind: kind) }
        }
        var fence: (marker: Character, length: Int, language: String, start: Int)?
        var offset = 0
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let run = trimmed.prefix { $0 == trimmed.first }.count
            let range = NSRange(location: offset, length: line.utf16.count)
            if let current = fence {
                if trimmed.first == current.marker, run >= current.length,
                   trimmed.dropFirst(run).trimmingCharacters(in: .whitespaces).isEmpty {
                    appendCode(NSRange(location: current.start, length: offset - current.start),
                               language: current.language, text: text, to: &result)
                    result.append(.init(range: range, kind: .comment))
                    fence = nil
                }
            } else if let marker = trimmed.first, marker == "`" || marker == "~", run >= 3 {
                let language = trimmed.dropFirst(run).split(whereSeparator: \.isWhitespace).first?.lowercased() ?? ""
                fence = (marker, run, language,
                         offset + line.utf16.count + 1)
                result.append(.init(range: range, kind: .comment))
            }
            offset += line.utf16.count + 1
        }
        if let fence, fence.start <= text.length {
            appendCode(NSRange(location: fence.start, length: text.length - fence.start),
                       language: fence.language, text: text, to: &result)
        }
        return result
    }

    private static func appendCode(_ range: NSRange, language: String, text: NSString,
                                   to tokens: inout [PythonHighlighter.Token]) {
        tokens.removeAll { NSIntersectionRange($0.range, range).length > 0 }
        if language == "python" || language == "py" || language == "python3" {
            tokens += PythonHighlighter.tokens(text.substring(with: range)).map {
                .init(range: NSRange(location: range.location + $0.range.location, length: $0.range.length), kind: $0.kind)
            }
        } else {
            tokens.append(.init(range: range, kind: .string))
        }
    }

    static func highlight(_ storage: NSTextStorage, language: EditorSourceLanguage, resetFont: Bool) {
        if resetFont {
            storage.addAttribute(.font, value: EditorTheme.font, range: NSRange(location: 0, length: storage.length))
        }
        PythonHighlighter.applyColors(to: storage, tokens: language == .markdown ? tokens(storage.string) : [])
    }
}
