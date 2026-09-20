import AppKit

enum PythonHighlighter {
    static let keywords: Set<String> = [
        "def", "class", "if", "elif", "else", "for", "while", "try", "except",
        "finally", "with", "as", "import", "from", "return", "yield", "lambda",
        "pass", "break", "continue", "global", "nonlocal", "del", "raise",
        "assert", "async", "await", "in", "is", "not", "and", "or",
    ]

    static let constants: Set<String> = ["True", "False", "None"]

    static let builtins: Set<String> = [
        "print", "len", "range", "enumerate", "zip", "map", "filter", "sorted",
        "sum", "min", "max", "abs", "round", "open", "input", "type", "isinstance",
        "issubclass", "getattr", "setattr", "hasattr", "dir", "vars", "repr",
        "str", "int", "float", "bool", "list", "tuple", "dict", "set", "frozenset",
        "bytes", "bytearray", "object", "super", "property", "staticmethod",
        "classmethod", "any", "all", "iter", "next", "reversed", "format", "id",
        "hash", "help", "exec", "eval", "callable", "divmod", "pow", "slice",
    ]

    static let stringPrefixes: Set<String> = ["r", "b", "f", "u", "rb", "br", "fr", "rf", "t", "tr", "rt"]

    enum Kind { case keyword, builtin, definition, string, comment, number, decorator }
    struct Token {
        let range: NSRange
        let kind: Kind
    }

    static func highlight(_ storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        let font = EditorTheme.font
        var ranges: [NSRange] = []
        storage.enumerateAttribute(.font, in: full) { value, range, _ in
            if (value as? NSFont) != font { ranges.append(range) }
        }
        storage.beginEditing()
        for range in ranges { storage.addAttribute(.font, value: font, range: range) }
        applyColors(to: storage)
        storage.endEditing()
    }

    static func highlight(_ storage: NSTextStorage, editedRange: NSRange) {
        applyColors(to: storage)
    }

    private static func applyColors(to storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        let desired = NSMutableAttributedString(string: storage.string, attributes: [.foregroundColor: EditorTheme.text])
        for token in tokens(storage.string) {
            desired.addAttribute(.foregroundColor, value: color(token.kind), range: token.range)
        }
        var changes: [(NSRange, NSColor)] = []
        desired.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            guard let color = value as? NSColor else { return }
            storage.enumerateAttribute(.foregroundColor, in: range) { current, subrange, _ in
                if (current as? NSColor) != color { changes.append((subrange, color)) }
            }
        }
        guard !changes.isEmpty else { return }
        storage.beginEditing()
        for (range, color) in changes { storage.addAttribute(.foregroundColor, value: color, range: range) }
        storage.endEditing()
    }

    private static func color(_ kind: Kind) -> NSColor {
        switch kind {
        case .keyword: EditorTheme.keyword
        case .builtin: EditorTheme.builtin
        case .definition: EditorTheme.defName
        case .string: EditorTheme.string
        case .comment: EditorTheme.comment
        case .number: EditorTheme.number
        case .decorator: EditorTheme.decorator
        }
    }

    static func allowsCompletion(in source: String, at offset: Int) -> Bool {
        guard offset > 0, offset <= source.utf16.count else { return false }
        let ns = source as NSString
        return !tokens(source).contains {
            guard $0.kind == .comment || $0.kind == .string || $0.kind == .number else { return false }
            if offset > $0.range.location && offset < NSMaxRange($0.range) { return true }
            guard offset == NSMaxRange($0.range) else { return false }
            if $0.kind == .comment || $0.kind == .number { return true }
            let last = ns.character(at: offset - 1)
            return last != 34 && last != 39
        }
    }

    private static let number = try! NSRegularExpression(pattern:
        #"(?:0[xX]_?[0-9a-fA-F](?:_?[0-9a-fA-F])*|0[bB]_?[01](?:_?[01])*|0[oO]_?[0-7](?:_?[0-7])*|(?:[0-9](?:_?[0-9])*(?:\.(?:[0-9](?:_?[0-9])*)?)?|\.[0-9](?:_?[0-9])*)(?:[eE][+-]?[0-9](?:_?[0-9])*)?[jJ]?)"#)

    static func tokens(_ source: String) -> [Token] {
        Lexer(source).scan()
    }

    private final class Lexer {
        let source: String
        let text: NSString
        let chars: [UInt16]
        var result: [Token] = []
        var i = 0
        var count: Int { chars.count }

        init(_ source: String) { self.source = source; text = source as NSString; chars = Array(source.utf16) }
        func add(_ kind: Kind, _ start: Int, _ end: Int) {
            if end > start { result.append(Token(range: NSRange(location: start, length: end - start), kind: kind)) }
        }
        func ident(_ c: UInt16) -> Bool {
            c == 95 || (65...90).contains(c) || (97...122).contains(c) || c > 127
        }
        func digit(_ c: UInt16) -> Bool { (48...57).contains(c) }
        func word(_ start: Int, _ end: Int) -> String { text.substring(with: NSRange(location: start, length: end - start)) }
        func lineStart(_ start: Int) -> Bool {
            var j = start
            while j > 0, chars[j - 1] != 10, chars[j - 1] != 13 {
                j -= 1
                if chars[j] != 32 && chars[j] != 9 { return false }
            }
            return true
        }
        func softKeyword(_ value: String, _ start: Int) -> Bool {
            guard lineStart(start) else { return false }
            let tail = text.substring(from: i).components(separatedBy: .newlines).first ?? ""
            let trimmed = tail.trimmingCharacters(in: .whitespaces)
            if value == "type" {
                return trimmed.first.map { $0.isLetter || $0 == "_" } == true && trimmed.contains("=")
            }
            return (value == "match" || value == "case") && !trimmed.hasPrefix("=") && trimmed.contains(":")
        }
        func scan() -> [Token] { code(); return result }

        func code(interpolation: Bool = false) {
            var nesting = 0
            var pendingName = false
            var previousDot = false
            while i < count {
                let c = chars[i]
                if interpolation, nesting == 0, c == 125 || c == 58 || c == 33 { return }
                if c == 10 || c == 13 { pendingName = false; previousDot = false; i += 1; continue }
                if c == 32 || c == 9 { i += 1; continue }
                if c == 35 {
                    let start = i
                    while i < count, chars[i] != 10, chars[i] != 13 { i += 1 }
                    add(.comment, start, i); continue
                }
                if c == 34 || c == 39 { string(prefix: "", start: i); previousDot = false; continue }
                if c == 64 && lineStart(i) {
                    let start = i
                    i += 1
                    while i < count, ident(chars[i]) || digit(chars[i]) || chars[i] == 46 { i += 1 }
                    add(.decorator, start, i); continue
                }
                if digit(c) || (c == 46 && i + 1 < count && digit(chars[i + 1])) {
                    if let match = number.firstMatch(in: source, options: .anchored, range: NSRange(location: i, length: count - i)) {
                        add(.number, i, NSMaxRange(match.range)); i = NSMaxRange(match.range); previousDot = false; continue
                    }
                }
                if ident(c) {
                    let start = i
                    while i < count, ident(chars[i]) || digit(chars[i]) { i += 1 }
                    let value = word(start, i)
                    if i < count, chars[i] == 34 || chars[i] == 39, stringPrefixes.contains(value.lowercased()) {
                        string(prefix: value.lowercased(), start: start)
                    } else if pendingName {
                        add(.definition, start, i); pendingName = false
                    } else if keywords.contains(value) || constants.contains(value) || softKeyword(value, start) {
                        add(.keyword, start, i); pendingName = value == "def" || value == "class"
                    } else if !previousDot, builtins.contains(value) { add(.builtin, start, i) }
                    previousDot = false
                    continue
                }
                if c == 40 || c == 91 || c == 123 { nesting += 1 }
                if c == 41 || c == 93 || c == 125 { nesting = max(0, nesting - 1) }
                previousDot = c == 46
                i += 1
            }
        }

        func string(prefix: String, start: Int) {
            let quote = chars[i]
            let triple = i + 2 < count && chars[i + 1] == quote && chars[i + 2] == quote
            let width = triple ? 3 : 1
            let formatted = prefix.contains("f") || prefix.contains("t")
            i += width
            var segment = start
            while i < count {
                if chars[i] == 92 { i = min(count, i + 2); continue }
                if chars[i] == quote, !triple || (i + 2 < count && chars[i + 1] == quote && chars[i + 2] == quote) {
                    i += width; add(.string, segment, i); return
                }
                if !triple && (chars[i] == 10 || chars[i] == 13) { add(.string, segment, i); return }
                if formatted, chars[i] == 123 {
                    if i + 1 < count, chars[i + 1] == 123 { i += 2; continue }
                    add(.string, segment, i + 1)
                    i += 1
                    code(interpolation: true)
                    segment = i
                    if i < count, chars[i] == 33 {
                        i += 1
                        if i < count { i += 1 }
                    }
                    if i < count, chars[i] == 58 {
                        i += 1
                        while i < count, chars[i] != 125 {
                            if chars[i] == 123 {
                                add(.string, segment, i + 1); i += 1
                                code(interpolation: true); segment = i
                                if i < count, chars[i] == 125 { i += 1 }
                            } else { i += 1 }
                        }
                    }
                    if i < count, chars[i] == 125 { i += 1 }
                    continue
                }
                i += 1
            }
            add(.string, segment, i)
        }
    }
}
