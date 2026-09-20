import AppKit
import Combine
import UniformTypeIdentifiers

final class DataBrowser: ObservableObject {
    @Published private(set) var sources: [LocalDataSource] = []
    func add(_ source: LocalDataSource) {
        if !sources.contains(source) { sources.append(source) }
    }
    func remove(_ source: LocalDataSource) { sources.removeAll { $0.id == source.id } }
}

final class DataSession: ObservableObject {
    let source: LocalDataSource
    @Published private(set) var tables: [DataTable] = []
    @Published private(set) var page: DataPage?
    @Published private(set) var payload: DataFramePayload?
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    @Published var query = ""
    @Published private(set) var submittedQuery = ""
    @Published var filter = ""
    @Published var sortColumn: Int?
    @Published var ascending = true
    @Published var selectedColumn = 0
    @Published private(set) var selectedTable: DataTable?
    private(set) var executedSQL = ""
    private var cancellation: DataQueryCancellation?
    private var generation = 0
    private var knownColumns: [String] = []

    init(source: LocalDataSource) {
        self.source = source
        if !source.isDatabase { query = "SELECT * FROM \(source.relation)" }
    }
    deinit { cancellation?.cancel() }

    func open() {
        if !source.isDatabase { run(); return }
        perform({ [source] token in try LocalDataEngine.tables(source, cancellation: token) }) { [weak self] tables in
            guard let self else { return }
            self.tables = tables
            if let selected = self.selectedTable, tables.contains(selected) { self.select(selected) }
            else if let first = tables.first { self.select(first) }
        }
    }
    func select(_ table: DataTable) {
        selectedTable = table
        query = "SELECT * FROM \(table.relation)"
        filter = ""
        sortColumn = nil
        selectedColumn = 0
        knownColumns = []
        run()
    }
    func run() {
        var base = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix(";") { base.removeLast() }
        guard !base.isEmpty else { error = "Enter a SELECT query."; return }
        if !filter.isEmpty, !knownColumns.isEmpty {
            let condition = knownColumns.map {
                "instr(lower(CAST(\(LocalDataEngine.identifier($0)) AS VARCHAR)), lower(\(LocalDataEngine.literal(filter)))) > 0"
            }.joined(separator: " OR ")
            base = "SELECT * FROM (\n\(base)\n) AS quanta_filter WHERE \(condition)"
        }
        if let sortColumn, knownColumns.indices.contains(sortColumn) {
            base = "SELECT * FROM (\n\(base)\n) AS quanta_sort ORDER BY \(sortColumn + 1) \(ascending ? "ASC" : "DESC")"
        }
        submittedQuery = query
        executedSQL = base
        page = nil
        payload = nil
        load(offset: 0)
    }
    func load(offset: Int) {
        let sql = executedSQL
        guard !sql.isEmpty else { return }
        perform({ [source] token in try LocalDataEngine.page(source, sql: sql, offset: offset, cancellation: token) }) { [weak self] page in
            self?.knownColumns = page.columns
            self?.page = page
            self?.payload = page.payload
            if let self, !page.columns.indices.contains(self.selectedColumn) { self.selectedColumn = 0 }
        }
    }
    func stop() {
        guard isLoading else { return }
        generation += 1
        cancellation?.cancel()
        cancellation = nil
        isLoading = false
        error = "Query stopped."
    }
    private func perform<Value>(_ operation: @escaping (DataQueryCancellation) throws -> Value, receive: @escaping (Value) -> Void) {
        cancellation?.cancel()
        let token = DataQueryCancellation()
        cancellation = token
        generation += 1
        let current = generation
        isLoading = true
        error = nil
        let timeout = DispatchWorkItem { token.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: timeout)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try operation(token) }
            timeout.cancel()
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.isLoading = false
                self.cancellation = nil
                switch result {
                case .success(let value): receive(value)
                case .failure(let error): self.error = error.localizedDescription
                }
            }
        }
    }

    var loadingCode: String {
        func python(_ text: String) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed), encoding: .utf8)!
        }
        let path = python(source.url.path)
        switch source.kind {
        case .csv, .tsv:
            return "import pandas as pd\n\ndf = pd.read_csv(\(path)\(source.kind == .tsv ? ", sep='\\t'" : ""))\ndf.head()"
        case .parquet:
            return "import pandas as pd\n\ndf = pd.read_parquet(\(path))\ndf.head()"
        case .sqlite:
            return "import sqlite3\nimport pandas as pd\n\nwith sqlite3.connect(\(python(source.url.absoluteString + "?mode=ro")), uri=True) as connection:\n    df = pd.read_sql_query(\(python(executedSQL)), connection)\ndf.head()"
        case .duckdb:
            return "import duckdb\n\nwith duckdb.connect(\(path), read_only=True) as connection:\n    df = connection.execute(\(python(executedSQL))).df()\ndf.head()"
        }
    }

    static func csv(_ page: DataPage) -> String {
        func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return ([page.columns.map(quote).joined(separator: ",")] + page.rows.map {
            $0.map { $0.map(quote) ?? "" }.joined(separator: ",")
        }).joined(separator: "\r\n") + "\r\n"
    }
    func exportPage() {
        guard let page else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(source.url.deletingPathExtension().lastPathComponent)-page.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Self.csv(page).write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = error.localizedDescription }
    }
}

extension AppState {
    func openDataPanel() {
        let panel = NSOpenPanel()
        panel.message = "Open a SQLite or DuckDB database, CSV, TSV, or Parquet file."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["sqlite", "sqlite3", "db", "duckdb", "ddb", "csv", "tsv", "parquet"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { if let source = LocalDataSource(url: url) { openData(source) } }
    }
    func openData(_ source: LocalDataSource) {
        dataBrowser.add(source)
        showSidebarPane(.data)
        if let document = openDocuments.first(where: { $0.dataSession?.source == source }) {
            activeDocumentID = document.id
            return
        }
        let session = DataSession(source: source)
        let document = Document(data: session)
        openDocuments.append(document)
        activeDocumentID = document.id
        session.open()
    }
    func insertDataLoadingCode(_ session: DataSession) {
        let notebook = Notebook(cells: [NotebookCell(type: .code, source: session.loadingCode)], metadata: [:])
        let document = Document(notebook: notebook, url: nil)
        document.isDirty = true
        openDocuments.append(document)
        activeDocumentID = document.id
        selectedCellID = notebook.cells.first?.id
    }
}
