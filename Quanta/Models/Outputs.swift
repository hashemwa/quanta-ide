import AppKit
import Combine
import Foundation

struct QuantaError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension String {
    var strippingANSI: String {
        replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    var trimmingTrailingNewlines: String {
        var s = Substring(self)
        while s.last == "\n" || s.last == "\r" { s.removeLast() }
        return String(s)
    }

    func appendingTerminalOutput(_ incoming: String) -> String {
        guard incoming.contains("\r") else { return self + incoming }
        var result = self
        for ch in incoming.replacingOccurrences(of: "\r\n", with: "\n") {
            if ch == "\r" {
                if let idx = result.lastIndex(of: "\n") {
                    result = String(result[...idx])
                } else {
                    result = ""
                }
            } else {
                result.append(ch)
            }
        }
        return result
    }
}

struct TraceFrame: Identifiable {
    let id = UUID()
    let file: String
    let line: Int
    let function: String
    let code: String
    let isUser: Bool

    init?(dict: [String: Any]) {
        guard let file = dict["file"] as? String else { return nil }
        self.file = file
        self.line = dict["line"] as? Int ?? 0
        self.function = dict["func"] as? String ?? ""
        self.code = dict["code"] as? String ?? ""
        self.isUser = dict["is_user"] as? Bool ?? true
    }
}

struct NDArrayPayload {
    let shape: [Int]
    let dtype: String
    let stats: [String: Double]
    let series: [Double?]?
    let grid: [[Double?]]?
    let text: String

    init?(dict: [String: Any]) {
        guard let shape = dict["shape"] as? [Int] else { return nil }
        self.shape = shape
        self.dtype = dict["dtype"] as? String ?? ""
        self.stats = (dict["stats"] as? [String: Any] ?? [:])
            .compactMapValues { ($0 as? NSNumber)?.doubleValue }
        self.series = (dict["series"] as? [Any]).map { $0.map { ($0 as? NSNumber)?.doubleValue } }
        self.grid = (dict["grid"] as? [[Any]]).map { rows in
            rows.map { $0.map { ($0 as? NSNumber)?.doubleValue } }
        }
        self.text = dict["text"] as? String ?? ""
    }

    var shapeLabel: String { shape.map(String.init).joined(separator: " × ") }
}

struct JSONTreePayload {
    let value: Any
    let summary: String
    let text: String
}

struct ObjectCardPayload {
    let title: String
    let subtitle: String
    let fields: [(name: String, value: String)]
    let badges: [String]
    let text: String

    init?(dict: [String: Any]) {
        guard let title = dict["title"] as? String else { return nil }
        self.title = title
        self.subtitle = dict["subtitle"] as? String ?? ""
        let raw = dict["fields"] as? [String: Any] ?? [:]
        self.fields = raw.keys.sorted().map { ($0, "\(raw[$0] ?? "")") }
        self.badges = dict["badges"] as? [String] ?? []
        self.text = dict["text"] as? String ?? ""
    }
}

struct DataFramePayload {
    var name: String?
    var columns: [String]
    var dtypes: [String]
    var index: [String]
    var rows: [[String]]
    var originalRows: [[String?]]?
    var originalIndex: [String?]?
    var offset: Int
    var totalRows: Int
    var totalCols: Int
    var colsTruncated: Bool
    var rowsTruncated: Bool
    var headCount: Int
    var text: String
    private(set) var contentVersion = UUID()

    init?(dict: [String: Any]) {
        guard let columns = dict["columns"] as? [String],
              let rawRows = dict["rows"] as? [[Any]] else { return nil }
        self.columns = columns
        self.rows = rawRows.map { row in row.map { value in "\(value)" } }
        self.originalRows = (dict["original_rows"] as? [[Any]])?.map { $0.map { $0 as? String } }
        self.originalIndex = (dict["original_index"] as? [Any])?.map { $0 as? String }
        self.dtypes = dict["dtypes"] as? [String] ?? Array(repeating: "", count: columns.count)
        self.index = dict["index"] as? [String] ?? []
        self.name = dict["name"] as? String
        self.offset = dict["offset"] as? Int ?? 0
        self.totalRows = dict["total_rows"] as? Int ?? rawRows.count
        self.totalCols = dict["total_cols"] as? Int ?? columns.count
        self.colsTruncated = dict["cols_truncated"] as? Bool ?? false
        self.rowsTruncated = dict["rows_truncated"] as? Bool ?? false
        self.headCount = dict["head_count"] as? Int ?? 0
        self.text = dict["text"] as? String ?? ""
    }

    func isNumericColumn(_ i: Int) -> Bool {
        guard i >= 0, i < dtypes.count else { return false }
        let d = dtypes[i].lowercased()
        return ["int", "float", "uint", "tinyint", "smallint", "bigint", "hugeint", "utinyint",
                "usmallint", "ubigint", "uhugeint", "double", "real", "decimal", "numeric"].contains { d.hasPrefix($0) }
    }

    var columnSummary: String {
        colsTruncated ? "first \(columns.count) of \(totalCols) columns" : "\(totalCols) columns"
    }

    var rowSummary: String {
        rowsTruncated
            ? "first \(headCount) and last \(rows.count - headCount) of \(totalRows) rows"
            : "\(totalRows) rows"
    }

    var displayRowCount: Int {
        rows.count + (rowsTruncated ? 1 : 0)
    }

    mutating func appendPage(_ other: DataFramePayload) {
        if originalRows != nil, let page = other.originalRows { originalRows?.append(contentsOf: page) }
        else { originalRows = nil }
        if originalIndex != nil, let page = other.originalIndex { originalIndex?.append(contentsOf: page) }
        else { originalIndex = nil }
        rows.append(contentsOf: other.rows)
        index.append(contentsOf: other.index)
        contentVersion = UUID()
    }

    func originalValue(row: Int, column: Int) -> String? {
        if column == 0, let originalIndex, originalIndex.indices.contains(row) { return originalIndex[row] }
        guard let originalRows, originalRows.indices.contains(row),
              originalRows[row].indices.contains(column - 1) else { return nil }
        return originalRows[row][column - 1]
    }

    func originalValues(rows selected: [Int], columns selectedColumns: [Int]) -> [[String]]? {
        var result: [[String]] = []
        for row in selected {
            var values: [String] = []
            for column in selectedColumns {
                guard let value = originalValue(row: row, column: column) else { return nil }
                values.append(value)
            }
            result.append(values)
        }
        return result
    }

    var tsv: String {
        var lines = [(["index"] + columns).joined(separator: "\t")]
        for (i, row) in rows.enumerated() {
            if rowsTruncated, i == headCount {
                lines.append(("…" + String(repeating: "\t…", count: columns.count)))
            }
            let label = i < index.count ? index[i] : ""
            lines.append(([label] + row).joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }
}

struct CellOutput: Identifiable {
    enum Kind {
        case stream(name: String, text: String)
        case executeResult(text: String)
        case image(data: Data, image: NSImage?)
        case plotlyFigure(html: String, jsPath: String, data: Data, image: NSImage?, height: Double)
        case error(ename: String, evalue: String, traceback: String, frames: [TraceFrame])
        case dataFrame(DataFramePayload)
        case ndarray(NDArrayPayload)
        case jsonTree(JSONTreePayload)
        case objectCard(ObjectCardPayload)
        case rich([String: Any])
        case unsupported(mime: String)
    }

    let id = UUID()
    var kind: Kind
    var raw: [String: Any]?

    init(kind: Kind, raw: [String: Any]? = nil) {
        self.kind = kind
        self.raw = raw
    }
}

struct VariableInfo: Identifiable {
    var id: String { name }
    let name: String
    let typeName: String
    let summary: String
    let shape: String?
    let isDataFrame: Bool

    init?(dict: [String: Any]) {
        guard let name = dict["name"] as? String else { return nil }
        self.name = name
        self.typeName = dict["type"] as? String ?? ""
        self.summary = dict["summary"] as? String ?? ""
        self.shape = dict["shape"] as? String
        self.isDataFrame = dict["is_dataframe"] as? Bool ?? false
    }
}

struct ConsoleLine: Identifiable {
    enum Kind {
        case stdout, stderr, system, input, result
    }

    let id = UUID()
    let kind: Kind
    var text: String
}

final class ConsoleModel: ObservableObject {
    @Published private(set) var lines: [ConsoleLine] = []
    @Published private(set) var revision = 0
    @Published var focusRequest = 0
    private(set) var history: [String] = []
    var handledFocusRequest = 0

    func recordHistory(_ code: String) {
        guard !code.isEmpty else { return }
        if history.last == code { return }
        history.append(code)
        if history.count > 200 { history.removeFirst(history.count - 200) }
    }

    func historyEntry(offset: Int, from index: Int) -> (text: String, index: Int)? {
        guard !history.isEmpty else { return nil }
        let start = min(max(index, 0), history.count)
        let target = start + offset
        if target < 0 { return (history[0], 0) }
        if target >= history.count {
            guard start < history.count else { return nil }
            return ("", history.count)
        }
        return (history[target], target)
    }

    func append(_ kind: ConsoleLine.Kind, _ text: String) {
        guard !text.isEmpty else { return }
        if kind == .stdout || kind == .stderr,
           let last = lines.last, last.kind == kind, last.text.count < 20_000 {
            lines[lines.count - 1].text = last.text.appendingTerminalOutput(text)
        } else {
            lines.append(ConsoleLine(kind: kind, text: "".appendingTerminalOutput(text)))
        }
        if lines.count > 2000 {
            lines.removeFirst(lines.count - 2000)
        }
        revision += 1
    }

    func clear() {
        lines.removeAll()
        revision += 1
    }

}
