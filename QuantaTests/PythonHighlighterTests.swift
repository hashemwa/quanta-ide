import AppKit
import XCTest
@testable import Quanta

@MainActor
final class PythonHighlighterTests: XCTestCase {
    func kind(_ text: String, _ token: String) -> PythonHighlighter.Kind? {
        let range = (text as NSString).range(of: token)
        return PythonHighlighter.tokens(text).last { NSLocationInRange(range.location, $0.range) }?.kind
    }

    func testPythonLexicalContexts() {
        XCTAssertNil(kind("match = 1\ncase = 2", "match"))
        XCTAssertEqual(kind("match value:\n    case 1:", "match"), .keyword)
        XCTAssertNil(kind("a @ matrix", "matrix"))
        XCTAssertEqual(kind("@decorator\ndef print(): pass", "decorator"), .decorator)
        XCTAssertEqual(kind("def print(): pass", "print"), .definition)
        XCTAssertNil(kind("obj.print()", "print"))
        XCTAssertNil(kind("self.value", "self"))
        XCTAssertEqual(kind("number = 1e-3 + 0xFF", "1e-3"), .number)
        XCTAssertEqual(kind("number = 1.0.real", "real"), nil)
        XCTAssertEqual(kind("number = 0x_FF", "FF"), .number)
        XCTAssertEqual(kind("number = 1.e-3j", "e-3j"), .number)
        XCTAssertEqual(kind("f\"value: {len(items):.2f}\"", "len"), .builtin)
        XCTAssertEqual(kind("f\"{row[\"key\"]}\"", "key"), .string)
        XCTAssertEqual(kind("# ''' is a comment\nprint(1)", "print"), .builtin)
    }

    func testIncrementalHighlightMatchesFullHighlightAfterClosingQuoteRemoved() {
        let initial = "value = '''hello\nworld'''\nprint(1)"
        let storage = NSTextStorage(string: initial)
        PythonHighlighter.highlight(storage)
        let range = (initial as NSString).range(of: "'''", options: .backwards)
        storage.replaceCharacters(in: range, with: "")
        PythonHighlighter.highlight(storage, editedRange: NSRange(location: range.location, length: 0))
        let expected = NSTextStorage(string: storage.string)
        PythonHighlighter.highlight(expected)
        for i in 0..<storage.length {
            XCTAssertEqual(storage.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor,
                           expected.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor)
        }
        for source in ["'\\", "'''\\", "f\"{value", "🙂 = 1"] {
            PythonHighlighter.highlight(NSTextStorage(string: source))
        }
    }

}
