import AppKit
import Combine
import WebKit
import XCTest
@testable import Quanta

final class IDEWorkflowTests: XCTestCase {
    func testWorkspaceHiddenFilesAreOptional() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "visible".write(to: root.appendingPathComponent("visible.py"), atomically: true, encoding: .utf8)
        try "hidden".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Workspace.load(url: root).root.children?.map(\.name), ["visible.py"])
        XCTAssertEqual(Set(Workspace.load(url: root, showsHiddenFiles: true).root.children?.map(\.name) ?? []),
                       Set([".env", "visible.py"]))
    }

    func testFileOperationsKeepBothAndRejectMovingFolderIntoItself() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("data.txt")
        try "one".write(to: file, atomically: true, encoding: .utf8)
        try "existing".write(to: destination.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let copied = FileOperations.transfer([file], to: destination, copying: true) { _ in .keepBoth }
        XCTAssertEqual(copied.completed.count, 1)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("data 1.txt")), "one")

        let rejected = FileOperations.transfer([source], to: source.appendingPathComponent("nested"),
                                               copying: false) { _ in .cancel }
        XCTAssertEqual(rejected.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testQuickOpenRanksDirectMatchesAndSupportsSubsequences() {
        XCTAssertLessThan(WorkspaceIndex.score("notebook.py", query: "note")!, WorkspaceIndex.score("notebook.py", query: "nbpy")!)
        XCTAssertNotNil(WorkspaceIndex.score("SourceControlPanel.swift", query: "scpsw"))
        XCTAssertNil(WorkspaceIndex.score("notebook.py", query: "xyz"))
    }

    func testSearchOptionsSupportCaseWholeWordsRegexAndPathGlobs() throws {
        var options = WorkspaceSearchOptions()
        options.include = "**/*.py, *.ipynb"
        options.exclude = "tests/**"
        XCTAssertTrue(options.accepts("main.py"))
        XCTAssertTrue(options.accepts("src/main.py"))
        XCTAssertFalse(options.accepts("tests/main.py"))
        XCTAssertFalse(options.accepts("README.md"))
        options.wholeWord = true
        options.caseSensitive = true
        let regex = try options.expression(for: "Value")
        let text = "value Value Values" as NSString
        XCTAssertEqual(regex.matches(in: text as String, range: NSRange(location: 0, length: text.length)).count, 1)
        options.regularExpression = true
        XCTAssertThrowsError(try options.expression(for: "["))
    }

    func testMarkdownParserGroupsTablesAndSkipsSeparatorRow() {
        let blocks = MarkdownView.parse("| Name | Value |\n| --- | ---: |\n| alpha | 1 |\n| beta | 2 |")
        XCTAssertEqual(blocks, [.table([
            ["Name", "Value"], ["alpha", "1"], ["beta", "2"],
        ])])
    }

    func testWorkspaceSearchMapsNotebookMatchesToCellsAndReportsTruncation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let notebook: [String: Any] = ["cells": [["source": ["first = 1\n"]], ["source": ["target = 2\n", "target += 1"]]]]
        try JSONSerialization.data(withJSONObject: notebook).write(to: root.appendingPathComponent("test.ipynb"))
        let result = WorkspaceSearcher.search(root: root, query: "target", options: WorkspaceSearchOptions())
        XCTAssertEqual(result.results.map(\.cellIndex), [1, 1])
        XCTAssertEqual(result.results.map(\.line), [1, 2])
        XCTAssertFalse(result.truncated)
        try Array(repeating: "target = 1", count: 401).joined(separator: "\n").write(to: root.appendingPathComponent("large.py"), atomically: true, encoding: .utf8)
        let limited = WorkspaceSearcher.search(root: root, query: "target", options: WorkspaceSearchOptions())
        XCTAssertEqual(limited.results.count, 400)
        XCTAssertTrue(limited.truncated)
        var invalid = WorkspaceSearchOptions()
        invalid.regularExpression = true
        XCTAssertNotNil(WorkspaceSearcher.search(root: root, query: "[", options: invalid).error)
    }

    func testStaleOutputTracksTheSourceThatWasExecuted() {
        let cell = NotebookCell(type: .code, source: "x = 1", outputs: [CellOutput(kind: .executeResult(text: "1"))])
        XCTAssertFalse(cell.hasStaleOutput)
        cell.source = "x = 2"
        XCTAssertTrue(cell.hasStaleOutput)
        cell.lastExecutedSource = cell.source
        XCTAssertFalse(cell.hasStaleOutput)
        cell.source = "x = 3"
        cell.outputs = []
        XCTAssertFalse(cell.hasStaleOutput)
    }

    @MainActor
    func testNotebookCellRangeAndToggleSelection() {
        let app = AppState()
        let cells = [NotebookCell(type: .code), NotebookCell(type: .markdown), NotebookCell(type: .code)]
        let notebook = Notebook(cells: cells, metadata: [:])
        let document = Document(notebook: notebook, url: nil)
        app.openDocuments = [document]
        app.activeDocumentID = document.id

        app.selectCell(cells[0], in: notebook)
        app.selectCell(cells[2], in: notebook, modifiers: .shift)
        XCTAssertEqual(app.selection.selectedCellIDs, Set(cells.map(\.id)))

        app.selectCell(cells[1], in: notebook, modifiers: .command)
        XCTAssertFalse(app.selection.selectedCellIDs.contains(cells[1].id))
        XCTAssertEqual(app.selection.selectedCellIDs.count, 2)
    }

    func testTracebackLocationsAndUnicodeLineNavigation() {
        let locations = TracebackLocation.parse("  File \"/tmp/my file.py\", line 12, in run\n  File \"<cell 3>\", line 2, in <module>")
        XCTAssertEqual(locations, [TracebackLocation(file: "/tmp/my file.py", line: 12)])
        XCTAssertEqual(AppState.lineLocation(in: "🐍 first\nsecond\n" as NSString, line: 2), 9)
    }

    @MainActor
    func testPinningPublishesTabOrderAndReorderingKeepsDocuments() {
        let app = AppState()
        let first = Document(script: nil, text: "first")
        let second = Document(script: nil, text: "second")
        let third = Document(script: nil, text: "third")
        app.openDocuments = [first, second, third]
        app.togglePin(third)
        XCTAssertEqual(app.openDocuments.map(\.id), [third.id, first.id, second.id])
        XCTAssertTrue(third.isPinned)
        app.reorderDocument(second.id, before: first.id)
        XCTAssertEqual(app.openDocuments.map(\.id), [third.id, second.id, first.id])
    }

    @MainActor
    func testFailedSavePreservesDirtyTextAndProvidesRecoveryMessage() {
        let app = AppState()
        let missingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let document = Document(script: missingDirectory.appendingPathComponent("unsaved.py"), text: "important = 42")
        document.isDirty = true
        XCTAssertFalse(app.save(document, interactive: false))
        XCTAssertEqual(document.text, "important = 42")
        XCTAssertTrue(document.isDirty)
        XCTAssertTrue(app.userNotice?.contains("Your edits are still open") ?? false)
    }

    @MainActor
    func testEditorRegistryKeepsBothSplitViews() {
        let id = UUID()
        let first = CodeEditorFactory.makeTextView()
        let second = CodeEditorFactory.makeTextView()
        EditorRegistry.shared.register(first, for: id)
        EditorRegistry.shared.register(second, for: id)
        XCTAssertTrue(EditorRegistry.shared.allViews.contains { $0 === first })
        XCTAssertTrue(EditorRegistry.shared.allViews.contains { $0 === second })
        XCTAssertNotNil(EditorRegistry.shared.view(for: id))
    }

    @MainActor
    func testTerminalProvidesTTYInputAndWindowSize() throws {
        let session = TerminalSession()
        let done = expectation(description: "Interactive shell responds")
        var output = ""
        var fulfilled = false
        session.onOutput = { data in
            output += String(decoding: data, as: UTF8.self)
            if output.contains("QUANTA_PTY_OK"), output.contains("37 101"), !fulfilled {
                fulfilled = true
                done.fulfill()
            }
        }
        session.start(in: FileManager.default.temporaryDirectory, shell: "/bin/sh")
        defer { session.stop() }
        XCTAssertTrue(session.running)
        session.resize(columns: 101, rows: 37)
        session.send("stty -echo; test -t 0 && printf 'QUANTA_PTY_%s\\n' OK; stty size\n")
        wait(for: [done], timeout: 10)
        XCTAssertTrue(fulfilled, output)
        session.send("exit\n")
    }
}

final class TerminalRendererTests: XCTestCase {
    @MainActor
    func testBundledTerminalRendererLoadsOffline() throws {
        let session = TerminalSession()
        let loaded = expectation(description: "Bundled terminal sends ready message")
        let observation = session.$isReady.sink { ready in if ready { loaded.fulfill() } }
        defer { observation.cancel() }
        let view = session.webView()
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 240)
        wait(for: [loaded], timeout: 15)
        XCTAssertNil(session.error)
        let rendered = expectation(description: "Terminal parses ANSI output")
        view.callAsyncJavaScript("return await new Promise(resolve => term.write('\\u001b[31mQUANTA_RENDER_OK\\u001b[0m', () => resolve(term.buffer.active.getLine(0).translateToString(true))))",
                                 arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let text): XCTAssertEqual(text as? String, "QUANTA_RENDER_OK")
            case .failure(let error): XCTFail(error.localizedDescription)
            }
            rendered.fulfill()
        }
        wait(for: [rendered], timeout: 5)
    }

    @MainActor
    func testTerminalInterruptsForegroundCommand() {
        let session = TerminalSession()
        let ready = expectation(description: "Shell starts foreground command")
        var output = ""
        var started = false
        session.onOutput = { bytes in
            output += String(decoding: bytes, as: UTF8.self)
            if output.contains("QUANTA_SLEEP_READY"), !started { started = true; ready.fulfill() }
        }
        session.start(in: FileManager.default.temporaryDirectory, shell: "/bin/sh")
        defer { session.stop() }
        session.send("stty -echo; printf 'QUANTA_SLEEP_%s\\n' READY; sleep 30\n")
        wait(for: [ready], timeout: 5)
        let interrupted = expectation(description: "Shell accepts input after Ctrl-C")
        var complete = false
        session.onOutput = { bytes in
            output += String(decoding: bytes, as: UTF8.self)
            if output.contains("QUANTA_INTERRUPT_OK"), !complete { complete = true; interrupted.fulfill() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { session.send("\u{03}") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            session.send("printf 'QUANTA_INTERRUPT_%s\\n' OK\n")
        }
        wait(for: [interrupted], timeout: 5)
        XCTAssertTrue(complete, output)
        session.send("exit\n")
    }
}
