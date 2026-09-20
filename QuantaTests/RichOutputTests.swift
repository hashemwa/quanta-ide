import AppKit
import WebKit
import XCTest
@testable import Quanta

@MainActor
final class RichOutputTests: XCTestCase {
    func testLivePlotlyFallsBackToBundledRendererAndPopoutsStayOffline() throws {
        let path = try XCTUnwrap(PlotlyWebView.availableScriptPath("/missing-environment/plotly.min.js"))
        XCTAssertEqual(path, RichOutput.bundledPlotlyPath)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: path))
        let document = PlotlyWebView.document(html: "<div></div>", script: "const text = '</script>';", fillsWindow: true)
        XCTAssertTrue(document.contains("default-src 'none'"))
        XCTAssertTrue(document.contains("form-action 'none'"))
        XCTAssertFalse(document.contains("const text = '</script>'"))
    }

    func testUnsupportedOutputExportContainsAnExplicitPlaceholder() {
        let bundle: [String: Any] = ["application/vnd.example+json": ["value": 1]]
        let output = CellOutput(kind: RichOutput.kind(bundle), raw: RichOutput.raw(bundle))
        let notebook = Notebook(cells: [NotebookCell(type: .code, outputs: [output])], metadata: [:])
        let export = NotebookExporter.html(from: notebook, title: "Unknown output")
        XCTAssertTrue(export.contains("Unsupported rich output: application/vnd.example+json"))
    }

    func testSavedHTMLCannotExecutePageScriptsInWebKit() async throws {
        let finished = expectation(description: "Rich HTML loaded")
        let observer = LoadObserver(finished)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 300),
                             configuration: RichOutputView.configuration())
        view.navigationDelegate = observer
        view.loadHTMLString(RichOutput.safeDocument("<title>safe</title><script>document.title='unsafe'</script><p>visible</p>"), baseURL: nil)
        await fulfillment(of: [finished], timeout: 15)
        XCTAssertEqual(view.title, "safe")
        XCTAssertEqual(view.url?.absoluteString, "about:blank")
    }

    private final class LoadObserver: NSObject, WKNavigationDelegate {
        let finished: XCTestExpectation
        let policy = RichOutputView.Coordinator()
        init(_ finished: XCTestExpectation) { self.finished = finished }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished.fulfill() }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            policy.webView(webView, decidePolicyFor: navigationAction, decisionHandler: decisionHandler)
        }
    }

    func testHTMLSVGAndJSONBundlesRoundTripWithMetadata() throws {
        let bundles: [[String: Any]] = [
            ["text/html": ["<table><tr><td>hello</td></tr></table>"], "text/plain": "hello"],
            ["image/svg+xml": "<svg xmlns=\"http://www.w3.org/2000/svg\"><circle r=\"10\"/></svg>"],
            ["application/json": ["value": [1, 2, 3]]],
            ["application/vnd.example+json": ["unknown": true], "text/plain": "fallback"],
        ]
        for bundle in bundles {
            let raw = RichOutput.raw(bundle, metadata: ["custom": "preserved"])
            let cell = NotebookCell(type: .code, outputs: [CellOutput(kind: RichOutput.kind(bundle), raw: raw)])
            let notebook = Notebook(cells: [cell], metadata: [:])
            let reloaded = try Notebook.load(from: notebook.serializedData())
            let result = try XCTUnwrap(reloaded.cells.first?.outputs.first?.raw)
            XCTAssertEqual(try JupyterJSON.data(result), try JupyterJSON.data(raw))
        }
    }

    func testJPEGReopensAsAnImageWithoutChangingItsMIME() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let jpeg = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:]))
        let bundle = ["image/jpeg": jpeg.base64EncodedString()]
        let notebook = Notebook(cells: [NotebookCell(type: .code, outputs: [CellOutput(kind: .rich(bundle))])], metadata: [:])
        let loaded = try Notebook.load(from: notebook.serializedData())
        guard case .image(let bytes, let image) = loaded.cells[0].outputs[0].kind else { return XCTFail("Expected JPEG image") }
        XCTAssertEqual(bytes, jpeg)
        XCTAssertNotNil(image)
        XCTAssertNotNil((loaded.cells[0].outputs[0].raw?["data"] as? [String: Any])?["image/jpeg"])
    }

    func testPlotlyReopensOfflineFromJSONAndEscapesScriptText() throws {
        XCTAssertNotNil(RichOutput.bundledPlotlyPath)
        let figure: [String: Any] = ["data": [["x": [1, 2], "y": [3, 4]]],
                                      "layout": ["title": "</script><script>alert(1)</script>"]]
        let bundle: [String: Any] = [RichOutput.plotlyMIME: figure, "text/plain": "figure"]
        let notebook = Notebook(cells: [NotebookCell(type: .code, outputs: [CellOutput(kind: .rich(bundle))])], metadata: [:])
        let loaded = try Notebook.load(from: notebook.serializedData())
        guard case .plotlyFigure(let html, let path, _, _, _) = loaded.cells[0].outputs[0].kind else { return XCTFail("Expected Plotly renderer") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(html.contains("<script>alert(1)</script>"))
        XCTAssertTrue(html.contains("Plotly.newPlot"))
        let export = NotebookExporter.html(from: loaded, title: "Plot")
        XCTAssertTrue(export.contains("sandbox=\"allow-scripts\""))
        XCTAssertFalse(export.contains("allow-same-origin"))
    }

    func testSavedDataFrameUsesNativeSnapshotWithoutLiveVariableHandle() throws {
        let payload: [String: Any] = ["columns": ["name"], "rows": [["<script>bad</script>"]],
                                     "index": ["0"], "text": "preview", "name": "df"]
        let bundle: [String: Any] = [RichOutput.dataframeMIME: payload, "text/html": "<table></table>"]
        guard case .dataFrame(let frame) = RichOutput.kind(bundle) else { return XCTFail("Expected native table") }
        XCTAssertNil(frame.name)
        XCTAssertTrue(RichOutput.tableHTML(frame).contains("&lt;script&gt;"))
        XCTAssertFalse(RichOutput.tableHTML(frame).contains("<script>"))
    }

    func testHTMLExportIsSandboxedAndStaticRendererDisablesScripts() {
        let output = CellOutput(kind: .rich(["text/html": "<script>bad()</script><b>visible</b>"]))
        let notebook = Notebook(cells: [NotebookCell(type: .code, outputs: [output])], metadata: [:])
        let export = NotebookExporter.html(from: notebook, title: "Test")
        XCTAssertTrue(export.contains("sandbox=\"\""))
        XCTAssertFalse(export.contains("<script>bad()</script>"))
        XCTAssertTrue(export.contains("script-src 'none'"))
        XCTAssertFalse(RichOutputView.configuration().defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(RichOutputView.configuration().websiteDataStore.isPersistent)
    }

    func testGeneratedHTMLSurvivesExecutionSaveAndReopen() async throws {
        let app = AppState()
        defer { app.kernel.stop() }
        app.pythonPath = "/usr/bin/python3"
        let cell = NotebookCell(type: .code, source: "class Result:\n    def _repr_html_(self):\n        return '<table><tr><td>42</td></tr></table>'\nResult()")
        let notebook = Notebook(cells: [cell], metadata: [:])
        let document = Document(notebook: notebook, url: nil)
        app.openDocuments = [document]
        let completed = expectation(description: "Executed HTML result")
        app.runCell(cell, in: document, advance: false) { ok in
            XCTAssertTrue(ok)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 10)
        let loaded = try Notebook.load(from: notebook.serializedData())
        let output = try XCTUnwrap(loaded.cells[0].outputs.first)
        guard case .rich(let bundle) = output.kind else { return XCTFail("Expected HTML rendering") }
        XCTAssertTrue(RichOutput.text(bundle["text/html"]).contains("42"))
        XCTAssertNotNil(bundle["text/plain"])
    }
}
