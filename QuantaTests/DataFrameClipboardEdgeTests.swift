import XCTest
@testable import Quanta

final class DataFrameClipboardEdgeTests: XCTestCase {
    func testTabularCopyQuotesOriginalValuesAndHeaders() {
        let text = DataFrameClipboard.tsv(header: ["a\tb", "description"], rows: [
            ["one\ttwo", "first\nsecond"],
            ["a\"b", "return\rline"],
            ["plain", ""],
        ])
        XCTAssertEqual(text, "\"a\tb\"\tdescription\n\"one\ttwo\"\t\"first\nsecond\"\n\"a\"\"b\"\t\"return\rline\"\nplain\t")
    }

    func testPythonColumnCopyConvertsDatabaseNullsAndBooleans() {
        XCTAssertEqual(DataFrameClipboard.pythonList(["true", "false", "NULL", "null", "1"], bare: true),
                       "[True, False, None, None, 1]")
        XCTAssertEqual(DataFrameClipboard.pythonList(["true", "NULL"], bare: false), "['true', 'NULL']")
    }

    func testTabularCopyQuotesEveryNewlineForm() {
        for value in ["one\ntwo", "one\rtwo", "one\r\ntwo"] {
            XCTAssertEqual(DataFrameClipboard.tsv(rows: [[value]]), "\"" + value + "\"")
        }
    }

    func testPythonStringColumnCopyEscapesControlCharacters() {
        XCTAssertEqual(DataFrameClipboard.pythonList(["first\nsecond\rthird\ttab\0end", "\\n"], bare: false),
                       "['first\\nsecond\\rthird\\ttab\\x00end', '\\\\n']")
    }
}
