import AppKit
import XCTest
@testable import Quanta

@MainActor
final class NotebookMarkdownRegressionTests: XCTestCase {
    func testNativeInlineRenderingPreservesSpacesAndEmphasisAcrossMathAndCode() {
        let pieces = MarkdownView.styledInlineSegments("Before **bold $x$ and `code` text** after")
        XCTAssertEqual(pieces.map(\.content), [.text("Before "), .text("bold "), .math("x"),
                                              .text(" and "), .code("code"), .text(" text"), .text(" after")])
        for piece in pieces.dropFirst().dropLast() {
            XCTAssertEqual(piece.attributes.inlinePresentationIntent?.contains(.stronglyEmphasized), true)
        }
        XCTAssertNil(pieces.first?.attributes.inlinePresentationIntent)
        XCTAssertNil(pieces.last?.attributes.inlinePresentationIntent)
    }

    func testNativeInlineCodeKeepsLiteralHTMLAndMath() {
        XCTAssertEqual(MarkdownView.styledInlineSegments("Use `<b>$x$</b>` here").map(\.content),
                       [.text("Use "), .code("<b>$x$</b>"), .text(" here")])
        XCTAssertEqual(MarkdownView.styledInlineSegments("QUANTAINLINE0TOKEN $x$").map(\.content),
                       [.text("QUANTAINLINE0TOKEN "), .math("x")])
    }

    func testInlineWhitespaceSurvivesAttributedParsing() {
        XCTAssertEqual(String(MarkdownView.inlineAttributed(" a ").characters), " a ")
        XCTAssertEqual(String(MarkdownView.inlineAttributed("   ").characters), "   ")
    }

    func testCodeSpansKeepMathImagesAndHTMLLiteral() {
        let source = #"Use `$x$` and ``a`$b$`c`` with `<b>literal</b>` and `![x](image.png)`; compute $y$."#
        XCTAssertEqual(MarkdownView.splitInlineMath(source), [
            .text("Use "), .code("$x$"), .text(" and "), .code("a`$b$`c"),
            .text(" with "), .code("<b>literal</b>"), .text(" and "), .code("![x](image.png)"),
            .text("; compute "), .math("y"), .text(".")
        ])
        let html = NotebookExporter.markdownToHTML(source)
        XCTAssertTrue(html.contains("<code>$x$</code>"))
        XCTAssertTrue(html.contains("<code>a`$b$`c</code>"))
        XCTAssertTrue(html.contains("<code>&lt;b&gt;literal&lt;/b&gt;</code>"))
        XCTAssertTrue(html.contains("<code>![x](image.png)</code>"))
        XCTAssertEqual(html.components(separatedBy: "<math").count - 1, 1)
    }

    func testCodeSpanWhitespaceAndUnmatchedBackticks() {
        XCTAssertEqual(MarkdownView.splitInlineMath("`` `x` ``"), [.code("`x`")])
        XCTAssertEqual(MarkdownView.splitInlineMath("`   `"), [.code("   ")])
        XCTAssertEqual(MarkdownView.splitInlineMath("`a\nb`"), [.code("a b")])
        XCTAssertEqual(MarkdownView.splitInlineMath("``unclosed $x$"), [.text("``unclosed "), .math("x")])
    }

    func testExportKeepsEveryCodeSpanInParagraphsWithManyInlineReplacements() {
        let snippets = (0..<24).map { "value_\($0)" }
        let source = snippets.map { "`\($0)`" }.joined(separator: " ")
        let expected = "<p>" + snippets.map { "<code>\($0)</code>" }.joined(separator: " ") + "</p>\n"
        XCTAssertEqual(NotebookExporter.markdownToHTML(source), expected)
    }

    func testCurrencyAndEscapesStayLiteralWhileTeXEscapesSurvive() {
        XCTAssertEqual(MarkdownView.splitInlineMath("Pay $5 or $10 today."), [.text("Pay $5 or $10 today.")])
        XCTAssertEqual(MarkdownView.splitInlineMath(#"Price \$5; $\text{Cost: \$5}$"#),
                       [.text("Price $5; "), .math(#"\text{Cost: \$5}"#)])
        XCTAssertEqual(MarkdownView.splitInlineMath(#"\\$x$"#), [.text(#"\\"#), .math("x")])
    }

    func testBackslashMathDelimitersWorkInPreviewAndExport() {
        XCTAssertEqual(MarkdownView.splitInlineMath(#"Compute \(x^2\) now."#),
                       [.text("Compute "), .math("x^2"), .text(" now.")])
        XCTAssertEqual(MarkdownView.parse("\\[\n\\frac{1}{2}\n\\]"), [.math(#"\frac{1}{2}"#)])
        let html = NotebookExporter.markdownToHTML(#"\[\frac{1}{2}\]"#)
        XCTAssertTrue(html.contains("<mfrac>"))
    }

    func testCodeFenceRequiresTheMatchingCharacterAndLength() {
        XCTAssertEqual(MarkdownView.parse("````python\n```\n$x$\n`````\nAfter"),
                       [.fencedCode(language: "python", source: "```\n$x$"), .paragraph("After")])
        XCTAssertEqual(MarkdownView.parse("~~~python\n```\n$$x$$\n~~~\nAfter"),
                       [.fencedCode(language: "python", source: "```\n$$x$$"), .paragraph("After")])
        XCTAssertEqual(MarkdownView.parse("```\n``` not a closing fence\n```"),
                       [.code("``` not a closing fence")])
    }

    func testTablePipesInsideMathCodeAndEscapesDoNotSplitColumns() {
        let source = "| Expression | Description |\n| --- | --- |\n| $|x|$ | norm |\n| `a|b` | code |\n| a\\|b | literal |"
        XCTAssertEqual(MarkdownView.parse(source), [.table([
            ["Expression", "Description"], ["$|x|$", "norm"], ["`a|b`", "code"], [#"a\|b"#, "literal"]
        ])])
        let html = NotebookExporter.markdownToHTML(source)
        XCTAssertEqual(html.components(separatedBy: "<td>").count - 1, 6)
        XCTAssertTrue(html.contains("<math"))
        XCTAssertTrue(html.contains("<code>a|b</code>"))
        XCTAssertTrue(html.contains("<td>a|b</td>"))
    }

    func testBlockAfterTableEndsItsRows() {
        let source = "| A | B |\n| --- | --- |\n$$x$$\nleft | right"
        XCTAssertEqual(MarkdownView.parse(source), [.table([["A", "B"]]), .math("x"), .paragraph("left | right")])
    }

    func testEquationEditsRejectLateResultsFromAnEarlierRequest() {
        let state = NotebookMathRenderState()
        var completions: [(AppState.LatexResult) -> Void] = []
        state.load(NotebookMathRequest(expressions: ["x", "x"], display: true, fontSize: 16, color: "#000000")) {
            _, _, _, _, completion in completions.append(completion)
        }
        XCTAssertEqual(completions.count, 1)
        state.load(NotebookMathRequest(expressions: ["y"], display: true, fontSize: 16, color: "#000000")) {
            _, _, _, _, completion in completions.append(completion)
        }
        completions[0](.image(NSImage(size: NSSize(width: 10, height: 10)), depth: 0))
        XCTAssertTrue(state.results.isEmpty)
        completions[1](.image(NSImage(size: NSSize(width: 20, height: 10)), depth: 0))
        XCTAssertEqual(Set(state.results.keys), ["y"])
    }

    func testAppearanceChangesRejectOldImagesOfTheSameEquation() {
        let state = NotebookMathRenderState()
        var completions: [(AppState.LatexResult) -> Void] = []
        for color in ["#000000", "#ffffff"] {
            state.load(NotebookMathRequest(expressions: ["x"], display: false, fontSize: 13, color: color)) {
                _, _, _, _, completion in completions.append(completion)
            }
        }
        completions[1](.image(NSImage(size: NSSize(width: 20, height: 10)), depth: 0))
        completions[0](.image(NSImage(size: NSSize(width: 10, height: 10)), depth: 0))
        guard case .image(let image, _) = state.results["x"] else { return XCTFail("Missing rendered image") }
        XCTAssertEqual(image.size.width, 20)
    }
}
