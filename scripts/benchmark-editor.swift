import AppKit

@main
struct LexerBenchmark {
    static func main() {
        var checksum = 0
        print("case,median_ms,tokens")
        for size in [500, 2_000, 10_000] {
            let values = (0..<size).map { String($0) }.joined(separator: ", ")
            let lines = (0..<size).map { "x\($0) = \($0)" }.joined(separator: "\n")
            for (label, source) in [("numeric-line-\(size)", "values = [\(values)]\n"), ("multiline-\(size)", lines)] {
                var times: [Double] = []
                var tokenCount = 0
                for repetition in 0..<7 {
                    let text = source + "\nvalue = \(repetition)"
                    let start = CFAbsoluteTimeGetCurrent()
                    let tokens = PythonHighlighter.tokens(text)
                    times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                    tokenCount = tokens.count
                    for token in tokens { checksum &+= token.range.location &+ token.range.length &+ token.kind.rawValue.count }
                }
                print("\(label),\(String(format: "%.3f", times.sorted()[3])),\(tokenCount)")
            }
        }
        let source = (0..<2_000).map { "x\($0) = \($0)" }.joined(separator: "\n")
        var times: [Double] = []
        for repetition in 0..<7 {
            let text = source + "\nvalue = \(repetition)"
            let storage = NSTextStorage(string: text)
            let start = CFAbsoluteTimeGetCurrent()
            #if REUSE_TOKENS
            let tokens = PythonHighlighter.tokens(text)
            PythonHighlighter.highlight(storage, editedRange: NSRange(location: storage.length - 1, length: 1), tokens: tokens)
            checksum &+= PythonHighlighter.allowsCompletion(in: text, at: text.utf16.count - 2, tokens: tokens) ? 1 : 0
            #else
            PythonHighlighter.highlight(storage, editedRange: NSRange(location: storage.length - 1, length: 1))
            checksum &+= PythonHighlighter.allowsCompletion(in: text, at: text.utf16.count - 2) ? 1 : 0
            #endif
            times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        print("highlight-and-completion-2000,\(String(format: "%.3f", times.sorted()[3])),0")
        print("checksum,\(checksum),0")
    }
}
