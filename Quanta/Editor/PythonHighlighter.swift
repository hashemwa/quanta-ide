import AppKit

enum PythonHighlighter {
    static let keywords: Set<String> = [
        "def", "class", "if", "elif", "else", "for", "while", "try", "except",
        "finally", "with", "as", "import", "from", "return", "yield", "lambda",
        "pass", "break", "continue", "global", "nonlocal", "del", "raise",
        "assert", "async", "await", "in", "is", "not", "and", "or", "match", "case",
    ]

    static let constants: Set<String> = ["True", "False", "None", "self", "cls"]

    static let builtins: Set<String> = [
        "print", "len", "range", "enumerate", "zip", "map", "filter", "sorted",
        "sum", "min", "max", "abs", "round", "open", "input", "type", "isinstance",
        "issubclass", "getattr", "setattr", "hasattr", "dir", "vars", "repr",
        "str", "int", "float", "bool", "list", "tuple", "dict", "set", "frozenset",
        "bytes", "bytearray", "object", "super", "property", "staticmethod",
        "classmethod", "any", "all", "iter", "next", "reversed", "format", "id",
        "hash", "help", "exec", "eval", "callable", "divmod", "pow", "slice",
    ]

    static let stringPrefixes: Set<String> = ["r", "b", "f", "u", "rb", "br", "fr", "rf"]

    static func highlight(_ storage: NSTextStorage) {
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        storage.beginEditing()
        defer { storage.endEditing() }
        storage.setAttributes([.font: EditorTheme.font, .foregroundColor: EditorTheme.text],
                              range: full)
        guard full.length > 0 else { return }
        colorize(storage, range: full)
    }

    static func highlight(_ storage: NSTextStorage, editedRange: NSRange) {
        let ns = storage.string as NSString
        guard ns.length > 0 else { return }
        let location = min(editedRange.location, ns.length)
        let paragraph = ns.paragraphRange(for: NSRange(
            location: location, length: min(editedRange.length, ns.length - location)))
        let scope = tripleQuoteScope(ns, around: paragraph)
        storage.beginEditing()
        defer { storage.endEditing() }
        storage.addAttribute(.foregroundColor, value: EditorTheme.text, range: scope)
        colorize(storage, range: scope)
    }

    private static func tripleQuoteScope(_ ns: NSString, around range: NSRange) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        if start > 0 { start = ns.paragraphRange(for: NSRange(location: start - 1, length: 0)).location }
        if end < ns.length { end = NSMaxRange(ns.paragraphRange(for: NSRange(location: end, length: 0))) }
        for marker in ["\"\"\"", "'''"] {
            let before = ns.substring(to: start) as NSString
            var count = 0
            var search = NSRange(location: 0, length: before.length)
            var lastOpen = NSNotFound
            while true {
                let found = before.range(of: marker, options: [], range: search)
                guard found.location != NSNotFound else { break }
                count += 1
                lastOpen = found.location
                let next = NSMaxRange(found)
                guard next < before.length else { break }
                search = NSRange(location: next, length: before.length - next)
            }
            let ahead = NSRange(location: start, length: ns.length - start)
            let markerAhead = ns.range(of: marker, options: [], range: ahead).location != NSNotFound
            if count % 2 == 1, lastOpen != NSNotFound {
                start = min(start, lastOpen)
                end = ns.length
            } else if markerAhead {
                end = ns.length
            }
        }
        return NSRange(location: start, length: end - start)
    }

    private static func colorize(_ storage: NSTextStorage, range: NSRange) {
        let ns = storage.string as NSString
        var chars = [unichar](repeating: 0, count: range.length)
        ns.getCharacters(&chars, range: range)
        let base = range.location
        let n = chars.count
        var i = 0
        var pendingDefName = false

        func setColor(_ color: NSColor, _ start: Int, _ end: Int) {
            guard end > start else { return }
            storage.addAttribute(.foregroundColor, value: color,
                                 range: NSRange(location: base + start, length: end - start))
        }
        func isIdentStart(_ c: unichar) -> Bool {
            (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c == 95 || c > 127
        }
        func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }
        func isIdentCont(_ c: unichar) -> Bool { isIdentStart(c) || isDigit(c) }

        while i < n {
            let c = chars[i]
            if c == 10 { pendingDefName = false; i += 1; continue }
            if c == 35 {
                let start = i
                while i < n && chars[i] != 10 { i += 1 }
                setColor(EditorTheme.comment, start, i)
                continue
            }
            if c == 34 || c == 39 {
                let start = i
                i = scanString(chars, from: i)
                setColor(EditorTheme.string, start, i)
                continue
            }
            if c == 64 {
                let start = i
                i += 1
                while i < n && (isIdentCont(chars[i]) || chars[i] == 46) { i += 1 }
                setColor(EditorTheme.decorator, start, i)
                continue
            }
            if isDigit(c) || (c == 46 && i + 1 < n && isDigit(chars[i + 1])) {
                let start = i
                i += 1
                while i < n {
                    let d = chars[i]
                    if isIdentCont(d) || d == 46 { i += 1; continue }
                    if (d == 43 || d == 45),
                       chars[i - 1] == 101 || chars[i - 1] == 69 { i += 1; continue }
                    break
                }
                setColor(EditorTheme.number, start, i)
                continue
            }
            if isIdentStart(c) {
                let start = i
                while i < n && isIdentCont(chars[i]) { i += 1 }
                if i < n, chars[i] == 34 || chars[i] == 39, i - start <= 2 {
                    let prefix = ns.substring(with: NSRange(location: base + start, length: i - start)).lowercased()
                    if stringPrefixes.contains(prefix) {
                        i = scanString(chars, from: i)
                        setColor(EditorTheme.string, start, i)
                        continue
                    }
                }
                let word = ns.substring(with: NSRange(location: base + start, length: i - start))
                if keywords.contains(word) {
                    setColor(EditorTheme.keyword, start, i)
                    if word == "def" || word == "class" { pendingDefName = true }
                } else if constants.contains(word) {
                    setColor(EditorTheme.keyword, start, i)
                } else if pendingDefName {
                    setColor(EditorTheme.defName, start, i)
                    pendingDefName = false
                } else if builtins.contains(word) {
                    setColor(EditorTheme.builtin, start, i)
                }
                continue
            }
            i += 1
        }
    }

    private static func scanString(_ chars: [unichar], from index: Int) -> Int {
        let n = chars.count
        var i = index
        let quote = chars[i]
        let isTriple = i + 2 < n && chars[i + 1] == quote && chars[i + 2] == quote
        if isTriple {
            i += 3
            while i < n {
                if chars[i] == 92 { i += 2; continue }
                if chars[i] == quote, i + 2 < n, chars[i + 1] == quote, chars[i + 2] == quote {
                    return i + 3
                }
                if chars[i] == quote, i + 2 == n, chars[i + 1] == quote {
                    return n
                }
                i += 1
            }
            return n
        } else {
            i += 1
            while i < n {
                let c = chars[i]
                if c == 92 { i += 2; continue }
                if c == quote { return i + 1 }
                if c == 10 { return i }
                i += 1
            }
            return n
        }
    }
}
