import AppKit
import PDFKit
import SwiftUI
import WebKit
import XCTest
@testable import Quanta

@MainActor
final class NotebookAuditTests: XCTestCase {
    func testCommonTeXAndMboxRenderWithoutUnknownCommands() {
        let expressions = [
            #"\mbox{direct} = \sum_{i=0}^{n-1}\sum_{j=0}^{n-1} A_{ij}"#,
            #"\mbox{staggered} = \sum_{i=0}^{n-1}\sum_{j=0}^{n-1}(-1)^{i+j} A_{ij}"#,
            #"\mbox{cost: \$5 and $x^2$}"#,
            #"\textnormal{tolerance}\quad\textup{upright}\quad\hbox{text}"#,
            #"\begin{displaymath}a=b\end{displaymath}"#,
            #"\frac{1}{\sqrt{2\pi}}\int_{-\infty}^{\infty}e^{-x^2/2}\,dx = 1"#,
            #"\begin{pmatrix}a&b\\c&d\end{pmatrix}"#,
            #"\begin{cases}x^2&x\geq0\\-x&x<0\end{cases}"#,
            #"\begin{aligned}a&=b+c\\d&=e+f\end{aligned}"#,
            #"\underbrace{a+b}_{\text{sum}}\quad\vec{x}\in\mathbb{R}^n"#,
            #"\newcommand{\foo}[1]{\mathbf{#1}}\foo{x}"#,
            #"a=b\tag{1}"#,
        ]
        for expression in expressions {
            let html = NotebookMath.html(expression, display: true)
            XCTAssertTrue(html.contains("<math"), expression)
            XCTAssertFalse(html.contains("math-error"), expression)
            XCTAssertFalse(html.contains("mathcolor=\"#cc0000\""), expression)
        }
        let html = NotebookMath.html(expressions[0], display: true)
        XCTAssertTrue(html.contains("<mtext>direct</mtext>"))
        XCTAssertFalse(NotebookMath.html(#"\foo{x}"#, display: true).contains("<mstyle mathvariant=\"bold\""))
    }

    func testMathCommentsKeepLineBreaksAndParenthesesAllowWhitespace() {
        let source = "$$\nx = 1 % a comment\n+ 2\n$$"
        XCTAssertEqual(MarkdownView.parse(source), [.math("x = 1 % a comment\n+ 2")])
        let html = NotebookExporter.markdownToHTML(source)
        XCTAssertTrue(html.contains("<mn>2</mn>"))
        XCTAssertEqual(MarkdownView.splitInlineMath(#"Value \( x^2 \) and $$ y^2 $$."#),
                       [.text("Value "), .math(" x^2 "), .text(" and "), .math(" y^2 "), .text(".")])
    }

    func testBareEquationEnvironmentsAndPythonFencesMatchPreviewAndExport() {
        let math = #"\begin{align}a&=b\\c&=d\end{align}"#
        XCTAssertEqual(MarkdownView.parse(math), [.math(math)])
        let html = NotebookExporter.markdownToHTML(math + "\n\n```python\nimport math\nprint(2)\n```")
        XCTAssertTrue(html.contains("<mtable"))
        XCTAssertTrue(html.contains("syntax-keyword\">import</span>"))
        XCTAssertTrue(html.contains("syntax-builtin\">print</span>"))
        XCTAssertFalse(html.contains("math-error"))
    }

    func testEquationEnvironmentClosingCommentsKeepFollowingMarkdownSeparate() {
        let equation = "\\begin{align}\nx &= 1 % keep the line break\n\\end{align} % finished"
        XCTAssertEqual(MarkdownView.parse(equation + "\n\nAfter the equation."),
                       [.math(equation), .paragraph("After the equation.")])
        let inline = #"\begin{equation}x=1\end{equation} % finished"#
        XCTAssertEqual(MarkdownView.parse(inline + "\nAfter"), [.math(inline), .paragraph("After")])
        let comment = "\\begin{align}\nx &= 1 % \\end{align}\n+ 2\n\\end{align}"
        XCTAssertEqual(MarkdownView.parse(comment), [.math(comment)])
        let html = NotebookExporter.markdownToHTML(equation + "\n\nAfter the equation.")
        XCTAssertTrue(html.contains("<p>After the equation.</p>"))
        XCTAssertFalse(html.contains("math-error"))
    }

    func testWindowsLineEndingsCloseMarkdownFencesEquationsAndTables() {
        let source = "```python\r\nprint(2)\r\n```\r\n\r\n$$\r\nx=2\r\n$$\r\n\r\n| Name | Value |\r\n| --- | --- |\r\n| count | 2 |\r\n\r\nAfter"
        XCTAssertEqual(MarkdownView.parse(source), [
            .fencedCode(language: "python", source: "print(2)"), .math("x=2"),
            .table([["Name", "Value"], ["count", "2"]]), .paragraph("After")
        ])
        let tokens = MarkdownHighlighter.tokens(source)
        XCTAssertTrue(tokens.contains { $0.kind == .builtin && (source as NSString).substring(with: $0.range) == "print" })
        let after = (source as NSString).range(of: "After")
        XCTAssertFalse(tokens.contains { NSIntersectionRange($0.range, after).length > 0 })
    }

    func testStreamColorsSurviveSaveReopenAndExportWithoutControlCodes() throws {
        let text = "\u{1B}[1;31mred <value>\u{1B}[0m normal \u{1B}[38;2;18;52;86mrgb\u{1B}[0m \u{1B}[38;5;46mgreen\u{1B}[0m"
        let output = CellOutput(kind: .stream(name: "stdout", text: text))
        let notebook = Notebook(cells: [NotebookCell(type: .code, outputs: [output])], metadata: [:])
        let reopened = try Notebook.load(from: notebook.serializedData())
        guard case .stream(_, let saved) = reopened.cells[0].outputs[0].kind else { return XCTFail("Missing stream") }
        XCTAssertEqual(saved, text)
        let html = NotebookExporter.html(from: reopened, title: "Colors")
        XCTAssertTrue(html.contains("red &lt;value&gt;"))
        XCTAssertTrue(html.contains("font-weight:600"))
        XCTAssertTrue(html.contains("color:#123456"))
        XCTAssertTrue(html.contains("color:#00FF00"))
        XCTAssertFalse(html.contains("\u{1B}"))
        XCTAssertEqual(String(ANSIRenderer.attributed(text).characters), "red <value> normal rgb green")
    }

    func testLaTeXAndMarkdownOutputBundlesRenderAndRoundTrip() throws {
        for bundle in [["text/latex": #"$\mbox{result}=\frac{1}{2}$"#, "text/plain": "fallback"],
                       ["text/markdown": "# Result\nThe value is $x^2$", "text/plain": "fallback"]] {
            let output = CellOutput(kind: RichOutput.kind(bundle), raw: RichOutput.raw(bundle))
            guard case .rich = output.kind else { return XCTFail("Expected rich math/Markdown output") }
            let notebook = Notebook(cells: [NotebookCell(type: .code, outputs: [output])], metadata: [:])
            let loaded = try Notebook.load(from: notebook.serializedData())
            XCTAssertEqual(loaded.cells[0].outputs[0].raw?["data"] as? [String: String], bundle)
            let html = NotebookExporter.html(from: loaded, title: "Result")
            XCTAssertTrue(html.contains("<math"))
            XCTAssertFalse(html.contains("math-error"))
            XCTAssertFalse(html.contains("mathcolor=\"#cc0000\""))
        }
    }

    func testFormulaSnapshotAndPaginatedExportHaveReadableContent() async throws {
        let formula = #"\mbox{direct} = \sum_{i=0}^{n-1}\sum_{j=0}^{n-1} A_{ij},\qquad\mbox{staggered} = \sum_{i=0}^{n-1}\sum_{j=0}^{n-1}(-1)^{i+j}A_{ij}"#
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/notebook-audit", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshotReady = expectation(description: "Formula snapshot")
        var formulaImage: NSImage?
        NotebookMathRenderer.shared.render(formula, display: true, fontSize: 16, color: "#1d1d1f") { image, _, error in
            XCTAssertNil(error)
            formulaImage = image
            snapshotReady.fulfill()
        }
        await fulfillment(of: [snapshotReady], timeout: 15)
        let image = try XCTUnwrap(formulaImage)
        XCTAssertGreaterThan(image.size.width, 300)
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("formula.png"))
        let table = "| Name | Value |\n| --- | --- |\n" + (0..<65).map { "| row \($0) | $x_{\($0)}$ |" }.joined(separator: "\n")
        let wide = (0..<45).map { "x_{\($0)}" }.joined(separator: "+") + #"=\mbox{WIDEEND}"#
        let markdown = NotebookCell(type: .markdown, source: "# Export audit\n**Problem 2.** Matrix sums.\n\n$$\n\(formula)\n$$\n\n```python\nimport math\nprint('highlighted fence')\n```\n\n$$\(wide)$$\n\n" + table)
        let stream = CellOutput(kind: .stream(name: "stdout", text: "\u{1B}[38;2;18;52;86mcolored output\u{1B}[0m\n"))
        let latexBundle = ["text/latex": #"\begin{pmatrix}1&2\\3&4\end{pmatrix}"#]
        let latex = CellOutput(kind: RichOutput.kind(latexBundle), raw: RichOutput.raw(latexBundle))
        let result = CellOutput(kind: .executeResult(text: "{'model': 'ExampleModel',\n 'alpha': 0.5}"))
        let code = NotebookCell(type: .code, source: "import math\nvalue = 42\nprint(f'result: {value}')",
                                outputs: [stream, latex, result])
        let notebook = Notebook(cells: [markdown, code], metadata: [:])
        let html = NotebookExporter.html(from: notebook, title: "Export audit")
        try html.write(to: directory.appendingPathComponent("export.html"), atomically: true, encoding: .utf8)
        let ready = expectation(description: "HTML loaded")
        let observer = LoadObserver(ready)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 1000))
        web.navigationDelegate = observer
        web.loadHTMLString(html, baseURL: nil)
        await fulfillment(of: [ready], timeout: 15)
        let htmlReady = expectation(description: "HTML prepared")
        var result: [String: Any]?
        web.callAsyncJavaScript("""
        await window.quantaExportReady;
        return {math:document.querySelectorAll('math').length,
          rows:document.querySelectorAll('tbody tr').length,
          code:document.querySelectorAll('.syntax-keyword').length,
          text:document.body.innerText};
        """, arguments: [:], in: nil, in: .page) { response in
            if case .success(let value) = response { result = value as? [String: Any] }
            else { XCTFail("HTML preparation failed: \(response)") }
            htmlReady.fulfill()
        }
        await fulfillment(of: [htmlReady], timeout: 15)
        XCTAssertEqual(result?["math"] as? Int, 68)
        XCTAssertEqual(result?["rows"] as? Int, 65)
        XCTAssertGreaterThan(result?["code"] as? Int ?? 0, 1)
        XCTAssertTrue((result?["text"] as? String)?.contains("colored output") == true)
        let pdfReady = expectation(description: "PDF exported")
        var pdfData: Data?
        NotebookExporter.renderPDF(html: html) { pdfData = $0; pdfReady.fulfill() }
        await fulfillment(of: [pdfReady], timeout: 40)
        let bytes = try XCTUnwrap(pdfData)
        try bytes.write(to: directory.appendingPathComponent("export.pdf"))
        let pdf = try XCTUnwrap(PDFDocument(data: bytes))
        XCTAssertGreaterThan(pdf.pageCount, 1)
        XCTAssertTrue(pdf.string?.contains("row 64") == true)
        XCTAssertTrue(pdf.string?.contains("colored output") == true)
        XCTAssertTrue(pdf.string?.contains("highlighted fence") == true)
        let fence = try XCTUnwrap(pdf.findString("import math", withOptions: []).first)
        let fencePage = try XCTUnwrap(fence.pages.first)
        XCTAssertLessThanOrEqual(fence.bounds(for: fencePage).minX, 55)
        for index in 0..<pdf.pageCount {
            let text = pdf.page(at: index)?.string ?? ""
            if text.contains("row ") { XCTAssertTrue(text.contains("Name")) }
        }
        XCTAssertTrue(pdf.string?.contains("'alpha': 0.5") == true)
        let wideSelection = try XCTUnwrap(pdf.findString("WIDEEND", withOptions: []).first)
        let widePage = try XCTUnwrap(wideSelection.pages.first)
        XCTAssertLessThanOrEqual(wideSelection.bounds(for: widePage).maxX, 577)
    }

    func testMarkdownEditorUsesMarkdownColorsAndDoesNotRequestPythonCompletions() throws {
        let source = "# Heading\nThis is a normal paragraph with import and print.\n**Bold** and `print` with $\\alpha$\n```python title=\"sample\"\nimport math\nprint(2)\n```"
        let cell = NotebookCell(type: .markdown, source: source)
        let document = Document(notebook: Notebook(cells: [cell], metadata: [:]), url: nil)
        let editor = CodeEditorFactory.makeTextView()
        editor.string = source
        editor.bindCodeTools(document: document, sourceID: cell.id, isPython: false)
        editor.highlightSource()
        let storage = try XCTUnwrap(editor.textStorage)
        func color(_ value: String) -> NSColor? {
            storage.attribute(.foregroundColor, at: (source as NSString).range(of: value).location,
                              effectiveRange: nil) as? NSColor
        }
        XCTAssertEqual(color("# Heading"), EditorTheme.defName)
        XCTAssertEqual(color("import and print"), EditorTheme.text)
        XCTAssertEqual(color("`print`"), EditorTheme.string)
        XCTAssertEqual(color(#"\alpha"#), EditorTheme.keyword)
        XCTAssertEqual(color("import math"), EditorTheme.keyword)
        var requests = 0
        editor.completionProvider = { _, _, _ in requests += 1 }
        editor.requestCompletions()
        XCTAssertEqual(requests, 0)
        XCTAssertNotNil(editor.inlineCompletionController)
        editor.string = "Result:"
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "Result:\n")
        XCTAssertFalse(editor.requestDocumentation())
    }

    func testMarkdownCopilotUsesAnIsolatedMarkdownDocument() throws {
        let code = NotebookCell(type: .code, source: "secret_data = 42")
        let markdown = NotebookCell(type: .markdown, source: "The result is ")
        let other = NotebookCell(type: .markdown, source: "Other notes")
        let document = Document(notebook: Notebook(cells: [code, markdown, other], metadata: [:]),
                                url: URL(fileURLWithPath: "/tmp/demo.ipynb"))
        let snapshot = try XCTUnwrap(CopilotDocumentSnapshot(document: document, sourceID: markdown.id,
                                                            source: markdown.source, caret: markdown.source.utf16.count))
        XCTAssertEqual(snapshot.languageID, "markdown")
        XCTAssertTrue(snapshot.uri.hasSuffix(".md"))
        XCTAssertEqual(snapshot.text, markdown.source)
        XCTAssertEqual(snapshot.cellRange.location, 0)
        XCTAssertNotNil(snapshot.suggestion(from: ["insertText": "a sum."], revision: 0))
        let second = try XCTUnwrap(CopilotDocumentSnapshot(document: document, sourceID: other.id,
                                                          source: other.source, caret: 0))
        XCTAssertNotEqual(snapshot.uri, second.uri)
        code.cellType = .raw
        XCTAssertNil(CopilotDocumentSnapshot(document: document, sourceID: code.id, source: code.source, caret: 0))
    }

    func testClickingAnAlreadySelectedFileReopensItsClosedTab() throws {
        let url = URL(fileURLWithPath: "/tmp/quanta-reopen/example.py")
        let node = FileNode(url: url, name: "example.py", isDirectory: false, children: nil)
        let root = FileNode(url: url.deletingLastPathComponent(), name: "quanta-reopen", isDirectory: true, children: [node])
        var selection: Set<URL> = [url]
        let parent = NavigatorOutline(root: root, children: [node], selection: Binding(
            get: { selection }, set: { selection = $0 }), filtering: false)
        let coordinator = NavigatorOutline.Coordinator(parent)
        coordinator.root = coordinator.makeItem(root, parent: nil)
        let outline = ClickedOutline()
        outline.addTableColumn(NSTableColumn(identifier: .init("files")))
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.reloadData()
        outline.expandItem(coordinator.root)
        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        var opened: [URL] = []
        coordinator.openFile = { opened.append($0) }
        coordinator.openClickedFile(outline)
        coordinator.openClickedFile(outline)
        XCTAssertEqual(opened, [url, url])
    }

    func testNotebookWindowResizeKeepsVisibleCellsBoundedAndRecordsTiming() throws {
        let cells = (0..<400).map { index in
            index % 3 == 0
                ? NotebookCell(type: .markdown, source: "## Section \(index)\n" + String(repeating: "Explanation of the data. ", count: 15))
                : NotebookCell(type: .code, source: String(repeating: "print('some code')\n", count: 6))
        }
        let notebook = Notebook(cells: cells, metadata: [:])
        let document = Document(notebook: notebook, url: nil)
        let canvas = NotebookCanvas(document: document, notebook: notebook, monoFontSize: 12)
        let view = canvas.view
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        for _ in 0..<12 { RunLoop.current.run(until: Date().addingTimeInterval(0.03)); view.layoutSubtreeIfNeeded() }
        var times: [Double] = []
        for width in [1100, 700, 1000, 750, 1200, 850] {
            let start = ProcessInfo.processInfo.systemUptime
            window.setContentSize(NSSize(width: width, height: 700))
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            view.layoutSubtreeIfNeeded()
            times.append(ProcessInfo.processInfo.systemUptime - start)
            XCTAssertLessThan(canvas.realizedCellCount, 80)
            XCTAssertGreaterThan(canvas.realizedCellCount, 0)
        }
        for _ in 0..<2 {
            window.zoom(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            view.layoutSubtreeIfNeeded()
            XCTAssertLessThan(canvas.realizedCellCount, 80)
            XCTAssertGreaterThan(canvas.realizedCellCount, 0)
        }
        print("Notebook resize timings (seconds): \(times)")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap((view as? NSScrollView)?.documentView).frame.height, view.bounds.height)
    }

    func testPDFContinuationHeadersReserveSpaceWithoutLosingRows() {
        let table = NotebookPDFRenderer.TableLayout(header: CGRect(x: 0, y: 0, width: 720, height: 30), bottom: 2500)
        let rows = stride(from: 30.0, to: 2490.0, by: 30).map { $0...($0 + 30) }
        let pages = NotebookPDFRenderer.pageLayouts(height: 2500, ranges: rows, tables: [table])
        XCTAssertEqual(pages.count, 3)
        XCTAssertNil(pages[0].header)
        XCTAssertEqual(pages[1].header, table.header)
        XCTAssertEqual(pages[2].header, table.header)
        for page in pages { XCTAssertLessThanOrEqual(page.rect.height + (page.header?.height ?? 0), 960) }
        for (first, second) in zip(pages, pages.dropFirst()) { XCTAssertEqual(first.rect.maxY, second.rect.minY) }
        XCTAssertEqual(pages.last?.rect.maxY, 2500)
    }

    private final class ClickedOutline: NSOutlineView {
        override var clickedRow: Int { 1 }
    }

    private final class LoadObserver: NSObject, WKNavigationDelegate {
        let loaded: XCTestExpectation
        init(_ loaded: XCTestExpectation) { self.loaded = loaded }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
    }
}
