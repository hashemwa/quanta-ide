import AppKit
import PDFKit
import WebKit
import XCTest
@testable import Quanta

@MainActor
final class NotebookSyntaxExportTests: XCTestCase {
    func testOperatorsStayNeutralOutsideStringsAndComments() {
        let source = "value += a ** 2 // 3 @ matrix\nvalid = a != b and a <= b\ntext = '+'\n# +"
        let storage = NSTextStorage(string: source)
        PythonHighlighter.highlight(storage)
        for token in ["+=", "**", "//", "@", "!=", "<="] {
            let range = (source as NSString).range(of: token)
            XCTAssertEqual(storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor, EditorTheme.text)
        }
        XCTAssertEqual(storage.attribute(.foregroundColor, at: (source as NSString).range(of: "and").location,
                                         effectiveRange: nil) as? NSColor, EditorTheme.keyword)
    }

    func testHTMLPreservesSourceEscapesAndNestedFStringColors() async throws {
        let source = "import math\nvalue = 42\nprint(f'π < {len(\"🙂\")} > &')\ntext = '</pre><script>bad()</script>'"
        let notebook = Notebook(cells: [NotebookCell(type: .code, source: source)], metadata: [:])
        let html = NotebookExporter.html(from: notebook, title: "Syntax verification")
        XCTAssertTrue(html.contains("class=\"syntax-keyword\">import</span>"))
        XCTAssertTrue(html.contains("class=\"syntax-builtin\">len</span>"))
        XCTAssertTrue(html.contains("&lt;/pre&gt;&lt;script&gt;"))
        let view = WKWebView()
        view.appearance = NSAppearance(named: .darkAqua)
        let loaded = expectation(description: "Syntax export loaded")
        let observer = Observer(loaded)
        view.navigationDelegate = observer
        view.loadHTMLString(html, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 15)
        let text = try await view.evaluateJavaScript("document.querySelector('.code').textContent") as? String
        XCTAssertEqual(text, source)
        let colors = try await view.evaluateJavaScript("""
        (() => {
          const token = document.querySelector('.syntax-keyword');
          const dark = matchMedia('(prefers-color-scheme: dark)').matches;
          const screen = getComputedStyle(token).color;
          document.documentElement.dataset.quantaPrint = 'true';
          return {dark, screen, print: getComputedStyle(token).color};
        })()
        """) as? [String: Any]
        XCTAssertEqual(colors?["screen"] as? String, (colors?["dark"] as? Bool == true) ? "rgb(252, 95, 163)" : "rgb(155, 35, 147)")
        XCTAssertEqual(colors?["print"] as? String, "rgb(155, 35, 147)")
    }

    func testPDFRendersSyntaxColorsAndPreservesText() async throws {
        let source = "import math\nvalue = 42\nprint('syntax colors')"
        let notebook = Notebook(cells: [NotebookCell(type: .code, source: source)], metadata: [:])
        let html = NotebookExporter.html(from: notebook, title: "Syntax colors")
        let rendered = expectation(description: "Syntax PDF rendered")
        var result: Data?
        NotebookExporter.renderPDF(html: html) { result = $0; rendered.fulfill() }
        await fulfillment(of: [rendered], timeout: 40)
        let data = try XCTUnwrap(result)
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertTrue(pdf.string?.contains("syntax colors") == true)
        let page = try XCTUnwrap(pdf.page(at: 0))
        let image = page.thumbnail(of: NSSize(width: 612, height: 792), for: .mediaBox)
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        var coloredPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent > 0.35, color.blueComponent > 0.3,
                   color.greenComponent < min(color.redComponent, color.blueComponent) * 0.65 {
                    coloredPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(coloredPixels, 15)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuantaSyntaxExportVerification", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("syntax.pdf"))
        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("syntax.png"))
    }

    private final class Observer: NSObject, WKNavigationDelegate {
        let loaded: XCTestExpectation
        init(_ loaded: XCTestExpectation) { self.loaded = loaded }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
    }
}
