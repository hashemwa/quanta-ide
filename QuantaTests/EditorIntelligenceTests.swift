import AppKit
import XCTest
@testable import Quanta

@MainActor
final class EditorIntelligenceTests: XCTestCase {
    func testRegistryPrefersTheVisibleSplitEditorOverAHiddenTab() throws {
        let id = UUID()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.close() }
        let editors = [CodeEditorFactory.makeTextView(), CodeEditorFactory.makeTextView()]
        for editor in editors {
            container.addSubview(editor)
            EditorRegistry.shared.register(editor, for: id)
        }
        for visible in editors {
            for editor in editors { editor.isHidden = editor !== visible }
            XCTAssertTrue(EditorRegistry.shared.view(for: id) === visible)
        }
    }

    func testImportInsertionAtCompletionStart() throws {
        var completion = CodeCompletion(label: "Path", range: NSRange(location: 0, length: 4))
        completion.additionalEdits = [CompletionEdit(range: NSRange(location: 0, length: 0), text: "from pathlib import Path\n")]
        let transaction = try XCTUnwrap(CompletionTransaction(source: "Path", completion: completion))
        let result = NSMutableString(string: "Path")
        for edit in transaction.edits.reversed() { result.replaceCharacters(in: edit.range, with: edit.text) }
        XCTAssertEqual(result as String, "from pathlib import Path\nPath")
        XCTAssertEqual(transaction.selection.location, result.length)
    }

    func testSnippetEditsPreserveImportsUnicodeAndSelection() throws {
        let source = "title = '🙂'\nPath"
        let snippet = try XCTUnwrap(CompletionSnippet("Path(${1:path})$0"))
        var completion = CodeCompletion(label: "Path", text: snippet.text,
                                        range: (source as NSString).range(of: "Path"))
        completion.placeholders = snippet.ranges
        completion.additionalEdits = [CompletionEdit(range: NSRange(location: 0, length: 0), text: "from pathlib import Path\n")]
        let transaction = try XCTUnwrap(CompletionTransaction(source: source, completion: completion))
        let result = NSMutableString(string: source)
        for edit in transaction.edits.reversed() { result.replaceCharacters(in: edit.range, with: edit.text) }
        XCTAssertEqual(result as String, "from pathlib import Path\ntitle = '🙂'\nPath(path)")
        XCTAssertEqual(result.substring(with: transaction.selection), "path")
        completion.additionalEdits.append(completion.edit)
        XCTAssertNil(CompletionTransaction(source: source, completion: completion))
        XCTAssertEqual(CodeCompletion.rank("DataFrame", query: "df"), 2)
        XCTAssertFalse(PythonHighlighter.allowsCompletion(in: "12", at: 2))
        XCTAssertTrue(PythonHighlighter.allowsCompletion(in: "value2", at: 6))
        XCTAssertFalse(PythonHighlighter.allowsCompletion(in: "# comment", at: 9))
        XCTAssertFalse(PythonHighlighter.allowsCompletion(in: "'hello", at: 6))
        XCTAssertTrue(PythonHighlighter.allowsCompletion(in: "f'{value", at: 8))
    }
}
