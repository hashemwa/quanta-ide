import Foundation

enum LocalPythonCompletion {
    private static let identifiers = try! NSRegularExpression(pattern: #"[\p{L}_][\p{L}\p{M}\p{N}_]*"#)
    private static var cache: [String: Set<String>] = [:]
    private static var order: [String] = []
    private static var cacheSize = 0

    static func suggestions(source: String, cursor: Int, context: [String]) -> [CodeCompletion] {
        let length = source.utf16.count
        guard length <= 1_000_000, cursor >= 0, cursor <= length,
              cursor == length || (source as NSString).rangeOfComposedCharacterSequence(at: cursor).location == cursor,
              let headRange = Range(NSRange(location: 0, length: cursor), in: source),
              cursor == 0 || PythonHighlighter.allowsCompletion(in: source, at: cursor) else { return [] }
        let head = source[headRange]
        let prefix = String(head.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" }.reversed())
        let start = cursor - prefix.utf16.count
        if head.dropLast(prefix.count).last == "." { return [] }
        var names = Set<String>()
        var remaining = 2_000_000
        for text in [source] + context {
            remaining -= text.utf16.count
            if remaining < 0 { break }
            names.formUnion(sourceNames(text))
        }
        let python = PythonHighlighter.keywords.union(PythonHighlighter.builtins)
            .union(PythonHighlighter.constants).union(["display", "clear_output", "match", "case"])
        let range = NSRange(location: start, length: cursor - start)
        return Array(names.union(python).filter {
            $0 != prefix && $0.hasPrefix(prefix)
        }.sorted {
            if names.contains($0) != names.contains($1) { return names.contains($0) }
            return $0 < $1
        }.prefix(100)).map { name in
            var completion = CodeCompletion(label: name, range: range)
            completion.detail = names.contains(name) ? "Source name" : "Python"
            completion.kind = PythonHighlighter.keywords.contains(name) ? 14 : 6
            return completion
        }
    }

    private static func sourceNames(_ source: String) -> Set<String> {
        if let cached = cache[source] { return cached }
        guard source.utf16.count <= 1_000_000 else { return [] }
        let ignored = PythonHighlighter.tokens(source).filter { $0.kind == .comment || $0.kind == .string }
            .sorted { $0.range.location < $1.range.location }
        let text = source as NSString
        var index = 0
        var names = Set<String>()
        for match in identifiers.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            while index < ignored.count, NSMaxRange(ignored[index].range) <= match.range.location { index += 1 }
            if index < ignored.count, NSIntersectionRange(ignored[index].range, match.range).length > 0 { continue }
            if match.range.location > 0, text.character(at: match.range.location - 1) == 46 { continue }
            names.insert(text.substring(with: match.range))
        }
        cache[source] = names
        order.append(source)
        cacheSize += source.utf8.count
        while order.count > 400 || cacheSize > 4_000_000 {
            let oldest = order.removeFirst()
            cacheSize -= oldest.utf8.count
            cache[oldest] = nil
        }
        return names
    }
}
