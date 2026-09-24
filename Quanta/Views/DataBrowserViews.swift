import SwiftUI

struct DataNavigatorView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var browser: DataBrowser
    @State private var filter = ""
    @State private var selected: URL?

    var body: some View {
        VStack(spacing: 0) {
            if browser.sources.isEmpty {
                NavigatorEmptyState("No Data Sources", systemImage: "cylinder.split.1x2",
                                    detail: "Open a local database or a CSV, TSV, or Parquet file.")
            } else {
                let visibleSources = browser.sources.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
                List(selection: $selected) {
                    ForEach(visibleSources) { source in
                        Group {
                            if let session = app.openDocuments.first(where: { $0.dataSession?.source == source })?.dataSession,
                               source.isDatabase {
                                DataSourceOutline(session: session)
                            } else {
                                Label(source.name, systemImage: source.isDatabase ? "cylinder.split.1x2" : "tablecells")
                            }
                        }.tag(source.url)
                            .help(source.url.path)
                            .contextMenu {
                                Button("Open") { app.openData(source) }
                                Button("Remove from Data") { browser.remove(source) }
                            }
                    }
                }
                .listStyle(.sidebar)
                .overlay {
                    if visibleSources.isEmpty {
                        NavigatorEmptyState("No Results", systemImage: "magnifyingglass",
                                            detail: "No data source matches “\(filter)”.")
                    }
                }
                .onChange(of: selected) { _, value in
                    if let source = browser.sources.first(where: { $0.url == value }) { app.openData(source) }
                }
            }
            FilterBar(text: $filter, prompt: "Filter Data Sources") {
                FilterBarButton("plus", help: "Open Data Source…") { app.openDataPanel() }
            }
        }
    }
}

struct DataBrowserTabView: View {
    @ObservedObject var session: DataSession
    let documentID: UUID
    @EnvironmentObject private var app: AppState
    @State private var showQuery = false
    @State private var showingFilter = false

    var body: some View {
        VStack(spacing: 0) {
            PanelBar {
                if session.source.isDatabase, let table = session.selectedTable {
                    Label(table.name, systemImage: "tablecells")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if session.isLoading {
                    ProgressView().controlSize(.small).accessibilityLabel("Loading")
                    Button("Stop") { session.stop() }.buttonStyle(.borderless).font(.caption)
                } else {
                    Text(summary).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
                IconButton("chevron.left", help: "Previous Page") {
                    session.load(offset: max(0, (session.page?.offset ?? 0) - LocalDataEngine.pageSize))
                }.disabled(session.isLoading || (session.page?.offset ?? 0) == 0)
                IconButton("chevron.right", help: "Next Page") {
                    session.load(offset: (session.page?.offset ?? 0) + LocalDataEngine.pageSize)
                }.disabled(session.isLoading || session.page?.hasMore != true)
                Spacer(minLength: DS.Space.s)
                if session.source.isDatabase {
                    IconMenu("list.bullet", help: "Choose Table or View") {
                        ForEach(session.tables) { table in
                            Button(table.schema + "." + table.name) { session.select(table) }
                        }
                    }
                }
                IconButton("magnifyingglass", help: "Filter Rows", isActive: showingFilter || !session.filter.isEmpty) {
                    showingFilter.toggle()
                }
                if let page = session.page {
                    IconMenu("arrow.up.arrow.down", help: "Sort Rows") {
                        Button("Unsorted") { session.sortColumn = nil; session.run() }
                        ForEach(page.columns.indices, id: \.self) { index in
                            Button(page.columns[index]) { session.sortColumn = index; session.run() }
                        }
                        Divider()
                        Button(session.ascending ? "Sort Descending" : "Sort Ascending") { session.ascending.toggle(); session.run() }
                    }
                }
                IconButton("chevron.left.forwardslash.chevron.right", help: "Show SQL Query", isActive: showQuery) { showQuery.toggle() }
                IconButton("arrow.clockwise", help: "Reload Data (⌘R)") { session.run() }
                IconMenu("ellipsis", help: "Data Actions") {
                    Button("Refresh Tables") { session.open() }.disabled(!session.source.isDatabase)
                    Button("Export Page as CSV…") { session.exportPage() }.disabled(session.page == nil)
                    Button("Open Loading Code in Notebook") { app.insertDataLoadingCode(session) }.disabled(session.executedSQL.isEmpty)
                }
            }
            if showingFilter {
                PanelSearchBar(prompt: "Filter rows — press Return", text: $session.filter, onSubmit: { session.run() }) {
                    showingFilter = false
                }
                .onChange(of: session.filter) { _, text in
                    if text.isEmpty { session.run() }
                }
            }
            if showQuery {
                TextEditor(text: $session.query)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80, idealHeight: 110, maxHeight: 160)
                    .accessibilityLabel("SQL Query")
                PanelBar {
                    Text(session.query == session.submittedQuery ? "One SELECT query • 10-second limit" : "Query edited • Run to update results").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Run Query") { session.run() }.disabled(session.isLoading)
                }
            }
            if let error = session.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer()
                }.padding(DS.Space.bar)
            }
            if let payload = session.payload {
                DataFrameNSTable(payload: payload, cacheKey: documentID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !session.isLoading {
                NavigatorEmptyState("No Rows to Show", systemImage: "tablecells", detail: "Choose a table or run a read-only SQL query.")
            } else { Spacer() }
        }
    }

    private var summary: String {
        guard let page = session.page else { return "" }
        if page.rows.isEmpty { return "No rows" }
        let range = "Rows \((page.offset + 1).formatted())–\((page.offset + page.rows.count).formatted())"
        guard let total = session.summary?.totalRows else { return range }
        return range + " of \(total.formatted())"
    }
}

struct DataColumnInspector: View {
    @ObservedObject var session: DataSession
    @State private var selection: Int?

    var body: some View {
        ColumnList(columns: session.page?.columns ?? [], types: session.page?.types ?? [],
                   summary: session.summary, selection: $selection)
            .onAppear { selection = session.selectedColumn }
            .onChange(of: selection) { _, value in if let value { session.selectedColumn = value } }
            .onChange(of: session.selectedColumn) { _, value in selection = value }
    }

    static func detail(_ stats: DataColumnStats, type: String) -> String {
        ColumnList.detail(stats, type: type)
    }
}

struct DataFrameColumnInspector: View {
    @ObservedObject var document: Document
    @State private var selection: Int?

    var body: some View {
        ColumnList(columns: document.dataFrame?.columns ?? [], types: document.dataFrame?.dtypes ?? [],
                   summary: document.dataFrameSummary, selection: $selection)
    }
}

struct ColumnList: View {
    let columns: [String]
    let types: [String]
    let summary: DataSummary?
    @Binding var selection: Int?
    @State private var query = ""

    private var visibleColumns: [Int] {
        columns.indices.filter { query.isEmpty || columns[$0].localizedStandardContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !columns.isEmpty {
                List(visibleColumns, id: \.self, selection: $selection) { index in
                    let type = types.indices.contains(index) ? types[index] : ""
                    InspectorRow(columns[index], type: type, detail: detail(index, type: type))
                        .tag(index)
                }
                .listStyle(.sidebar)
                .overlay {
                    if visibleColumns.isEmpty {
                        NavigatorEmptyState("No Matching Columns", systemImage: "magnifyingglass",
                                            detail: "No column matches “\(query)”.") {
                            Button("Clear Filter") { query = "" }
                        }
                    }
                }
            } else {
                NavigatorEmptyState("No Columns", systemImage: "tablecells", detail: "Open a table or run a query to inspect its columns.")
            }
            FilterBar(text: $query, prompt: "Filter Columns")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func detail(_ index: Int, type: String) -> String {
        guard let stats = summary?.columns, stats.indices.contains(index) else { return "" }
        return Self.detail(stats[index], type: type)
    }

    static func detail(_ stats: DataColumnStats, type: String) -> String {
        let upper = type.uppercased()
        var parts: [String] = []
        if let min = stats.min, let max = stats.max,
           LocalDataEngine.isNumeric(type) || upper.contains("DATE") || upper.contains("TIME") {
            parts.append(min == max ? min : "\(min) – \(max)")
            if let mean = stats.mean {
                parts.append("mean \(mean.formatted(.number.precision(.fractionLength(0...2))))")
            }
        } else {
            parts.append("\(stats.distinct.formatted()) distinct")
        }
        if stats.missing > 0 { parts.append("\(stats.missing.formatted()) missing") }
        return parts.joined(separator: " · ")
    }
}

private struct DataSourceOutline: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var session: DataSession
    @State private var expanded = true
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(session.tables) { table in
                Button {
                    app.openData(session.source)
                    session.select(table)
                } label: {
                    Label(table.schema + "." + table.name, systemImage: "tablecells")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("Open " + table.name)
            }
        } label: {
            Label(session.source.name, systemImage: "cylinder.split.1x2")
        }
    }
}
