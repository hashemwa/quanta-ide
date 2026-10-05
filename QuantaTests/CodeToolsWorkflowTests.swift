import AppKit
import XCTest
@testable import Quanta

@MainActor
final class CodeToolsWorkflowTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
    }

    private func interpreter() throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quanta-code-tools-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("python")
        try """
        #!/usr/bin/python3
        import json
        import sys
        import time
        request = json.load(sys.stdin)
        if request['op'] == 'format':
            time.sleep(0.15)
            print(json.dumps({'source': 'values = [1, 2]\\n'}))
        else:
            print(json.dumps({'diagnostics': [], 'toolName': 'Test Python'}))
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable.path
    }

    func testCompletionFindsNamesInUnexecutedNotebookCells() {
        let context = ["measurements = [1, 2, 3]\n", "mean_value = sum(measurements) / len(measurements)\n"]
        let matches = LocalPythonCompletion.suggestions(source: "mea", cursor: 3, context: context)
        XCTAssertTrue(matches.contains { $0.label == "measurements" })
        XCTAssertTrue(matches.contains { $0.label == "mean_value" })
        XCTAssertTrue(matches.allSatisfy { $0.edit.range == NSRange(location: 0, length: 3) })
        XCTAssertTrue(LocalPythonCompletion.suggestions(source: "pri", cursor: 3, context: []).contains { $0.label == "print" })
    }

    func testCompletionSkipsCommentsStringsNumbersAndMemberAccess() {
        for source in ["# mea", "'mea", "123", "frame.mea"] {
            XCTAssertTrue(LocalPythonCompletion.suggestions(source: source, cursor: source.utf16.count,
                                                            context: ["measurements = 1"]).isEmpty, source)
        }
        let matches = LocalPythonCompletion.suggestions(source: "sec", cursor: 3,
            context: ["# secret_comment\nmessage = 'secret_string'\nobject.secret_attribute\nsection = 1"])
        XCTAssertEqual(matches.map(\.label), ["section"])
    }

    func testCompletionRangesRespectUnicode() throws {
        let source = "label = '🙂'; café"
        let matches = LocalPythonCompletion.suggestions(source: source, cursor: source.utf16.count,
                                                         context: ["café_total = 1"])
        let match = try XCTUnwrap(matches.first { $0.label == "café_total" })
        XCTAssertEqual((source as NSString).substring(with: match.edit.range), "café")
        XCTAssertTrue(LocalPythonCompletion.suggestions(source: "🙂", cursor: 1, context: []).isEmpty)
    }

    func testDiagnosticRangesRespectGraphemesAndLineEndings() {
        let source = "title = '👩🏽‍💻é'\r\nmissing = value\r\n"
        let diagnostic = PythonDiagnostic(sourceID: UUID(), line: 2, column: 11,
                                          endLine: 2, endColumn: 16, message: "Undefined name",
                                          code: "F821", severity: .error)
        XCTAssertEqual((source as NSString).substring(with: diagnostic.editorRange(in: source)), "value")
        let emoji = PythonDiagnostic(sourceID: UUID(), line: 1, column: 10,
                                    endLine: 1, endColumn: 11, message: "Example", code: "Test", severity: .warning)
        XCTAssertEqual((source as NSString).substring(with: emoji.editorRange(in: source)), "👩🏽‍💻")
    }

    func testBackgroundChecksUpdateAfterScriptChanges() async throws {
        let document = Document(script: nil, text: "values = (\n")
        let state = document.codeTools
        defer { state.cancel() }
        state.configure(document: document, python: "/usr/bin/python3", directory: nil, enabled: true)
        try await waitUntil { state.hasChecked }
        XCTAssertEqual(state.diagnostics.first?.sourceID, document.id)
        document.text = "values = [1, 2]\n"
        try await waitUntil { state.checkedSources[document.id] == document.text }
        XCTAssertTrue(state.diagnostics.isEmpty)
    }

    func testNotebookReplacementAndCellTypeChangesAreObserved() async throws {
        let oldCell = NotebookCell(type: .code, source: "values = (\n")
        let document = Document(notebook: Notebook(cells: [oldCell], metadata: [:]), url: nil)
        let state = document.codeTools
        defer { state.cancel() }
        state.configure(document: document, python: "/usr/bin/python3", directory: nil, enabled: true)
        try await waitUntil { state.hasChecked }
        XCTAssertEqual(state.diagnostics.first?.sourceID, oldCell.id)
        let newCell = NotebookCell(type: .code, source: "if True\n")
        document.notebook = Notebook(cells: [newCell], metadata: [:])
        try await waitUntil { state.checkedSources[newCell.id] == newCell.source }
        XCTAssertEqual(state.diagnostics.first?.sourceID, newCell.id)
        newCell.cellType = .markdown
        try await waitUntil { state.hasChecked && state.checkedSources.isEmpty }
        XCTAssertTrue(state.diagnostics.isEmpty)
    }

    func testDisabledChecksNeverLaunchPython() async throws {
        let document = Document(script: nil, text: "invalid = (\n")
        let state = document.codeTools
        defer { state.cancel() }
        state.configure(document: document, python: "/missing/python", directory: nil, enabled: false)
        state.checkNow()
        XCTAssertFalse(state.isChecking)
        XCTAssertFalse(state.hasChecked)
        XCTAssertTrue(state.notice?.contains("Trust") == true)
    }

    func testFormattingRejectsCodeEditedWhileFormatterRuns() async throws {
        let document = Document(script: nil, text: "values=[1,2]")
        let state = document.codeTools
        defer { state.cancel() }
        state.configure(document: document, python: try interpreter(), directory: nil, enabled: true)
        var applied = false
        state.format(sourceID: document.id) { _, _ in applied = true; return true }
        document.text = "values=[3,4]"
        try await waitUntil { !state.isFormatting }
        XCTAssertFalse(applied)
        XCTAssertEqual(document.text, "values=[3,4]")
        XCTAssertTrue(state.notice?.contains("changed while formatting") == true)
    }

    func testFormattingIsUndoableAndRejectsStaleEditorText() throws {
        let editor = CodeEditorFactory.makeTextView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        defer { window.close() }
        editor.string = "values=[1,2]"
        let undo = try XCTUnwrap(editor.undoManager)
        undo.beginUndoGrouping()
        XCTAssertTrue(editor.applyPythonFormatting(original: "values=[1,2]", formatted: "values = [1, 2]\n"))
        undo.endUndoGrouping()
        XCTAssertEqual(editor.string, "values = [1, 2]\n")
        undo.undo()
        XCTAssertEqual(editor.string, "values=[1,2]")
        undo.redo()
        XCTAssertEqual(editor.string, "values = [1, 2]\n")
        XCTAssertFalse(editor.applyPythonFormatting(original: "different", formatted: "lost work"))
        XCTAssertEqual(editor.string, "values = [1, 2]\n")
    }

    func testFormattingRestoresCaretAtAComposedCharacterBoundary() {
        let editor = CodeEditorFactory.makeTextView()
        editor.string = "abcdefgh"
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        XCTAssertTrue(editor.applyPythonFormatting(original: "abcdefgh", formatted: "x='👩🏽‍💻'"))
        XCTAssertEqual(editor.selectedRange().location, 3)
    }
}
