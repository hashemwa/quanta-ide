import AppKit
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var git = AppState.shared.git
    @State private var searchQuery = ""
    @State private var searchResults: [AppState.FileSearchResult] = []
    @State private var searching = false
    @State private var searchedQuery: String?
    @State private var selectedFiles: Set<URL> = []
    @State private var fileFilter = ""
    @State private var searchGeneration = 0
    @State private var searchOptions = WorkspaceSearchOptions()
    @State private var searchReport = WorkspaceSearchReport()
    @State private var showSearchOptions = false

    private var showsSearch: Bool { searching || searchedQuery != nil }

    var body: some View {
        VStack(spacing: 0) {
            navigatorBar
            switch app.sidebarPane {
            case .files:
                filesPane
            case .search:
                searchPane
            case .sourceControl:
                SourceControlPanel()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private static let paneSegments: [IconSegmentedControl<SidebarPane>.Segment] =
        SidebarPane.allCases.map { .init(value: $0, icon: $0.icon, title: $0.title, help: $0.help) }

    private var navigatorBar: some View {
        PanelBar(height: DS.Bar.primary) {
            IconSegmentedControl(segments: Self.paneSegments,
                                 selection: Binding(get: { app.sidebarPane },
                                                    set: { app.showSidebarPane($0) }))
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Navigator")
        }
    }

    @ViewBuilder
    private var filesPane: some View {
        if let workspace = app.workspace {
            fileTree(workspace)
            filesFooter(workspace)
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private var searchPane: some View {
        if app.workspace != nil {
            searchRow
            if showSearchOptions {
                searchOptionsView
                Divider()
            }
            if showsSearch {
                searchList
                searchFooter
            } else {
                NavigatorEmptyState("Search Workspace", systemImage: "magnifyingglass",
                                    detail: "Find text in scripts, notebooks, and project files.")
            }
        } else {
            emptyState
        }
    }

    private var searchRow: some View {
        PanelBar {
            SearchField(text: $searchQuery,
                        prompt: "Search in files",
                        focusRequest: app.fileSearchFocusRequest,
                        handledFocusRequest: Binding(
                            get: { app.handledFileSearchFocusRequest },
                            set: { app.handledFileSearchFocusRequest = $0 }),
                        onSubmit: runSearch)
                .frame(maxWidth: .infinity)
            IconButton("textformat", help: "Match Case", isActive: searchOptions.caseSensitive) {
                searchOptions.caseSensitive.toggle()
            }
            IconButton("textformat.abc", help: "Match Whole Word", isActive: searchOptions.wholeWord) {
                searchOptions.wholeWord.toggle()
            }
            IconButton("chevron.left.forwardslash.chevron.right", help: "Use Regular Expression", isActive: searchOptions.regularExpression) {
                searchOptions.regularExpression.toggle()
            }
            IconButton("slider.horizontal.3", help: "Search Options", isActive: showSearchOptions) { showSearchOptions.toggle() }
        }
        .onChange(of: searchQuery) { _, value in
            if value.isEmpty {
                searchGeneration += 1
                searching = false
                searchResults = []
                searchedQuery = nil
            }
        }
        .onChange(of: searchOptions.caseSensitive) { _, _ in rerunSearch() }
        .onChange(of: searchOptions.wholeWord) { _, _ in rerunSearch() }
        .onChange(of: searchOptions.regularExpression) { _, _ in rerunSearch() }
    }

    private func filesFooter(_ workspace: Workspace) -> some View {
        PanelBar(height: DS.Bar.footer) {
            IconMenu("plus", help: "New notebook, file or folder (⌘N)", glass: true) {
                Button("New Notebook") { app.newNotebook() }
                Button("New Python File") { app.newScript() }
                Divider()
                Button("New File…") { app.createFile(in: workspace.rootURL) }
                Button("New Folder…") { app.createFolder(in: workspace.rootURL) }
            }
            FilterField(text: $fileFilter)
            IconMenu("ellipsis", help: "Show more actions", glass: true) {
                Toggle("Show Hidden Files", isOn: $app.showsHiddenFiles)
                Button("Refresh File Tree") { app.refreshWorkspace() }
                Divider()
                Button("Move To…") { app.chooseDestinationAndMoveNodes(at: Array(selectedFiles)) }
                    .disabled(selectedFiles.isEmpty)
                Button("Duplicate") { app.duplicateNodes(at: Array(selectedFiles)) }
                    .disabled(selectedFiles.isEmpty)
                Button("Copy") { app.copyNodes(at: Array(selectedFiles)) }
                    .disabled(selectedFiles.isEmpty)
                Button("Paste") { app.pasteNodes(into: workspace.rootURL) }
                Divider()
                Button("Open Folder…") { app.openFolderPanel() }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([workspace.rootURL])
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Folder Open", systemImage: "folder")
        } description: {
            Text("Open a folder to browse and search its files.")
        } actions: {
            Button("Open Folder…") { app.openFolderPanel() }
                .help("Open a folder as the workspace (⇧⌘O)")
        }
    }

    private func runSearch() {
        guard !searchQuery.isEmpty else { return }
        let query = searchQuery
        searchGeneration += 1
        let generation = searchGeneration
        searching = true
        app.searchWorkspace(query, options: searchOptions) { report in
            guard generation == searchGeneration else { return }
            searching = false
            searchReport = report
            searchResults = report.results
            searchedQuery = query
        }
    }

    private func rerunSearch() {
        if !searchQuery.isEmpty { runSearch() }
    }

    private var searchOptionsView: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            TextField("Include: *.py, **/*.ipynb", text: $searchOptions.include).onSubmit(runSearch)
            TextField("Exclude: tests/**", text: $searchOptions.exclude).onSubmit(runSearch)
        }
        .controlSize(.small)
        .padding(.horizontal, DS.Space.bar)
        .padding(.vertical, DS.Space.s)
        .onChange(of: searchOptions.include) { _, _ in rerunSearch() }
        .onChange(of: searchOptions.exclude) { _, _ in rerunSearch() }
    }

    private var searchList: some View {
        List {
            ForEach(Array(Set(searchResults.map(\.fileURL))).sorted { $0.path < $1.path }, id: \.self) { url in
                Section {
                    ForEach(searchResults.filter { $0.fileURL == url }) { result in
                        Button { app.openSearchResult(result) } label: {
                            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                                Text(result.cellIndex.map { "Cell \($0 + 1) · line \(result.line)" } ?? "Line \(result.line)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(highlighted(result.preview)).font(.caption.monospaced()).lineLimit(2)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("\(url.path):\(result.line)")
                    }
                } header: {
                    Text(app.relativePath(url)).lineLimit(1).truncationMode(.middle).help(url.path)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if searching { ProgressView() }
            else if let error = searchReport.error {
                ContentUnavailableView("Search Error", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if searchResults.isEmpty, let query = searchedQuery {
                ContentUnavailableView.search(text: query)
            }
        }
        .onChange(of: app.workspace?.rootURL) { _, _ in
            searchGeneration += 1
            searching = false
            searchedQuery = nil
            searchResults = []
        }
    }

    private var searchFooter: some View {
        PanelBar(height: DS.Bar.footer) {
            Text(searchSummary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if searchReport.skippedFiles > 0 {
                Text("\(searchReport.skippedFiles) skipped")
                    .help("Unreadable files or files larger than 8 MB were skipped")
            }
            ActivitySlot(active: searching)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var searchSummary: String {
        if searching { return "Searching…" }
        if searchReport.truncated { return "First 400 matching lines" }
        let files = Set(searchResults.map(\.fileURL)).count
        return "\(searchResults.count) matching line\(searchResults.count == 1 ? "" : "s") in \(files) file\(files == 1 ? "" : "s")"
    }

    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let expression = try? searchOptions.expression(for: searchedQuery ?? searchQuery) else { return result }
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let converted = Range(range, in: result) else { continue }
            result[converted].backgroundColor = .yellow.opacity(0.25)
            result[converted].font = .caption.monospaced().bold()
        }
        return result
    }

    private func fileTree(_ workspace: Workspace) -> some View {
        let nodes = filteredNodes(workspace.root.children ?? [])
        let snapshot = git.availability == .ready ? git.snapshot : nil
        return NavigatorOutline(root: workspace.root,
                                children: nodes,
                                selection: $selectedFiles,
                                filtering: !fileFilter.isEmpty,
                                statusByPath: snapshot?.statusByPath ?? [:],
                                directoriesWithChanges: snapshot?.directoriesWithChanges ?? [])
        .onChange(of: selectedFiles) { old, selection in
            guard selection.count == 1, let url = selection.first,
                  old != selection, url.resolvingSymlinksInPath() != app.activeDocument?.url?.resolvingSymlinksInPath() else { return }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return }
            app.openFile(url)
        }
        .onChange(of: app.activeDocumentID, initial: true) { _, _ in
            let active = app.activeDocument?.url
            if let active, selectedFiles.count <= 1 { selectedFiles = [active] }
        }
    }

    private func filteredNodes(_ nodes: [FileNode]) -> [FileNode] {
        guard !fileFilter.isEmpty else { return nodes }
        return nodes.compactMap { node in
            let children = filteredNodes(node.children ?? [])
            guard node.name.localizedStandardContains(fileFilter) || !children.isEmpty else { return nil }
            var copy = node
            if node.isDirectory { copy.children = children }
            return copy
        }
    }
}
