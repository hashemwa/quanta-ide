import Foundation
import SQLite3

@_silgen_name("quanta_duck_open") func duckOpen(_ library: UnsafePointer<CChar>, _ path: UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
@_silgen_name("quanta_duck_error") func duckError(_ handle: UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?
@_silgen_name("quanta_duck_query") func duckQuery(_ handle: UnsafeMutableRawPointer, _ sql: UnsafePointer<CChar>) -> Int32
@_silgen_name("quanta_duck_validate") func duckValidate(_ handle: UnsafeMutableRawPointer, _ sql: UnsafePointer<CChar>) -> Int32
@_silgen_name("quanta_duck_rows") func duckRows(_ handle: UnsafeMutableRawPointer) -> UInt64
@_silgen_name("quanta_duck_value") func duckValue(_ handle: UnsafeMutableRawPointer, _ column: UInt64, _ row: UInt64, _ length: UnsafeMutablePointer<UInt64>) -> UnsafeMutablePointer<CChar>?
@_silgen_name("quanta_duck_free") func duckFree(_ handle: UnsafeMutableRawPointer, _ value: UnsafeMutableRawPointer)
@_silgen_name("quanta_duck_interrupt") func duckInterrupt(_ handle: UnsafeMutableRawPointer)
@_silgen_name("quanta_duck_close") func duckClose(_ handle: UnsafeMutableRawPointer?)

struct LocalDataSource: Identifiable, Equatable {
    enum Kind: String { case sqlite, duckdb, csv, tsv, parquet }
    let url: URL
    let kind: Kind
    var id: URL { url }
    var name: String { url.lastPathComponent }
    var isDatabase: Bool { kind == .sqlite || kind == .duckdb }

    init?(url: URL) {
        self.url = url.resolvingSymlinksInPath().standardizedFileURL
        switch url.pathExtension.lowercased() {
        case "sqlite", "sqlite3", "db": kind = .sqlite
        case "duckdb", "ddb": kind = .duckdb
        case "csv": kind = .csv
        case "tsv": kind = .tsv
        case "parquet": kind = .parquet
        default: return nil
        }
    }

    var relation: String {
        let file = LocalDataEngine.literal(url.path)
        switch kind {
        case .csv: return "read_csv(\(file), header = true)"
        case .tsv: return "read_csv(\(file), delim = '\\t', header = true)"
        case .parquet: return "read_parquet(\(file))"
        default: return ""
        }
    }
}

struct DataTable: Identifiable, Equatable {
    let schema: String
    let name: String
    let type: String
    var id: String { schema + "." + name }
    var relation: String { [schema, name].filter { !$0.isEmpty }.map(LocalDataEngine.identifier).joined(separator: ".") }
}

struct DataPage {
    let columns: [String]
    let types: [String]
    let rows: [[String?]]
    let offset: Int
    let hasMore: Bool
    var payload: DataFramePayload {
        let values = rows.map { $0.map { $0 ?? "NULL" } }
        return DataFramePayload(dict: ["columns": columns, "dtypes": types, "rows": values,
            "original_rows": values, "index": rows.indices.map { String(offset + $0 + 1) },
            "original_index": rows.indices.map { String(offset + $0 + 1) }, "offset": offset])!
    }
}

struct DataColumnStats: Equatable {
    let count: Int
    let missing: Int
    let distinct: Int
    let min: String?
    let max: String?
    let mean: Double?
}

struct DataSummary: Equatable {
    let totalRows: Int
    let columns: [DataColumnStats]
}

extension DataSummary {
    init?(_ message: [String: Any]) {
        guard let total = message["total_rows"] as? Int,
              let columns = message["columns"] as? [[String: Any]] else { return nil }
        totalRows = total
        self.columns = columns.map {
            DataColumnStats(count: $0["count"] as? Int ?? 0, missing: $0["missing"] as? Int ?? 0,
                            distinct: $0["distinct"] as? Int ?? 0, min: $0["min"] as? String,
                            max: $0["max"] as? String, mean: $0["mean"] as? Double)
        }
    }
}

final class DataQueryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?
    private var cancelled = false
    func install(_ action: (() -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        self.action = action
        if cancelled { action?() }
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        action?()
    }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw QuantaError("Query stopped or exceeded the 10-second time limit.") }
    }
}

protocol LocalDataConnection {
    func query(_ sql: String, limit: Int, columnLimit: Int, cancellation: DataQueryCancellation) throws -> DataPage
}

enum LocalDataEngine {
    static let pageSize = 200
    static let maxBytes = 4 * 1024 * 1024
    static func identifier(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    static func literal(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }

    static func connection(_ source: LocalDataSource, cancellation: DataQueryCancellation) throws -> any LocalDataConnection {
        try cancellation.check()
        if source.kind == .sqlite { return try SQLiteDataConnection(source.url, cancellation: cancellation) }
        return try DuckDataConnection(source, cancellation: cancellation)
    }

    static func tables(_ source: LocalDataSource, cancellation: DataQueryCancellation) throws -> [DataTable] {
        guard source.isDatabase else { return [] }
        let connection = try connection(source, cancellation: cancellation)
        let sql = source.kind == .sqlite
            ? "SELECT 'main', name, type FROM sqlite_schema WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY name"
            : "SELECT table_schema, table_name, table_type FROM information_schema.tables WHERE table_schema NOT IN ('information_schema', 'pg_catalog') ORDER BY table_schema, table_name"
        let page = try connection.query(sql, limit: 1001, columnLimit: 3, cancellation: cancellation)
        guard page.rows.count <= 1000 else { throw QuantaError("This database has more than 1,000 tables. Open a narrower database to browse it.") }
        return page.rows.compactMap { row in
            guard row.count == 3, let schema = row[0], let name = row[1], let type = row[2] else { return nil }
            return DataTable(schema: schema, name: name, type: type)
        }
    }

    static func isNumeric(_ type: String) -> Bool {
        let upper = type.uppercased()
        return ["INT", "DOUBLE", "REAL", "FLOAT", "DECIMAL", "NUMERIC"].contains { upper.contains($0) }
    }

    static func summary(_ source: LocalDataSource, sql: String, columns: [String], types: [String],
                        cancellation: DataQueryCancellation) throws -> DataSummary {
        let connection = try connection(source, cancellation: cancellation)
        var query = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.hasSuffix(";") { query.removeLast() }
        if let duck = connection as? DuckDataConnection { try duck.validate(query) }
        var totalRows: Int?
        var stats: [DataColumnStats] = []
        for start in stride(from: 0, to: max(1, columns.count), by: 32) {
            try cancellation.check()
            let indices = start..<min(start + 32, columns.count)
            var parts = ["count(*)"]
            for index in indices {
                let name = identifier(columns[index])
                let numeric = types.indices.contains(index) && isNumeric(types[index])
                parts += ["count(\(name))", "count(DISTINCT \(name))", "min(\(name))", "max(\(name))",
                          numeric ? "avg(\(name))" : "NULL"]
            }
            let aggregate = "SELECT \(parts.joined(separator: ", ")) FROM (\n\(query)\n) AS quanta_summary"
            let result = try connection.query(aggregate, limit: 1, columnLimit: 1 + indices.count * 5, cancellation: cancellation)
            guard let row = result.rows.first, row.count == 1 + indices.count * 5,
                  let total = row[0].flatMap(Int.init) else { throw QuantaError("Could not summarize this table.") }
            if let totalRows, totalRows != total { throw QuantaError("The table changed while its columns were being summarized. Reload to retry.") }
            totalRows = total
            stats += indices.enumerated().map { offset, _ in
                let base = 1 + offset * 5
                let count = row[base].flatMap(Int.init) ?? 0
                return DataColumnStats(count: count, missing: total - count,
                                       distinct: row[base + 1].flatMap(Int.init) ?? 0,
                                       min: row[base + 2], max: row[base + 3],
                                       mean: row[base + 4].flatMap(Double.init))
            }
        }
        return DataSummary(totalRows: totalRows ?? 0, columns: stats)
    }

    static func page(_ source: LocalDataSource, sql: String, offset: Int, cancellation: DataQueryCancellation) throws -> DataPage {
        let connection = try connection(source, cancellation: cancellation)
        var query = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.hasSuffix(";") { query.removeLast() }
        guard !query.isEmpty else { throw QuantaError("Enter a SELECT query.") }
        let bounded = "SELECT * FROM (\n\(query)\n) AS quanta_result LIMIT \(pageSize + 1) OFFSET \(max(0, offset))"
        if let duck = connection as? DuckDataConnection { try duck.validate(query) }
        let page = try connection.query(bounded, limit: pageSize + 1, columnLimit: 256, cancellation: cancellation)
        return DataPage(columns: page.columns, types: page.types, rows: Array(page.rows.prefix(pageSize)), offset: offset, hasMore: page.rows.count > pageSize)
    }
}

private final class SQLiteDataConnection: LocalDataConnection {
    private var db: OpaquePointer?
    private let cancellation: DataQueryCancellation
    init(_ url: URL, cancellation: DataQueryCancellation) throws {
        self.cancellation = cancellation
        let status = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK else {
            let error = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open database"
            sqlite3_close(db); db = nil
            throw QuantaError(error)
        }
        sqlite3_busy_timeout(db, 500)
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, Int32(LocalDataEngine.maxBytes))
        if let db { cancellation.install { sqlite3_interrupt(db) } }
    }
    deinit { cancellation.install(nil); sqlite3_close(db) }

    func query(_ sql: String, limit: Int, columnLimit: Int, cancellation: DataQueryCancellation) throws -> DataPage {
        try cancellation.check()
        var statement: OpaquePointer?
        let valid = sql.withCString { pointer -> Bool in
            var tail: UnsafePointer<CChar>?
            let status = sqlite3_prepare_v2(db, pointer, -1, &statement, &tail)
            return status == SQLITE_OK && (tail.map { String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true)
        }
        defer { sqlite3_finalize(statement) }
        guard valid, let statement, sqlite3_stmt_readonly(statement) != 0 else {
            throw QuantaError("Read-only query failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        let count = sqlite3_column_count(statement)
        guard count <= columnLimit else { throw QuantaError("Select at most \(columnLimit) columns for a preview.") }
        let columns = (0..<count).map { String(cString: sqlite3_column_name(statement, $0)) }
        let types = (0..<count).map { sqlite3_column_decltype(statement, $0).map(String.init(cString:)) ?? "value" }
        var rows: [[String?]] = [], bytes = 0
        while rows.count < limit {
            try cancellation.check()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw QuantaError(String(cString: sqlite3_errmsg(db))) }
            var row: [String?] = []
            for column in 0..<count {
                if sqlite3_column_type(statement, column) == SQLITE_NULL { row.append(nil); continue }
                let value: String
                if sqlite3_column_type(statement, column) == SQLITE_BLOB {
                    let size = Int(sqlite3_column_bytes(statement, column))
                    guard size <= LocalDataEngine.maxBytes / 2 else { throw QuantaError("A binary value exceeds the preview limit.") }
                    let data = sqlite3_column_blob(statement, column)
                    value = "X'" + (data.map { Data(bytes: $0, count: size).map { String(format: "%02X", $0) }.joined() } ?? "") + "'"
                } else if let data = sqlite3_column_text(statement, column) {
                    let size = Int(sqlite3_column_bytes(statement, column))
                    value = String(decoding: UnsafeBufferPointer(start: data, count: size), as: UTF8.self)
                } else { value = "" }
                bytes += value.utf8.count
                guard bytes <= LocalDataEngine.maxBytes else { throw QuantaError("The page exceeds the 4 MB preview limit. Select fewer columns or shorter values.") }
                row.append(value)
            }
            rows.append(row)
        }
        return DataPage(columns: columns, types: types, rows: rows, offset: 0, hasMore: rows.count == limit)
    }
}

private final class DuckDataConnection: LocalDataConnection {
    private let handle: UnsafeMutableRawPointer
    private let cancellation: DataQueryCancellation
    init(_ source: LocalDataSource, cancellation: DataQueryCancellation) throws {
        self.cancellation = cancellation
        let library = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libduckdb.dylib").path
        guard let handle = duckOpen(library, source.isDatabase ? source.url.path : "") else { throw QuantaError("Could not load the bundled data engine.") }
        if let error = duckError(handle) {
            let message = String(cString: error)
            duckClose(handle)
            throw QuantaError(message)
        }
        self.handle = handle
        cancellation.install { duckInterrupt(handle) }
    }
    deinit { cancellation.install(nil); duckClose(handle) }
    func validate(_ sql: String) throws {
        guard duckValidate(handle, sql) == 0 else { throw QuantaError(duckError(handle).map(String.init(cString:)) ?? "Enter a read-only SELECT query.") }
    }
    func query(_ sql: String, limit: Int, columnLimit: Int, cancellation: DataQueryCancellation) throws -> DataPage {
        try cancellation.check()
        guard duckQuery(handle, "DESCRIBE (\n\(sql)\n)") == 0 else { throw QuantaError(duckError(handle).map(String.init(cString:)) ?? "Query failed") }
        let count = Int(duckRows(handle))
        guard count <= columnLimit else { throw QuantaError("Select at most \(columnLimit) columns for a preview.") }
        var columns: [String] = [], types: [String] = []
        for row in 0..<count {
            columns.append(try value(column: 0, row: row) ?? "Column \(row + 1)")
            types.append(try value(column: 1, row: row) ?? "value")
        }
        guard duckQuery(handle, "SELECT COLUMNS(*)::VARCHAR FROM (\n\(sql)\n) AS quanta_text") == 0 else { throw QuantaError(duckError(handle).map(String.init(cString:)) ?? "Query failed") }
        try cancellation.check()
        var rows: [[String?]] = [], bytes = 0
        for row in 0..<min(limit, Int(duckRows(handle))) {
            try cancellation.check()
            var values: [String?] = []
            for column in 0..<count {
                let text = try value(column: column, row: row)
                bytes += text?.utf8.count ?? 0
                guard bytes <= LocalDataEngine.maxBytes else { throw QuantaError("The page exceeds the 4 MB preview limit. Select fewer columns or shorter values.") }
                values.append(text)
            }
            rows.append(values)
        }
        return DataPage(columns: columns, types: types, rows: rows, offset: 0, hasMore: rows.count == limit)
    }
    private func value(column: Int, row: Int) throws -> String? {
        var length: UInt64 = 0
        guard let pointer = duckValue(handle, UInt64(column), UInt64(row), &length) else {
            if let error = duckError(handle) { throw QuantaError(String(cString: error)) }
            return nil
        }
        defer { duckFree(handle, pointer) }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(length)), as: UTF8.self)
    }

}
