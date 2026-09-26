import XCTest
@testable import Quanta

final class NotebookExecutionTests: XCTestCase {
    @MainActor
    func testRejectedConsoleExecutionDoesNotAdvanceScriptCaret() {
        let app = AppState()
        app.pythonPath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let document = Document(script: nil, text: "first = 1\nsecond = 2")
        let editor = CodeEditorFactory.makeTextView()
        editor.string = document.text
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        EditorRegistry.shared.register(editor, for: document.id)
        app.openDocuments = [document]
        app.activeDocumentID = document.id
        app.runSelectionOrLine(in: document)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertFalse(app.kernel.isRunning)
        XCTAssertFalse(app.console.lines.contains { $0.kind == .input })
    }

    @MainActor
    func testClosingAnotherTabPreservesRunAllQueue() async throws {
        let app = try await runningApp()
        defer { app.kernel.stop() }
        let document = notebook(["import time; time.sleep(0.2)", "42"])
        let other = Document(script: nil, text: "")
        app.openDocuments = [document, other]
        app.activeDocumentID = document.id
        app.runAllCells(in: document)
        XCTAssertTrue(app.closeDocument(other))
        try await waitUntil { app.kernel.status == .idle }
        XCTAssertNotNil(document.notebook?.cells[1].executionCount)
        XCTAssertFalse(document.notebook?.cells.contains(where: { $0.isQueued }) ?? true)
        XCTAssertNil(app.runQueueProgress)
    }

    @MainActor
    func testRunAllInAnotherNotebookDoesNotReplaceActiveQueue() async throws {
        let app = try await runningApp()
        defer { app.kernel.stop() }
        let first = notebook(["import time; time.sleep(0.2)", "42"])
        let second = notebook(["99", "100"])
        app.openDocuments = [first, second]
        app.activeDocumentID = first.id
        app.runAllCells(in: first)
        app.runAllCells(in: second)
        XCTAssertFalse(second.notebook?.cells.contains(where: { $0.isRunning || $0.isQueued }) ?? true)
        try await waitUntil { app.kernel.status == .idle }
        XCTAssertNotNil(first.notebook?.cells[1].executionCount)
        XCTAssertNil(second.notebook?.cells[0].executionCount)
        XCTAssertNil(app.runQueueProgress)
    }

    @MainActor
    func testInterruptedRunAllDoesNotOfferToContinueCancelledCells() async throws {
        let app = try await runningApp()
        defer { app.kernel.stop() }
        let document = notebook(["import time; print('started', flush=True); time.sleep(5)", "42"])
        app.openDocuments = [document]
        app.activeDocumentID = document.id
        app.runAllCells(in: document)
        try await waitUntil { document.notebook?.cells[0].outputs.isEmpty == false }
        app.interruptKernel()
        try await waitUntil { app.kernel.status == .idle }
        XCTAssertNil(app.pausedRunDocumentID)
        XCTAssertNil(app.userNotice)
        XCTAssertNil(document.notebook?.cells[1].executionCount)
        XCTAssertFalse(document.notebook?.cells.contains(where: { $0.isQueued }) ?? true)
    }

    @MainActor
    func testRunAndAdvanceKeepsSelectionInNewlyActiveNotebook() async throws {
        let app = try await runningApp()
        defer { app.kernel.stop() }
        let first = notebook(["import time; time.sleep(0.2)", "42"])
        let second = notebook(["99"])
        app.openDocuments = [first, second]
        app.activeDocumentID = first.id
        let cell = try XCTUnwrap(first.notebook?.cells.first)
        app.runCell(cell, in: first, advance: true)
        app.activeDocumentID = second.id
        try await waitUntil { app.kernel.status == .idle }
        XCTAssertEqual(app.selectedCellID, second.notebook?.cells[0].id)
        XCTAssertEqual(first.lastSelectedCellID, first.notebook?.cells[1].id)
    }

    @MainActor
    func testBackgroundCellErrorKeepsSelectionInActiveNotebook() async throws {
        let app = try await runningApp()
        defer { app.kernel.stop() }
        let first = notebook(["import time; time.sleep(0.2); raise ValueError('expected')", "42"])
        let second = notebook(["99"])
        app.openDocuments = [first, second]
        app.activeDocumentID = first.id
        app.runAllCells(in: first)
        app.activeDocumentID = second.id
        try await waitUntil { app.kernel.status == .idle }
        XCTAssertEqual(app.selectedCellID, second.notebook?.cells[0].id)
        XCTAssertEqual(app.pausedRunDocumentID, first.id)
    }

    @MainActor
    func testAutosavePreservesExternalChangesWithOlderTimestamp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("script.py")
        try "external changes".write(to: file, atomically: true, encoding: .utf8)
        let document = Document(script: file, text: "my unsaved edits")
        document.isDirty = true
        document.fileModificationDate = Date(timeIntervalSinceNow: 60)
        XCTAssertFalse(AppState().save(document, interactive: false))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "external changes")
        XCTAssertTrue(document.isDirty)
    }

    private func notebook(_ sources: [String]) -> Document {
        Document(notebook: Notebook(cells: sources.map { NotebookCell(type: .code, source: $0) }, metadata: [:]), url: nil)
    }

    @MainActor
    private func runningApp() async throws -> AppState {
        let app = AppState()
        app.pythonPath = "/usr/bin/python3"
        app.startKernel()
        try await waitUntil { app.kernel.status == .idle }
        return app
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for notebook execution")
        throw NSError(domain: "NotebookExecutionTests", code: 1)
    }
}
