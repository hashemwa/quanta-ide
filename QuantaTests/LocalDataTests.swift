import AppKit
import SQLite3
import XCTest
@testable import Quanta

@MainActor
final class LocalDataTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("quanta-data-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func sqlite() throws -> LocalDataSource {
        let url = root.appendingPathComponent("quoted ' database.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let sql = "CREATE TABLE \"odd table\" (id INTEGER, value TEXT, raw BLOB); INSERT INTO \"odd table\" VALUES (9007199254740993, NULL, X'00FF'), (2, '', X''), (3, 'a' || char(0) || 'b', NULL)"
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        return try XCTUnwrap(LocalDataSource(url: url))
    }
    func csv() throws -> LocalDataSource {
        let url = root.appendingPathComponent("quoted ' data.csv")
        let rows = (0..<450).map { "\($0),\"hello, \($0)\"" }.joined(separator: "\n")
        try ("id,label\n" + rows).write(to: url, atomically: true, encoding: .utf8)
        return try XCTUnwrap(LocalDataSource(url: url))
    }
    func testSQLiteOriginalValuesSchemaAndReadOnlyQueries() throws {
        let source = try sqlite()
        let tables = try LocalDataEngine.tables(source, cancellation: DataQueryCancellation())
        XCTAssertEqual(tables.map(\.name), ["odd table"])
        let sql = "SELECT * FROM \(tables[0].relation) ORDER BY id DESC"
        let page = try LocalDataEngine.page(source, sql: sql, offset: 0, cancellation: DataQueryCancellation())
        XCTAssertEqual(page.rows[0][0], "9007199254740993")
        XCTAssertNil(page.rows[0][1])
        XCTAssertEqual(page.rows[0][2], "X'00FF'")
        XCTAssertEqual(page.rows[1][1], "a\0b")
        XCTAssertEqual(page.rows[2][1], "")
        XCTAssertThrowsError(try LocalDataEngine.page(source, sql: "DELETE FROM \"odd table\"", offset: 0, cancellation: DataQueryCancellation()))
        XCTAssertThrowsError(try LocalDataEngine.page(source, sql: "SELECT 1); DELETE FROM \"odd table\"; --", offset: 0, cancellation: DataQueryCancellation()))
        XCTAssertEqual(try LocalDataEngine.page(source, sql: sql, offset: 0, cancellation: DataQueryCancellation()).rows.count, 3)
        let text = DataSession.csv(page)
        XCTAssertTrue(text.contains("9007199254740993"))
        XCTAssertTrue(text.contains(",,\"X'00FF'\""))
        XCTAssertTrue(text.contains("\"\""))
    }
    func testBundledDuckDBReadsCSVAndPagesWithoutPython() throws {
        let source = try csv()
        let sql = "SELECT * FROM \(source.relation) ORDER BY id"
        let first = try LocalDataEngine.page(source, sql: sql, offset: 0, cancellation: DataQueryCancellation())
        XCTAssertEqual(first.rows.count, 200)
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(first.rows[0], ["0", "hello, 0"])
        let last = try LocalDataEngine.page(source, sql: sql, offset: 400, cancellation: DataQueryCancellation())
        XCTAssertEqual(last.rows.count, 50)
        XCTAssertFalse(last.hasMore)
        XCTAssertEqual(last.rows[0][0], "400")
        XCTAssertThrowsError(try LocalDataEngine.page(source, sql: "SELECT 1; SELECT 2", offset: 0, cancellation: DataQueryCancellation()))
        XCTAssertThrowsError(try LocalDataEngine.page(source, sql: "COPY (SELECT 1) TO '/tmp/quanta-must-not-write.csv'", offset: 0, cancellation: DataQueryCancellation()))
    }
    func testSummaryCountsWholeResultNotPage() throws {
        let source = try csv()
        let sql = "SELECT * FROM \(source.relation)"
        let page = try LocalDataEngine.page(source, sql: sql, offset: 0, cancellation: DataQueryCancellation())
        let summary = try LocalDataEngine.summary(source, sql: sql, columns: page.columns, types: page.types,
                                                  cancellation: DataQueryCancellation())
        XCTAssertEqual(summary.totalRows, 450)
        XCTAssertEqual(summary.columns[0], DataColumnStats(count: 450, missing: 0, distinct: 450, min: "0", max: "449", mean: 224.5))
        XCTAssertEqual(summary.columns[1].distinct, 450)
        XCTAssertNil(summary.columns[1].mean)
    }

    func testSQLiteSummaryReportsMissingValues() throws {
        let source = try sqlite()
        let sql = "SELECT id, value FROM \"odd table\""
        let summary = try LocalDataEngine.summary(source, sql: sql, columns: ["id", "value"], types: ["INTEGER", "TEXT"],
                                                  cancellation: DataQueryCancellation())
        XCTAssertEqual(summary.totalRows, 3)
        XCTAssertEqual(summary.columns[1].missing, 1)
        XCTAssertEqual(summary.columns[1].count, 2)
    }

    func testKernelDataFrameSummaryParsesIntoTheSameStats() throws {
        let summary = try XCTUnwrap(DataSummary(["total_rows": 4, "columns": [
            ["count": 3, "missing": 1, "distinct": 3, "min": "3.0", "max": "20.0", "mean": 10.333],
            ["count": 3, "missing": 1, "distinct": 2, "min": NSNull(), "max": NSNull(), "mean": NSNull()],
        ]]))
        XCTAssertEqual(summary.totalRows, 4)
        XCTAssertEqual(DataColumnInspector.detail(summary.columns[0], type: "float64"), "3.0 – 20.0 · mean 10.33 · 1 missing")
        XCTAssertEqual(DataColumnInspector.detail(summary.columns[1], type: "object"), "2 distinct · 1 missing")
        XCTAssertNil(DataSummary(["columns": []]))
    }

    func testColumnDetailReadsLikeASentence() {
        XCTAssertEqual(DataColumnInspector.detail(DataColumnStats(count: 365, missing: 0, distinct: 300, min: "1.4", max: "30.0", mean: 21.337), type: "DOUBLE"),
                       "1.4 – 30.0 · mean 21.34")
        XCTAssertEqual(DataColumnInspector.detail(DataColumnStats(count: 360, missing: 5, distinct: 4, min: "Autumn", max: "Winter", mean: nil), type: "VARCHAR"),
                       "4 distinct · 5 missing")
        XCTAssertEqual(DataColumnInspector.detail(DataColumnStats(count: 365, missing: 0, distinct: 365, min: "2025-01-01", max: "2025-12-31", mean: nil), type: "DATE"),
                       "2025-01-01 – 2025-12-31")
    }

    func testDuckDBDatabaseAndParquetAndNullPreservation() throws {
        let library = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libduckdb.dylib").path
        let handle = try XCTUnwrap(duckOpen(library, ""))
        defer { duckClose(handle) }
        XCTAssertNil(duckError(handle))
        let database = root.appendingPathComponent("test.duckdb")
        let parquet = root.appendingPathComponent("test.parquet")
        XCTAssertEqual(duckQuery(handle, "ATTACH \(LocalDataEngine.literal(database.path)) AS fixture"), 0)
        XCTAssertEqual(duckQuery(handle, "CREATE TABLE fixture.items AS SELECT 9007199254740993::BIGINT AS id, 'a' || chr(0) || 'b' AS label, NULL AS missing"), 0)
        XCTAssertEqual(duckQuery(handle, "COPY fixture.items TO \(LocalDataEngine.literal(parquet.path)) (FORMAT PARQUET)"), 0)
        XCTAssertEqual(duckQuery(handle, "DETACH fixture"), 0)
        let db = try XCTUnwrap(LocalDataSource(url: database))
        let tables = try LocalDataEngine.tables(db, cancellation: DataQueryCancellation())
        XCTAssertEqual(tables.map(\.name), ["items"])
        let result = try LocalDataEngine.page(db, sql: "SELECT * FROM items", offset: 0, cancellation: DataQueryCancellation())
        XCTAssertEqual(result.rows[0][0], "9007199254740993")
        XCTAssertEqual(result.rows[0][1], "a\0b")
        XCTAssertNil(result.rows[0][2])
        let file = try XCTUnwrap(LocalDataSource(url: parquet))
        XCTAssertEqual(try LocalDataEngine.page(file, sql: "SELECT * FROM \(file.relation)", offset: 0, cancellation: DataQueryCancellation()).rows, result.rows)
    }
    func testPreviewBudgetAndCancellation() async throws {
        let source = try sqlite()
        XCTAssertThrowsError(try LocalDataEngine.page(source, sql: "SELECT hex(zeroblob(3000000))", offset: 0, cancellation: DataQueryCancellation()))
        let token = DataQueryCancellation()
        let done = expectation(description: "A running SQLite query is interrupted")
        DispatchQueue.global().async {
            do {
                _ = try LocalDataEngine.page(source, sql: "WITH RECURSIVE x(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM x WHERE n<1000000000) SELECT sum(n) FROM x", offset: 0, cancellation: token)
                XCTFail("A cancelled query must not complete")
            } catch {}
            done.fulfill()
        }
        try await Task.sleep(for: .milliseconds(100))
        token.cancel()
        await fulfillment(of: [done], timeout: 3)
        XCTAssertThrowsError(try LocalDataEngine.page(source, sql: "SELECT 1", offset: 0, cancellation: token))
    }
    func testLoadingCodeEscapesPathsAndUsesReadOnlyConnections() throws {
        let session = DataSession(source: try sqlite())
        XCTAssertTrue(session.loadingCode.contains("mode=ro"))
        XCTAssertTrue(session.loadingCode.contains("uri=True"))
        XCTAssertTrue(session.loadingCode.contains("read_sql_query"))
    }
}
