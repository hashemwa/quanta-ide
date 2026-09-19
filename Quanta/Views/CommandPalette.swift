import SwiftUI

enum PaletteMode: String, Identifiable {
    case files, commands
    var id: String { rawValue }
}

struct IDECommand: Identifiable {
    let id: String
    let title: String
    let shortcut: String
    var enabled = true
    let action: () -> Void
}

struct CommandPalette: View {
    let mode: PaletteMode
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: String?
    @FocusState private var focused: Bool

    private struct Entry: Identifiable {
        let id: String
        let title: String
        let detail: String
        let icon: String
        let enabled: Bool
        let action: () -> Void
    }

    private var entries: [Entry] {
        let candidates: [Entry]
        if mode == .commands {
            let recent = QuantaDefaults.store.stringArray(forKey: "QuantaRecentCommands") ?? []
            candidates = app.ideCommands.sorted {
                (recent.firstIndex(of: $0.id) ?? Int.max) < (recent.firstIndex(of: $1.id) ?? Int.max)
            }.map { command in
                Entry(id: command.id, title: command.title, detail: command.shortcut,
                      icon: "command", enabled: command.enabled) {
                    var history = recent.filter { $0 != command.id }
                    history.insert(command.id, at: 0)
                    QuantaDefaults.store.set(Array(history.prefix(12)), forKey: "QuantaRecentCommands")
                    command.action()
                }
            }
        } else {
            let files = app.workspace.map { WorkspaceIndex.files(in: $0.root) } ?? []
            var seen = Set<String>()
            let ordered = app.openDocuments.compactMap(\.url)
                + app.recentFiles.map { URL(fileURLWithPath: $0) } + files
            candidates = ordered.filter {
                seen.insert($0.resolvingSymlinksInPath().standardizedFileURL.path).inserted
                    && FileManager.default.fileExists(atPath: $0.path)
            }.map { url in
                Entry(id: url.path, title: url.lastPathComponent, detail: app.relativePath(url),
                      icon: FileNode.iconName(forExtension: url.pathExtension), enabled: true) { app.openFile(url) }
            }
        }
        return Array(candidates.enumerated().compactMap { index, entry -> (Entry, Int, Int)? in
            guard let score = WorkspaceIndex.score(entry.title + " " + entry.detail, query: query) else { return nil }
            return (entry, score, index)
        }.sorted { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 < $1.1 }.prefix(100).map(\.0))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.m) {
                Image(systemName: mode == .files ? "doc.text.magnifyingglass" : "command")
                    .foregroundStyle(.secondary)
                TextField(mode == .files ? "Search files by name or path" : "Search commands", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(activate)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(DS.Space.l)
            Divider()
            ScrollViewReader { proxy in
                List(entries, selection: $selected) { entry in
                    HStack(spacing: DS.Space.m) {
                        Image(systemName: entry.icon).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            Text(entry.title).lineLimit(1)
                            if mode == .files {
                                Text(entry.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        Spacer()
                        if mode == .commands { Text(entry.detail).font(.caption).foregroundStyle(.secondary) }
                    }
                    .opacity(entry.enabled ? 1 : 0.45)
                    .tag(entry.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { selected = entry.id; activate() }
                    .help(entry.detail)
                }
                .listStyle(.plain)
                .onChange(of: selected) { _, id in if let id { proxy.scrollTo(id) } }
                .overlay {
                    if entries.isEmpty { ContentUnavailableView.search(text: query) }
                }
            }
            Divider()
            HStack {
                Text("↑ ↓ to navigate · Return to open · Esc to dismiss")
                Spacer()
                Text("\(entries.count) results")
            }
            .font(.caption).foregroundStyle(.secondary).padding(DS.Space.bar)
        }
        .frame(width: DS.Layout.paletteWidth, height: DS.Layout.paletteHeight)
        .onAppear { focused = true; selected = entries.first?.id }
        .onChange(of: query) { _, _ in selected = entries.first?.id }
    }

    private func move(_ delta: Int) {
        let matches = entries
        guard !matches.isEmpty else { return }
        let index = matches.firstIndex { $0.id == selected } ?? 0
        selected = matches[min(max(0, index + delta), matches.count - 1)].id
    }

    private func activate() {
        guard let entry = entries.first(where: { $0.id == selected }), entry.enabled else { return }
        dismiss()
        DispatchQueue.main.async { entry.action() }
    }
}

extension AppState {
    func relativePath(_ url: URL) -> String {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard let root = workspace?.rootURL.resolvingSymlinksInPath().standardizedFileURL.path,
              path.hasPrefix(root + "/") else { return url.path }
        return String(path.dropFirst(root.count + 1))
    }

    var ideCommands: [IDECommand] {
        [
            IDECommand(id: "open", title: "Open File…", shortcut: "⌘O", action: openFilePanel),
            IDECommand(id: "folder", title: "Open Folder…", shortcut: "⇧⌘O", action: openFolderPanel),
            IDECommand(id: "notebook", title: "New Notebook", shortcut: "⌘N", action: newNotebook),
            IDECommand(id: "script", title: "New Python File", shortcut: "⇧⌘N", action: newScript),
            IDECommand(id: "save", title: "Save File", shortcut: "⌘S", enabled: activeDocumentIsEditable, action: saveActiveDocument),
            IDECommand(id: "run", title: runCommandTitle, shortcut: "⌘R", enabled: activeDocumentIsRunnable, action: runActiveDocument),
            IDECommand(id: "run-selected", title: "Run Selected Cells", shortcut: "", enabled: selection.selectedCellIDs.count > 1, action: runSelectedCells),
            IDECommand(id: "stop", title: "Interrupt Execution", shortcut: "⌘.", enabled: kernelStatus == .busy, action: interruptKernel),
            IDECommand(id: "restart", title: "Restart Kernel…", shortcut: "⌃⌘R", action: { self.restartKernel() }),
            IDECommand(id: "back", title: "Go Back", shortcut: "⌘[", enabled: canNavigateBack, action: { self.navigateHistory(-1) }),
            IDECommand(id: "forward", title: "Go Forward", shortcut: "⌘]", enabled: canNavigateForward, action: { self.navigateHistory(1) }),
            IDECommand(id: "search", title: "Find in Files…", shortcut: "⇧⌘F", enabled: workspace != nil, action: focusFileSearch),
            IDECommand(id: "continue-run", title: "Continue Remaining Cells", shortcut: "", enabled: pausedRunDocumentID != nil, action: continueRemainingCells),
            IDECommand(id: "variables", title: "Toggle Variables", shortcut: "⌥⌘0", action: toggleVariables),
            IDECommand(id: "console", title: "Show Python Console", shortcut: "", action: { self.showPythonConsole() }),
            IDECommand(id: "terminal", title: "Show Terminal", shortcut: "⌃`", action: showTerminal),
            IDECommand(id: "reopen", title: "Reopen Closed Tab", shortcut: "⇧⌘T", enabled: !closedDocuments.isEmpty, action: reopenClosedDocument),
            IDECommand(id: "split", title: "Toggle Split Editor", shortcut: "⌘\\", enabled: activeDocument != nil, action: toggleSplitEditor),
            IDECommand(id: "git", title: "Show Source Control", shortcut: "⌘2", action: { self.showSidebarPane(.sourceControl) }),
            IDECommand(id: "hidden-files", title: showsHiddenFiles ? "Hide Hidden Files" : "Show Hidden Files", shortcut: "", enabled: workspace != nil, action: { self.showsHiddenFiles.toggle() }),
            IDECommand(id: "reset-layout", title: "Reset Window Layout", shortcut: "", action: resetLayout),
            IDECommand(id: "stage", title: "Stage All Changes", shortcut: "", enabled: !git.isBusy && !(git.snapshot?.unstaged.isEmpty ?? true), action: stageAllChanges),
            IDECommand(id: "commit", title: "Write Commit Message…", shortcut: "⌃⌘C", enabled: !git.isBusy && git.availability == .ready && !(git.snapshot?.isClean ?? true), action: focusCommitMessage),
        ]
    }
}
