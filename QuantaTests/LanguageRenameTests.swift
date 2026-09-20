import AppKit
import XCTest
@testable import Quanta

@MainActor
final class LanguageRenameTests: XCTestCase {
    func testRenameAcrossNotebookCellsIsAtomicAndUndoable() throws {
        let root = URL(fileURLWithPath: "/tmp")
        let first = NotebookCell(type: .code, source: "value = 1")
        let second = NotebookCell(type: .code, source: "print(value)")
        let document = Document(notebook: Notebook(cells: [first, second], metadata: [:]), url: root.appendingPathComponent("rename.ipynb"))
        let snapshots = LanguageDocument.documents(document, root: root)
        let edit: [String: Any] = ["changes": [
            snapshots[0].uri: [["range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 5]], "newText": "total"]],
            snapshots[1].uri: [["range": ["start": ["line": 0, "character": 6], "end": ["line": 0, "character": 11]], "newText": "total"]],
        ]]
        let changes = try LanguageRename.prepare(edit, documents: [document], root: root, snapshots: Dictionary(uniqueKeysWithValues: snapshots.map { ($0.uri, $0) }), versions: [:])
        let app = AppState()
        app.openDocuments = [document]
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        try app.applyLanguageChanges(changes, undoManager: undo)
        undo.endUndoGrouping()
        XCTAssertEqual(first.source, "total = 1")
        XCTAssertEqual(second.source, "print(total)")
        undo.undo()
        XCTAssertEqual(first.source, "value = 1")
        XCTAssertEqual(second.source, "print(value)")
        first.source = "changed = 2"
        XCTAssertThrowsError(try app.applyLanguageChanges(changes, undoManager: nil))
        XCTAssertEqual(second.source, "print(value)")
    }
    func testRenameRejectsFileOperationsAndOutsideWorkspaceTargets() {
        XCTAssertThrowsError(try LanguageRename.prepare(["documentChanges": [["kind": "rename", "oldUri": "file:///a", "newUri": "file:///b"]]], documents: [], root: URL(fileURLWithPath: "/tmp"), snapshots: [:], versions: [:]))
        XCTAssertThrowsError(try LanguageRename.prepare(["changes": ["file:///outside.py": [["newText": "unsafe"]]]], documents: [], root: URL(fileURLWithPath: "/tmp"), snapshots: [:], versions: [:]))
    }
}
