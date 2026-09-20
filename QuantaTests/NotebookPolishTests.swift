import AppKit
import PDFKit
import WebKit
import XCTest
@testable import Quanta

@MainActor
final class NotebookPolishTests: XCTestCase {
    func testInsertionSelectsRequestedTypeAndPosition() {
        for type in [CellType.code, .markdown] {
            for offset in [0, 1] {
                let app = AppState()
                let first = NotebookCell(type: .code, source: "first")
                let last = NotebookCell(type: .code, source: "last")
                let notebook = Notebook(cells: [first, last], metadata: [:])
                let document = Document(notebook: notebook, url: nil)
                app.openDocuments = [document]
                app.activeDocumentID = document.id
                app.selectedCellID = first.id
                app.isCommandMode = true
                app.commandInsert(offset: offset, type: type)
                let inserted = notebook.cells[offset]
                XCTAssertEqual(inserted.cellType, type)
                XCTAssertEqual(app.selectedCellID, inserted.id)
                XCTAssertEqual(app.scrollRequest, inserted.id)
                XCTAssertEqual(inserted.isEditingMarkdown, type == .markdown)
                XCTAssertTrue(app.isCommandMode)
                XCTAssertTrue(document.isDirty)
                XCTAssertEqual(notebook.cells.last?.id, last.id)
            }
        }
    }

    func testPointerInsertionActivatesCorrectNotebookAndEntersEditing() {
        let app = AppState()
        let cell = NotebookCell(type: .code)
        let notebook = Notebook(cells: [cell], metadata: [:])
        let document = Document(notebook: notebook, url: nil)
        let other = Document(script: nil, text: "")
        app.openDocuments = [document, other]
        app.activeDocumentID = other.id
        app.isCommandMode = true
        app.insertCell(type: .markdown, nextTo: cell, offset: 0, in: notebook, document: document, editing: true)
        XCTAssertEqual(app.activeDocumentID, document.id)
        XCTAssertFalse(app.isCommandMode)
        XCTAssertEqual(app.selectedCellID, notebook.cells[0].id)
    }

    func testOriginalValuesSurvivePagingAndDoNotFallbackToPreviews() throws {
        var payload = try XCTUnwrap(DataFramePayload(dict: [
            "columns": ["value"], "rows": [["short…"]], "index": ["0"],
            "original_rows": [["full\nvalue\twith precision 1.2345678901234567"]], "original_index": ["0"],
        ]))
        let page = try XCTUnwrap(DataFramePayload(dict: [
            "columns": ["value"], "rows": [["huge…"]], "index": ["1"],
            "original_rows": [[NSNull()]], "original_index": ["1"],
        ]))
        payload.appendPage(page)
        XCTAssertEqual(payload.originalValue(row: 0, column: 1), "full\nvalue\twith precision 1.2345678901234567")
        XCTAssertNil(payload.originalValues(rows: [0, 1], columns: [1]))
        XCTAssertNil(payload.originalValue(row: -1, column: 1))
        XCTAssertNil(payload.originalValue(row: 0, column: 10))
    }

    func testMarkdownExportSharesTablesAndRendersSafeOfflineMathAndLinks() {
        let html = NotebookExporter.markdownToHTML(#"""
        | Name | Value |
        | --- | --- |
        | **x** | $\frac{1}{2}$ |

        $$\sum_{i=1}^{n} i$$

        [Reference](https://example.com/?x=1&y=2) and [unsafe](javascript:alert)
        """#)
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("<th>Name</th>"))
        XCTAssertTrue(html.contains("<mfrac>"))
        XCTAssertTrue(html.contains("<math"))
        XCTAssertTrue(html.contains("href=\"https://example.com/?x=1&amp;y=2\""))
        XCTAssertFalse(html.contains("javascript:"))
        XCTAssertFalse(html.contains("$\\frac"))
        let untrusted = NotebookMath.html(#"\href{javascript:alert(1)}{danger}"#, display: false)
        XCTAssertFalse(untrusted.contains("href=\"javascript:"))
    }

    func testExportSanitizesRichHTMLWithoutExecutingItsScripts() async throws {
        let output = CellOutput(kind: .rich(["text/html": "<table><tr><td>kept</td></tr></table><script>document.title='unsafe'</script><img src='https://example.com/tracker' onerror=\"document.title='unsafe'\"><a href='javascript:alert(1)'>link</a>"]))
        let notebook = Notebook(cells: [NotebookCell(type: .code, outputs: [output])], metadata: [:])
        let html = NotebookExporter.html(from: notebook, title: "safe")
        let loaded = expectation(description: "Export loaded")
        let observer = ExportObserver(loaded)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        view.navigationDelegate = observer
        view.loadHTMLString(html, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 15)
        let clean: String? = try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript("await window.quantaExportReady; return document.querySelector('.rich-output').innerHTML;", arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value as? String)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
        XCTAssertTrue(try XCTUnwrap(clean).contains("<td>kept</td>"))
        XCTAssertFalse(clean?.contains("<script") ?? true)
        XCTAssertFalse(clean?.contains("onerror") ?? true)
        XCTAssertFalse(clean?.contains("javascript:") ?? true)
        XCTAssertFalse(clean?.contains("https://example.com/tracker") ?? true)
        XCTAssertEqual(view.title, "safe")
    }

    func testPaginationKeepsRowsAndLinesIntactAndBoundsPageCount() {
        let pages = NotebookPDFRenderer.pageRects(height: 2000, ranges: [950...980, 1890...1920])
        XCTAssertEqual(pages.first?.height, 950)
        XCTAssertEqual(pages.last?.maxY, 2000)
        for index in 1..<pages.count { XCTAssertEqual(pages[index - 1].maxY, pages[index].minY) }
        XCTAssertTrue(NotebookPDFRenderer.pageRects(height: .infinity, ranges: []).isEmpty)
        XCTAssertTrue(NotebookPDFRenderer.pageRects(height: 480_001, ranges: []).isEmpty)
    }

    func testPortableImagesSurviveQuantaSaveAndReopen() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 60,
                                                   bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<60 {
            for x in 0..<120 {
                let pixel = try XCTUnwrap(bitmap.bitmapData).advanced(by: y * bitmap.bytesPerRow + x * 3)
                pixel[0] = x < 60 ? 20 : 240
                pixel[1] = x < 60 ? 90 : 130
                pixel[2] = x < 60 ? 190 : 20
            }
        }
        let jpeg = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:]))
        let bundles: [[String: Any]] = [
            ["image/svg+xml": "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"240\" height=\"80\"><rect width=\"240\" height=\"80\" fill=\"#1256ab\"/><text x=\"20\" y=\"48\" fill=\"white\" font-size=\"20\">Portable SVG</text></svg>"],
            ["image/jpeg": jpeg.base64EncodedString()],
        ]
        let cells = bundles.map { bundle in
            NotebookCell(type: .code, outputs: [CellOutput(kind: RichOutput.kind(bundle), raw: RichOutput.raw(bundle))])
        }
        let notebook = Notebook(cells: cells, metadata: [:])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuantaExportVerification", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("images.ipynb")
        try notebook.serializedData().write(to: url)
        let reopened = try Notebook.load(from: Data(contentsOf: url))
        XCTAssertEqual(reopened.cells.count, 2)
        let svg = reopened.cells[0].outputs[0].raw?["data"] as? [String: Any]
        XCTAssertEqual(RichOutput.text(svg?["image/svg+xml"]), bundles[0]["image/svg+xml"] as? String)
        guard case .image(let bytes, _) = reopened.cells[1].outputs[0].kind else { return XCTFail("Expected JPEG output") }
        XCTAssertEqual(bytes, jpeg)
    }

    func testPDFContainsEveryPageTablesMathAndCompletedPlotly() async throws {
        let markdown = NotebookCell(type: .markdown, source: #"""
        # Notebook export verification
        A portable report with $\frac{1}{2}$ and [a reference](https://example.com).

        | Dataset | Count |
        | --- | --- |
        | Train | 120 |
        | Test | 30 |

        $$\sum_{i=1}^{n} i = \frac{n(n+1)}{2}$$
        """#)
        let rows = (0..<60).map { "<tr><td>Row \($0)</td><td>Measured value \($0)</td></tr>" }.joined()
        let table = CellOutput(kind: .rich(["text/html": "<table><thead><tr><th>Record</th><th>Measurement</th></tr></thead><tbody>\(rows)</tbody></table>"]))
        let figure: [String: Any] = ["data": [["type": "bar", "x": ["A", "B"], "y": [2, 5]]], "layout": ["title": ["text": "Completed Plotly Figure"], "height": 400]]
        let plot = CellOutput(kind: .rich([RichOutput.plotlyMIME: figure]))
        let stream = CellOutput(kind: .stream(name: "stdout", text: (0..<240).map { "Output line \($0)" }.joined(separator: "\n") + "\nFINAL_OUTPUT_MARKER"))
        let code = NotebookCell(type: .code, source: "print('reviewed output')", outputs: [table, plot, stream])
        let notebook = Notebook(cells: [markdown, code], metadata: [:])
        let html = NotebookExporter.html(from: notebook, title: "Export verification")
        let finished = expectation(description: "PDF rendered")
        var result: Data?
        NotebookExporter.renderPDF(html: html) { data in result = data; finished.fulfill() }
        await fulfillment(of: [finished], timeout: 40)
        let data = try XCTUnwrap(result)
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(pdf.pageCount, 3)
        let text = try XCTUnwrap(pdf.string)
        XCTAssertTrue(text.contains("FINAL_OUTPUT_MARKER"))
        XCTAssertTrue(text.contains("Row 59"))
        XCTAssertTrue(text.contains("Completed Plotly Figure"))
        for index in 0..<pdf.pageCount {
            let page = try XCTUnwrap(pdf.page(at: index))
            XCTAssertEqual(page.bounds(for: .mediaBox).width, 612, accuracy: 1)
            XCTAssertEqual(page.bounds(for: .mediaBox).height, 792, accuracy: 1)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuantaExportVerification", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("notebook.pdf"))
        try Data(html.utf8).write(to: directory.appendingPathComponent("notebook.html"))
        try notebook.serializedData().write(to: directory.appendingPathComponent("notebook.ipynb"))
    }

    private final class ExportObserver: NSObject, WKNavigationDelegate {
        let loaded: XCTestExpectation
        init(_ loaded: XCTestExpectation) { self.loaded = loaded }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
    }
}
