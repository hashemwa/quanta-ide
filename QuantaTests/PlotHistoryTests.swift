import XCTest
@testable import Quanta

@MainActor
final class PlotHistoryTests: XCTestCase {
    private let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a6l8AAAAASUVORK5CYII="

    func testPlotlyFallbackIsUpgradedWithinTheSameRun() throws {
        let history = PlotHistory()
        let origin = history.beginRun(document: Document(script: nil, text: ""))
        history.consume(["type": "display", "mime": "image/png", "data": png], origin: origin)
        let id = try XCTUnwrap(history.records.first?.id)
        history.consume(["type": "plotlyhtml", "html": "figure", "js_path": "/plotly.js", "has_png": true], origin: origin)
        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(history.records.first?.id, id)
        guard case .plotlyFigure(_, _, let data, _, _) = history.records[0].output.kind else {
            return XCTFail("Expected an interactive plot")
        }
        XCTAssertEqual(data, Data(base64Encoded: png))
    }

    func testPlotlyDoesNotReplaceAnotherRunsImage() {
        let history = PlotHistory()
        let first = history.beginRun(document: nil)
        let second = history.beginRun(document: nil)
        history.consume(["type": "display", "mime": "image/png", "data": png], origin: first)
        history.consume(["type": "plotlyhtml", "html": "figure", "js_path": "/plotly.js", "has_png": true], origin: second)
        XCTAssertEqual(history.records.count, 2)
        XCTAssertEqual(history.records.map { $0.origin.run }, [1, 2])
    }

    func testNotebookImportDeduplicatesAndDoesNotReplaceRunProvenance() {
        let output = CellOutput(kind: .image(data: Data(), image: nil))
        let cell = NotebookCell(type: .code, outputs: [output])
        let document = Document(notebook: Notebook(cells: [cell], metadata: [:]), url: nil)
        let history = PlotHistory()
        let origin = history.beginRun(document: document, cell: cell)
        history.record(output, origin: origin)
        history.importNotebook(document)
        history.importNotebook(document)
        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(history.records[0].origin.runID, origin.runID)
        XCTAssertEqual(history.records[0].origin.cellNumber, 1)
        XCTAssertEqual(history.records[0].origin.documentID, document.id)
    }

    func testHistoryIsBoundedAndIgnoresNonPlots() {
        let history = PlotHistory(limit: 2)
        let origin = history.beginRun(document: nil)
        history.record(CellOutput(kind: .executeResult(text: "hello")), origin: origin)
        XCTAssertTrue(history.records.isEmpty)
        for _ in 0..<3 {
            history.record(CellOutput(kind: .image(data: Data(), image: nil)), origin: origin)
        }
        XCTAssertEqual(history.records.count, 2)
    }

    func testRevealSourceSelectsOriginalNotebookCell() throws {
        let app = AppState()
        let cell = NotebookCell(type: .code)
        let document = Document(notebook: Notebook(cells: [cell], metadata: [:]), url: nil)
        app.openDocuments = [document]
        let origin = app.plots.beginRun(document: document, cell: cell)
        app.plots.record(CellOutput(kind: .image(data: Data(), image: nil)), origin: origin)
        app.revealPlotSource(try XCTUnwrap(app.plots.records.first))
        XCTAssertEqual(app.activeDocumentID, document.id)
        XCTAssertEqual(app.selectedCellID, cell.id)
        XCTAssertEqual(app.scrollRequest, cell.id)
    }

    func testScriptPlotKeepsItsSourceAfterTabSwitch() async throws {
        let app = AppState()
        defer { app.kernel.stop() }
        app.pythonPath = "/usr/bin/python3"
        let source = Document(script: nil, text: "import __main__\n__main__.emit({'id': __main__._current_id, 'type': 'display', 'mime': 'image/png', 'data': '\(png)'})")
        let other = Document(script: nil, text: "")
        app.openDocuments = [source, other]
        app.activeDocumentID = source.id
        app.runScript(source)
        app.activeDocumentID = other.id
        for _ in 0..<500 {
            if !app.plots.records.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let plot = try XCTUnwrap(app.plots.records.first)
        XCTAssertEqual(plot.origin.documentID, source.id)
        XCTAssertNotEqual(plot.origin.documentID, app.activeDocumentID)
    }
}
