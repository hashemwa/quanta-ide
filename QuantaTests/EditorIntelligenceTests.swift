import AppKit
import XCTest
@testable import Quanta

@MainActor
final class EditorIntelligenceTests: XCTestCase {
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
