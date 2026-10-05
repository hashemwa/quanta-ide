import XCTest
@testable import Quanta

@MainActor
final class InteractiveCellExecutionTests: XCTestCase {
    func testImmediateClearDiscardsBufferedStreamsWithoutResurrectingThem() async throws {
        let app = try await runningApp()
        defer { app.kernel.stop() }
        let document = notebook("print('old', end='')\nclear_output()\nprint('new', end='')")
        let cell = try XCTUnwrap(document.notebook?.cells.first)
        try await execute(cell, in: document, app: app)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(textOutputs(cell), ["new"])
    }

    func testDeferredClearKeepsExistingOutputUntilReplacementArrives() async throws {
        let app = try await runningApp()
        defer { app.kernel.stop() }
        let document = notebook("import time\nprint('old', end='', flush=True)\nclear_output(wait=True)\ntime.sleep(0.4)\nprint('new', end='')")
        let cell = try XCTUnwrap(document.notebook?.cells.first)
        app.openDocuments = [document]
        app.runCell(cell, in: document, advance: false)
        try await waitUntil { self.textOutputs(cell) == ["old"] }
        XCTAssertTrue(cell.isRunning)
        try await waitUntil { !cell.isRunning }
        XCTAssertEqual(textOutputs(cell), ["new"])
    }

    func testDeferredClearWithoutReplacementPreservesOutputAndNextRun() async throws {
        let app = try await runningApp()
        defer { app.kernel.stop() }
        let document = notebook("print('keep', end='')\nclear_output(wait=True)")
        let cell = try XCTUnwrap(document.notebook?.cells.first)
        try await execute(cell, in: document, app: app)
        XCTAssertEqual(textOutputs(cell), ["keep"])
        cell.source = "print('next', end='')\ndisplay(42)"
        try await execute(cell, in: document, app: app)
        XCTAssertEqual(textOutputs(cell), ["next", "42"])
        XCTAssertEqual(cell.executionCount, 2)
    }

    func testDeferredClearAppliesOnceAndPreservesFollowingOutputOrder() async throws {
        let app = try await runningApp()
        defer { app.kernel.stop() }
        let document = notebook("display(1)\nclear_output(wait=True)\ndisplay(2)\nprint('after', end='')\n3")
        let cell = try XCTUnwrap(document.notebook?.cells.first)
        try await execute(cell, in: document, app: app)
        XCTAssertEqual(textOutputs(cell), ["2", "after", "3"])
    }

    func testErrorReplacesDeferredOutput() async throws {
        let app = try await runningApp()
        defer { app.kernel.stop() }
        let document = notebook("print('old', end='')\nclear_output(wait=True)\nraise ValueError('expected')")
        let cell = try XCTUnwrap(document.notebook?.cells.first)
        try await execute(cell, in: document, app: app, expectedSuccess: false)
        XCTAssertEqual(cell.outputs.count, 1)
        let output = try XCTUnwrap(cell.outputs.first)
        guard case .error(let name, let value, _, _) = output.kind else {
            return XCTFail("Expected the error to replace the previous output")
        }
        XCTAssertEqual(name, "ValueError")
        XCTAssertEqual(value, "expected")
    }

    func testPlainDisplayAndFinalResultKeepDistinctNotebookOutputTypes() async throws {
        let app = try await runningApp()
        defer { app.kernel.stop() }
        let document = notebook("display(42)\n99")
        let cell = try XCTUnwrap(document.notebook?.cells.first)
        try await execute(cell, in: document, app: app)
        let saved = try savedOutputs(document)
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(saved[0]["output_type"] as? String, "display_data")
        XCTAssertNil(saved[0]["execution_count"])
        XCTAssertEqual(RichOutput.text((saved[0]["data"] as? [String: Any])?["text/plain"]), "42")
        XCTAssertEqual(saved[1]["output_type"] as? String, "execute_result")
        XCTAssertEqual(saved[1]["execution_count"] as? Int, cell.executionCount)
        XCTAssertEqual(RichOutput.text((saved[1]["data"] as? [String: Any])?["text/plain"]), "99")
    }

    func testRichDisplayAndFinalResultPreserveMetadataAndExecutionCount() async throws {
        let app = try await runningApp()
        defer { app.kernel.stop() }
        let document = notebook("class Rich:\n    def _repr_mimebundle_(self):\n        return ({'text/html': '<b>42</b>'}, {'text/html': {'isolated': True}})\ndisplay(Rich())\nRich()")
        let cell = try XCTUnwrap(document.notebook?.cells.first)
        try await execute(cell, in: document, app: app)
        let saved = try savedOutputs(document)
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(saved[0]["output_type"] as? String, "display_data")
        XCTAssertNil(saved[0]["execution_count"])
        XCTAssertEqual(saved[1]["output_type"] as? String, "execute_result")
        XCTAssertEqual(saved[1]["execution_count"] as? Int, cell.executionCount)
        for output in saved {
            XCTAssertEqual((output["data"] as? [String: Any])?["text/html"] as? String, "<b>42</b>")
            let metadata = output["metadata"] as? [String: Any]
            XCTAssertEqual((metadata?["text/html"] as? [String: Any])?["isolated"] as? Bool, true)
        }
    }

    func testImageResultsAndDisplayedImagesKeepDistinctNotebookOutputTypes() async throws {
        let app = try await runningApp()
        defer { app.kernel.stop() }
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a6l8AAAAASUVORK5CYII="
        let document = notebook("import __main__\nimage = {'id': __main__._current_id, 'type': 'display', 'mime': 'image/png', 'data': '\(png)'}\n__main__.emit(image)\nimage['output_type'] = 'execute_result'\n__main__.emit(image)")
        let cell = try XCTUnwrap(document.notebook?.cells.first)
        try await execute(cell, in: document, app: app)
        let saved = try savedOutputs(document)
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(saved[0]["output_type"] as? String, "display_data")
        XCTAssertNil(saved[0]["execution_count"])
        XCTAssertEqual(saved[1]["output_type"] as? String, "execute_result")
        XCTAssertEqual(saved[1]["execution_count"] as? Int, cell.executionCount)
        for output in saved {
            XCTAssertEqual((output["data"] as? [String: Any])?["image/png"] as? String, png)
        }
    }

    func testKernelDeathFinishesDeferredClearAndNextRunCanDisplay() async throws {
        let app = try await runningApp()
        defer { app.kernel.stop() }
        let document = notebook("import os, time\nprint('old', end='')\nclear_output(wait=True)\ntime.sleep(0.1)\nos._exit(7)")
        let cell = try XCTUnwrap(document.notebook?.cells.first)
        try await execute(cell, in: document, app: app, expectedSuccess: false)
        XCTAssertFalse(cell.isRunning)
        XCTAssertEqual(cell.outputs.count, 1)
        let output = try XCTUnwrap(cell.outputs.first)
        guard case .error(let name, _, _, _) = output.kind else {
            return XCTFail("Expected the kernel error")
        }
        XCTAssertEqual(name, "KernelError")
        app.startKernel()
        try await waitUntil { app.kernel.status == .idle }
        cell.source = "display(5)\n6"
        try await execute(cell, in: document, app: app)
        XCTAssertEqual(textOutputs(cell), ["5", "6"])
    }

    func testInterruptedAwaitFinishesCellAndNextAwaitRuns() async throws {
        let app = try await runningApp()
        defer { app.kernel.stop() }
        let document = notebook("import asyncio\ncleaned = False\ntry:\n    print('started', flush=True)\n    await asyncio.sleep(30)\nfinally:\n    cleaned = True")
        let cell = try XCTUnwrap(document.notebook?.cells.first)
        app.openDocuments = [document]
        app.runCell(cell, in: document, advance: false)
        try await waitUntil { !cell.outputs.isEmpty }
        app.interruptKernel()
        try await waitUntil { !cell.isRunning && app.kernel.status == .idle }
        XCTAssertTrue(cell.outputs.contains {
            if case .error(let name, _, _, _) = $0.kind { return name == "KeyboardInterrupt" }
            return false
        })
        cell.source = "await asyncio.sleep(0)\ncleaned"
        try await execute(cell, in: document, app: app)
        XCTAssertEqual(textOutputs(cell), ["True"])
    }

    func testConsoleClearOnlyRemovesOutputFromCurrentCommand() async throws {
        let app = try await runningApp()
        defer { app.kernel.stop() }
        app.console.clear()
        XCTAssertTrue(app.runConsoleInput("print('history', end='')"))
        try await waitUntil { app.kernel.status == .idle }
        let retainedIDs = Set(app.console.lines.map(\.id))
        XCTAssertTrue(app.runConsoleInput("print('old', end='')\nclear_output()\nprint('new', end='')"))
        try await waitUntil { app.kernel.status == .idle }
        XCTAssertTrue(retainedIDs.isSubset(of: Set(app.console.lines.map(\.id))))
        XCTAssertEqual(app.console.lines.filter { $0.kind == .stdout }.map(\.text), ["history", "new"])
        XCTAssertEqual(app.console.lines.filter { $0.kind == .input }.count, 2)
    }

    func testQueuedConsoleCommandsKeepTheirOwnClearedOutput() async throws {
        let app = try await runningApp()
        defer { app.kernel.stop() }
        app.console.clear()
        XCTAssertTrue(app.runConsoleInput("import time\nprint('old', flush=True)\ntime.sleep(0.1)\nclear_output(wait=True)\nprint('first', end='')"))
        XCTAssertTrue(app.runConsoleInput("print('second', end='')"))
        try await waitUntil { app.kernel.status == .idle }
        XCTAssertEqual(app.console.lines.filter { $0.kind == .input }.count, 2)
        XCTAssertEqual(app.console.lines.filter { $0.kind == .stdout }.map(\.text), ["first", "second"])
    }

    func testConsoleDeferredClearWithoutReplacementPreservesOutput() async throws {
        let app = try await runningApp()
        defer { app.kernel.stop() }
        app.console.clear()
        XCTAssertTrue(app.runConsoleInput("print('keep', end='')\nclear_output(wait=True)"))
        try await waitUntil { app.kernel.status == .idle }
        XCTAssertEqual(app.console.lines.filter { $0.kind == .stdout }.map(\.text), ["keep"])
    }

    private func notebook(_ source: String) -> Document {
        Document(notebook: Notebook(cells: [NotebookCell(type: .code, source: source)], metadata: [:]), url: nil)
    }

    private func textOutputs(_ cell: NotebookCell) -> [String] {
        cell.outputs.compactMap {
            switch $0.kind {
            case .stream(_, let text), .executeResult(let text): return text
            default: return nil
            }
        }
    }

    private func savedOutputs(_ document: Document) throws -> [[String: Any]] {
        let notebook = try XCTUnwrap(document.notebook)
        let reloaded = try Notebook.load(from: notebook.serializedData())
        return try XCTUnwrap(reloaded.cells.first).outputs.compactMap(\.raw)
    }

    private func runningApp() async throws -> AppState {
        let app = AppState()
        app.pythonPath = "/usr/bin/python3"
        app.startKernel()
        try await waitUntil { app.kernel.status == .idle }
        return app
    }

    private func execute(_ cell: NotebookCell, in document: Document, app: AppState,
                         expectedSuccess: Bool = true) async throws {
        app.openDocuments = [document]
        var success: Bool?
        app.runCell(cell, in: document, advance: false) { success = $0 }
        try await waitUntil { success != nil }
        XCTAssertEqual(try XCTUnwrap(success), expectedSuccess)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for interactive cell execution")
        throw NSError(domain: "InteractiveCellExecutionTests", code: 1)
    }
}
