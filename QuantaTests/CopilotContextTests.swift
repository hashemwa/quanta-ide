import AppKit
import XCTest
@testable import Quanta

@MainActor
final class CopilotContextTests: XCTestCase {
    func testUTF16PositionsRoundTripEmojiCRLFAndFinalNewline() {
        let source = "x = '🐍'\r\nprint(x)\r\n"
        for offset in 0...source.utf16.count {
            if let position = CopilotTextPosition(offset: offset, in: source) {
                XCTAssertEqual(position.offset(in: source), offset)
            }
        }
        XCTAssertEqual(CopilotTextPosition(offset: source.utf16.count, in: source), CopilotTextPosition(line: 2, character: 0))
        XCTAssertNil(CopilotTextPosition(offset: 6, in: source))
    }

    func testInvalidPositionsCannotOverflowOrSplitSurrogates() {
        for position in [CopilotTextPosition(line: Int.max, character: 0),
                         CopilotTextPosition(line: 0, character: Int.max),
                         CopilotTextPosition(line: -1, character: 0),
                         CopilotTextPosition(line: 0, character: 1)] {
            XCTAssertNil(position.offset(in: "🐍\n"))
        }
        XCTAssertNil(CopilotTextPosition(line: 1, character: 0).offset(in: "one line"))
        XCTAssertEqual(CopilotTextPosition(line: 0, character: 0).offset(in: ""), 0)
        XCTAssertEqual(CopilotTextPosition(line: 0, character: 3).offset(in: "a\u{2028}b"), 3)
        XCTAssertEqual(CopilotTextPosition(offset: 3, in: "a\u{2028}b"), CopilotTextPosition(line: 0, character: 3))
    }

    func testSuggestionCannotReplaceAnotherNotebookCell() throws {
        let first = NotebookCell(type: .code, source: "safe = 1")
        let active = NotebookCell(type: .code, source: "print")
        let document = Document(notebook: Notebook(cells: [first, active], metadata: [:]), url: nil)
        let snapshot = try XCTUnwrap(CopilotDocumentSnapshot(document: document, sourceID: active.id, source: active.source, caret: 5))
        let item: [String: Any] = ["insertText": "unsafe", "range": ["start": ["line": 0, "character": 0], "end": ["line": 2, "character": 5]]]
        XCTAssertNil(snapshot.suggestion(from: item, revision: 0))
    }

    func testMalformedAndOversizedSuggestionsAreIgnored() throws {
        let document = Document(script: nil, text: "x")
        let snapshot = try XCTUnwrap(CopilotDocumentSnapshot(document: document, sourceID: document.id, source: "x", caret: 1))
        let items: [[String: Any]] = [
            ["insertText": "bad", "range": ["start": ["line": 0, "character": Int.max], "end": ["line": 0, "character": 1]]],
            ["insertText": "bad", "range": "invalid"],
            ["insertText": ["value": "snippet"]],
            ["insertText": String(repeating: "a", count: CopilotDocumentSnapshot.suggestionLimit + 1)],
        ]
        for item in items { XCTAssertNil(snapshot.suggestion(from: item, revision: 0)) }
    }

    func testNotebookContextIsBoundedAndKeepsTheActiveCell() throws {
        let cells = (0..<100).map { index in NotebookCell(type: .code, source: "cell_\(index) = '" + String(repeating: "a", count: 4_000) + "'") }
        let active = cells[50]
        let document = Document(notebook: Notebook(cells: cells, metadata: [:]), url: nil)
        let snapshot = try XCTUnwrap(CopilotDocumentSnapshot(document: document, sourceID: active.id, source: active.source, caret: active.source.utf16.count))
        XCTAssertLessThanOrEqual(snapshot.text.utf16.count, CopilotDocumentSnapshot.contextLimit)
        XCTAssertEqual((snapshot.text as NSString).substring(with: snapshot.cellRange), active.source)
        XCTAssertFalse(snapshot.text.contains("cell_99 ="))
    }

    func testOversizedOrDeletedCellsNeverProduceContext() {
        let active = NotebookCell(type: .code, source: "print")
        let document = Document(notebook: Notebook(cells: [active], metadata: [:]), url: nil)
        XCTAssertNil(CopilotDocumentSnapshot(document: document, sourceID: UUID(), source: "print", caret: 5))
        XCTAssertNil(CopilotDocumentSnapshot(document: document, sourceID: active.id,
                                             source: String(repeating: "a", count: CopilotDocumentSnapshot.contextLimit + 1), caret: 0))
        active.cellType = .markdown
        XCTAssertEqual(CopilotDocumentSnapshot(document: document, sourceID: active.id, source: "print", caret: 5)?.languageID, "markdown")
    }

    func testCompletionUsesCellLineEndings() throws {
        let document = Document(script: nil, text: "x = 1\r\n")
        let snapshot = try XCTUnwrap(CopilotDocumentSnapshot(document: document, sourceID: document.id, source: document.text, caret: document.text.utf16.count))
        let result = snapshot.suggestion(from: ["insertText": "a\nb\rc\r\n"], revision: 4)
        XCTAssertEqual(result?.text, "a\r\nb\r\nc\r\n")
        XCTAssertEqual(result?.revision, 4)
    }
}
