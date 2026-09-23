import SwiftUI

struct DataNavigatorView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var browser: DataBrowser
    @State private var filter = ""
    @State private var selected: URL?

    var body: some View {
        VStack(spacing: 0) {
            if browser.sources.isEmpty {
                NavigatorEmptyState("No Data Sources", systemImage: "externaldrive",
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
                                Label(source.name, systemImage: source.isDatabase ? "externaldrive" : "tablecells")
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
    @State private var handledFilterFocus = 0

    var body: some View {
        VStack(spacing: 0) {
            PanelBar {
                if session.source.isDatabase {
                    Menu {
                        ForEach(session.tables) { table in
                            Button(table.schema + "." + table.name) { session.select(table) }
                        }
                    } label: {
                        Label(session.selectedTable?.name ?? "Tables", systemImage: "tablecells")
                    }
                    .help("Choose Table or View")
                } else { Text(session.source.name).font(.callout).lineLimit(1) }
                Spacer(minLength: DS.Space.s)
                Text("Read Only").font(.caption).foregroundStyle(.secondary)
                IconButton("chevron.left.forwardslash.chevron.right", help: "Show SQL Query", isActive: showQuery) { showQuery.toggle() }
                IconButton("arrow.clockwise", help: "Reload Data (⌘R)") { session.run() }
                Menu {
                    Button("Refresh Tables") { session.open() }.disabled(!session.source.isDatabase)
                    Button("Export Page as CSV…") { session.exportPage() }.disabled(session.page == nil)
                    Button("Open Loading Code in Notebook") { app.insertDataLoadingCode(session) }.disabled(session.executedSQL.isEmpty)
                } label: { Image(systemName: "ellipsis") }
                .help("Data Actions")
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
            PanelBar {
                SearchField(text: $session.filter, prompt: "Filter Rows", style: .filter,
                            focusRequest: 0, handledFocusRequest: $handledFilterFocus, onSubmit: { session.run() }, submitsImmediately: false, allowsEmptySubmission: true)
                    .help("Filter the full query result, then press Return")
                if let page = session.page {
                    Menu {
                        Button("Unsorted") { session.sortColumn = nil; session.run() }
                        ForEach(page.columns.indices, id: \.self) { index in
                            Button(page.columns[index]) { session.sortColumn = index; session.run() }
                        }
                        Divider()
                        Button(session.ascending ? "Sort Descending" : "Sort Ascending") { session.ascending.toggle(); session.run() }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                    .help("Sort Query Results")
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
            PanelBar {
                if session.isLoading {
                    ProgressView().controlSize(.small)
                    Text("Loading…").font(.caption).foregroundStyle(.secondary)
                    Button("Stop") { session.stop() }
                } else if let page = session.page {
                    Text(page.rows.isEmpty ? "No rows" : "Rows \(page.offset + 1)–\(page.offset + page.rows.count)\(page.hasMore ? " · more available" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                IconButton("chevron.left", help: "Previous Page") {
                    session.load(offset: max(0, (session.page?.offset ?? 0) - LocalDataEngine.pageSize))
                }.disabled(session.isLoading || (session.page?.offset ?? 0) == 0)
                IconButton("chevron.right", help: "Next Page") {
                    session.load(offset: (session.page?.offset ?? 0) + LocalDataEngine.pageSize)
                }.disabled(session.isLoading || session.page?.hasMore != true)
            }
        }
    }
}

struct DataColumnInspector: View {
    @ObservedObject var session: DataSession
    @State private var selection: Int?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelBar(height: DS.Bar.primary) {
                Text("Columns").font(.callout)
                Spacer()
            }
            if let page = session.page, !page.columns.isEmpty {
                List(selection: $selection) {
                    ForEach(page.columns.indices, id: \.self) { index in
                        HStack {
                            Text(page.columns[index]).lineLimit(1)
                            Spacer()
                            Text(page.types[index]).font(.caption).foregroundStyle(.secondary)
                        }.tag(index)
                    }
                }.listStyle(.sidebar)
                    .onAppear { selection = session.selectedColumn }
                    .onChange(of: selection) { _, value in if let value { session.selectedColumn = value } }
                    .onChange(of: session.selectedColumn) { _, value in selection = value }
                if page.columns.indices.contains(session.selectedColumn) {
                    let values = page.rows.compactMap { $0[session.selectedColumn] }
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        Text(page.columns[session.selectedColumn]).font(.headline)
                        LabeledContent("Rows on page", value: String(page.rows.count))
                        LabeledContent("Missing on page", value: String(page.rows.count - values.count))
                        LabeledContent("Distinct on page", value: String(Set(values).count))
                        Text("Statistics describe this page only.").font(.caption).foregroundStyle(.secondary)
                    }.padding(DS.Space.bar)
                }
            } else {
                NavigatorEmptyState("No Columns", systemImage: "tablecells", detail: "Open a table or run a query to inspect its columns.")
            }
        }
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
            Label(session.source.name, systemImage: "externaldrive")
        }
    }
}
