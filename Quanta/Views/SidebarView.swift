import AppKit
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var app: AppState
    @State private var searchQuery = ""
    @State private var searchResults: [AppState.FileSearchResult] = []
    @State private var searching = false
    @State private var searchedQuery: String?
    @State private var selectedFile: URL?
    @State private var searchGeneration = 0

    private var showsSearch: Bool { searching || searchedQuery != nil }

    var body: some View {
        VStack(spacing: 0) {
            navigatorBar
            switch app.sidebarPane {
            case .files:
                filesPane
            case .sourceControl:
                SourceControlPanel()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private static let paneSegments: [IconSegments<SidebarPane>.Segment] =
        SidebarPane.allCases.map { .init(value: $0, icon: $0.icon, help: $0.help) }

    private var navigatorBar: some View {
        PanelBar(height: DS.Bar.primary, rule: .below) {
            IconSegments(segments: Self.paneSegments,
                         selection: Binding(get: { app.sidebarPane },
                                            set: { app.showSidebarPane($0) }))
            Spacer(minLength: DS.Space.xs)
            switch app.sidebarPane {
            case .files:
                FilesPaneActions(searching: searching)
            case .sourceControl:
                SourceControlActions()
            }
        }
    }

    @ViewBuilder
    private var filesPane: some View {
        if let workspace = app.workspace {
            searchRow
            if showsSearch {
                searchList
            } else {
                fileTree(workspace)
            }
        } else {
            emptyState
        }
    }

    private var searchRow: some View {
        PanelBar(rule: .none) {
            SearchField(text: $searchQuery,
                        prompt: "Search in files",
                        focusRequest: app.fileSearchFocusRequest,
                        handledFocusRequest: Binding(
                            get: { app.handledFileSearchFocusRequest },
                            set: { app.handledFileSearchFocusRequest = $0 }),
                        onSubmit: runSearch)
                .frame(maxWidth: .infinity)
                .frame(height: DS.Layout.slot)
        }
        .onChange(of: searchQuery) { _, value in
            if value.isEmpty {
                searchGeneration += 1
                searching = false
                searchResults = []
                searchedQuery = nil
            }
        }
    }

    private struct FilesPaneActions: View {
        let searching: Bool
        private var app: AppState { AppState.shared }
        @ObservedObject private var git = AppState.shared.git

        private var changeCount: Int {
            guard git.availability == .ready else { return 0 }
            return git.snapshot?.changedPathCount ?? 0
        }

        var body: some View {
            HStack(spacing: DS.Space.xxs) {
                if changeCount > 0 { changesPill }
                ActivitySlot(active: searching)
                IconMenu("plus", help: "New notebook, file or folder (⌘N)") {
                    Button("New Notebook") { app.newNotebook() }
                    Button("New Python File") { app.newScript() }
                    Divider()
                    Button("New File…") {
                        if let root = app.workspace?.rootURL { app.createFile(in: root) }
                    }
                    .disabled(app.workspace == nil)
                    Button("New Folder…") {
                        if let root = app.workspace?.rootURL { app.createFolder(in: root) }
                    }
                    .disabled(app.workspace == nil)
                }
                IconMenu("ellipsis", help: "Show more actions") {
                    Button("Refresh File Tree") { app.refreshWorkspace() }
                        .disabled(app.workspace == nil)
                    Divider()
                    Button("Open Folder…") { app.openFolderPanel() }
                    Button("Reveal in Finder") {
                        guard let root = app.workspace?.rootURL else { return }
                        NSWorkspace.shared.activateFileViewerSelecting([root])
                    }
                    .disabled(app.workspace == nil)
                }
            }
        }

        private var changesPill: some View {
            Button {
                app.showSidebarPane(.sourceControl)
            } label: {
                Pill(changeCount > 999 ? "999+" : "\(changeCount)")
            }
            .buttonStyle(IconButtonStyle(shape: AnyShape(Capsule())))
            .help("Show Source Control — \(changeCount) change\(changeCount == 1 ? "" : "s") (⌘2)")
            .accessibilityLabel(
                "Show Source Control, \(changeCount) change\(changeCount == 1 ? "" : "s")")
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
        app.searchWorkspace(query) { results in
            guard generation == searchGeneration else { return }
            searching = false
            searchResults = results
            searchedQuery = query
        }
    }

    private var searchList: some View {
        List(searchResults) { result in
            Button {
                app.openSearchResult(result)
            } label: {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    HStack(spacing: DS.Space.xs) {
                        Text(result.fileURL.lastPathComponent)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(":\(result.line)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    Text(result.preview)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, DS.Space.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight()
            .help("\(result.fileURL.path):\(result.line)")
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, DS.Layout.listRowMinHeight)
        .overlay {
            if searching {
                ProgressView()
                    .controlSize(.small)
            } else if searchResults.isEmpty, let query = searchedQuery {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private func fileTree(_ workspace: Workspace) -> some View {
        List(selection: $selectedFile) {
            Section(workspace.rootURL.lastPathComponent) {
                OutlineGroup(workspace.root.children ?? [], children: \.children) { node in
                    FileRowView(node: node)
                        .tag(node.url)
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, DS.Layout.listRowMinHeight)
        .onChange(of: selectedFile) { _, url in
            guard let url, url != app.activeDocument?.url else { return }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return }
            app.openFile(url)
        }
        .onChange(of: app.activeDocumentID, initial: true) { _, _ in
            let active = app.activeDocument?.url
            if selectedFile != active { selectedFile = active }
        }
        .contextMenu {
            Button("New File…") { app.createFile(in: workspace.rootURL) }
            Button("New Folder…") { app.createFolder(in: workspace.rootURL) }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([workspace.rootURL])
            }
        }
    }
}

struct FileRowView: View {
    private var app: AppState { AppState.shared }
    @ObservedObject private var git = AppState.shared.git
    let node: FileNode

    private var status: GitChange.Status? {
        git.snapshot?.statusByPath[node.url.path]
    }

    private var containsChanges: Bool {
        node.isDirectory && (git.snapshot?.directoriesWithChanges.contains(node.url.path) ?? false)
    }

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Label {
                Text(node.name)
                    .strikethrough(status == .deleted)
                    .foregroundStyle(status.map { DS.Git.color(for: $0) } ?? Color.primary)
            } icon: {
                Image(systemName: node.iconName)
            }
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer(minLength: DS.Space.xs)
            Group {
                if let status {
                    Text(status.letter)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(DS.Git.color(for: status))
                        .help(status.label)
                } else if containsChanges {
                    Circle()
                        .fill(.secondary)
                        .frame(width: DS.Layout.statusDot, height: DS.Layout.statusDot)
                        .accessibilityLabel("Contains changes")
                }
            }
            .frame(width: DS.Layout.statusSlot, alignment: .trailing)
        }
        .help(node.url.path)
        .contextMenu {
            if !node.isDirectory {
                Button("Open") { app.openFile(node.url) }
                if status != nil {
                    Button("Show Changes") { app.openDiff(forFileAt: node.url) }
                }
                Divider()
            }
            if node.isDirectory {
                Button("New File…") { app.createFile(in: node.url) }
                Button("New Folder…") { app.createFolder(in: node.url) }
                Divider()
            }
            Button("Rename…") { app.renameNode(node) }
            Button("Move to Trash", role: .destructive) { app.trashNode(node) }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.url.path, forType: .string)
            }
        }
    }
}
