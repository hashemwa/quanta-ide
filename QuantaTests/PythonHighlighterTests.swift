import AppKit
import XCTest
@testable import Quanta

@MainActor
final class PythonLexicalContextTests: XCTestCase {
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

    func testFStringInequalityKeepsItsExpressionColors() {
        let source = "f\"{1 if value != len(items) else 2!r:>{width}}\""
        XCTAssertEqual(kind(source, "len"), .builtin)
        XCTAssertEqual(kind(source, "else"), .keyword)
        XCTAssertEqual(kind(source, "2"), .number)
        XCTAssertNil(kind(source, "!="))
        XCTAssertNil(kind(source, "width"))
        XCTAssertEqual(kind(source, "!r"), .string)
        XCTAssertTrue(PythonHighlighter.allowsCompletion(in: "f'{value != leng", at: 16))
    }

    func testAnnotatedMatchAndCaseNamesAreOrdinaryIdentifiers() {
        let source = "match: str = 'mean'\ncase: int = 2\nmatch sample:\n    case 1:\n        pass"
        XCTAssertNil(kind(source, "match:"))
        XCTAssertNil(kind(source, "case:"))
        XCTAssertEqual(kind(source, "match sample"), .keyword)
        XCTAssertEqual(kind(source, "case 1"), .keyword)
    }

    func testPandasAndNumPyAttributesKeepTheirLexicalContext() {
        let source = "import pandas as pd\nimport numpy as np\n@np.vectorize\ndef center(frame):\n    means = frame.groupby('cohort')['score'].mean()\n    return np.sum(means) / len(means)\nresult = matrix @ matrix.T"
        XCTAssertEqual(kind(source, "import"), .keyword)
        XCTAssertEqual(kind(source, "@np.vectorize"), .decorator)
        XCTAssertEqual(kind(source, "center"), .definition)
        XCTAssertEqual(kind(source, "'cohort'"), .string)
        XCTAssertEqual(kind(source, "return"), .keyword)
        XCTAssertEqual(kind(source, "len"), .builtin)
        XCTAssertNil(kind(source, "sum"))
        XCTAssertNil(kind(source, "matrix"))
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

@MainActor
final class PythonSyntaxContrastTests: XCTestCase {
    private let source = "import numpy as np\n@np.vectorize\ndef scale(value: float):\n    # Keep unavailable values\n    if np.isnan(value):\n        return np.nan\n    return round(value / 100.0, 2)\nprint(f'Rows: {len(values):,}')"

    func testSyntaxIsReadableOnScriptAndNotebookSurfaces() throws {
        let storage = NSTextStorage(string: source)
        PythonHighlighter.highlight(storage)
        XCTAssertEqual(Set(PythonHighlighter.tokens(source).map(\.kind)), Set(PythonHighlighter.Kind.allCases))
        for name: NSAppearance.Name in [.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                let page = components(.textBackgroundColor)
                let well = composite(components(.tertiarySystemFill), over: page)
                storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                    guard let color = value as? NSColor else { XCTFail("Missing source color"); return }
                    for background in [page, well] {
                        XCTAssertGreaterThanOrEqual(contrast(composite(components(color), over: background), background), 4.5,
                                                    "Unreadable syntax at \(range) in \(name.rawValue)")
                    }
                }
            }
        }
    }

    func testIncreaseContrastStrengthensEverySyntaxColor() throws {
        for name: NSAppearance.Name in [.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                let page = components(.textBackgroundColor)
                let well = composite(components(.tertiarySystemFill), over: page)
                for kind in PythonHighlighter.Kind.allCases {
                    let normal = components(EditorTheme.syntaxColor(kind, dark: name == .darkAqua, increasedContrast: false))
                    let increased = components(EditorTheme.syntaxColor(kind, dark: name == .darkAqua, increasedContrast: true))
                    for background in [page, well] {
                        let baseline = contrast(normal, background)
                        XCTAssertGreaterThan(contrast(increased, background), baseline, "Unchanged \(kind) contrast")
                        XCTAssertGreaterThanOrEqual(contrast(increased, background), 4.5)
                    }
                }
            }
        }
    }

    private func components(_ color: NSColor) -> [Double] {
        guard let rgb = color.usingColorSpace(.sRGB) else { XCTFail("Unresolved source color"); return [0, 0, 0, 1] }
        return [Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent), Double(rgb.alphaComponent)]
    }

    private func composite(_ foreground: [Double], over background: [Double]) -> [Double] {
        zip(foreground.prefix(3), background.prefix(3)).map { $0 * foreground[3] + $1 * (1 - foreground[3]) } + [1]
    }

    private func contrast(_ foreground: [Double], _ background: [Double]) -> Double {
        func luminance(_ color: [Double]) -> Double {
            let linear = color.prefix(3).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        let first = luminance(foreground), second = luminance(background)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}
