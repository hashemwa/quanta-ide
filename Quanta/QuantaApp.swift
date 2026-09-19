import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        let app = AppState.shared
        for url in urls {
            if url.hasDirectoryPath {
                app.openWorkspace(url)
            } else {
                app.openFile(url)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppState.shared.confirmDiscardingUnsavedChanges() else { return .terminateCancel }
        AppState.shared.terminal.stop()
        AppState.shared.kernel.stop()
        return .terminateNow
    }
}

@main
struct QuantaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        Window("Quanta", id: "main") {
            MainWindowView()
                .environmentObject(appState)
                .frame(minWidth: 800, minHeight: 520)
                .background(WindowFrameSaver())
                .preferredColorScheme(previewColorScheme)
        }
        .windowToolbarStyle(.unified)
        .commands {
            QuantaCommands(app: appState, git: appState.git, selection: appState.selection)
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }

    private var previewColorScheme: ColorScheme? {
        guard QuantaDefaults.previewDirectory != nil,
              let appearance = ProcessInfo.processInfo.environment["QUANTA_UI_PREVIEW_APPEARANCE"] else { return nil }
        return appearance == "light" ? .light : .dark
    }
}

private struct WindowFrameSaver: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if QuantaDefaults.previewDirectory != nil {
                let width = Double(ProcessInfo.processInfo.environment["QUANTA_UI_PREVIEW_WIDTH"] ?? "1280") ?? 1280
                view.window?.setContentSize(NSSize(width: width, height: width < 1280 ? 700 : 800))
            } else {
                view.window?.setFrameAutosaveName("QuantaMainWindow")
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct QuantaCommands: Commands {
    @ObservedObject var app: AppState
    @ObservedObject var git: SourceControlState
    @ObservedObject var selection: CellSelection

    var body: some Commands {
        CommandMenu("Navigate") {
            Button("Back") { app.navigateHistory(-1) }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!app.canNavigateBack)
            Button("Forward") { app.navigateHistory(1) }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!app.canNavigateForward)
            Divider()
            Button("Quick Open…") { app.paletteMode = .files }
                .keyboardShortcut("p", modifiers: .command)
            Button("Command Palette…") { app.paletteMode = .commands }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Button("Reopen Closed Tab") { app.reopenClosedDocument() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(app.closedDocuments.isEmpty)
            Button("Toggle Split Editor") { app.toggleSplitEditor() }
                .keyboardShortcut("\\", modifiers: .command)
                .disabled(app.activeDocument == nil)
            Button("Pin / Unpin Tab") { if let document = app.activeDocument { app.togglePin(document) } }
                .disabled(app.activeDocument == nil)
            Divider()
            Button("Show Terminal") { app.showTerminal() }
                .keyboardShortcut("`", modifiers: .control)
            Button("New Terminal Session…") { app.newTerminalSession() }
            Button("Show Python Console") { app.showPythonConsole() }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Notebook") { app.newNotebook() }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Python File") { app.newScript() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New File…") {
                if let root = app.workspace?.rootURL { app.createFile(in: root) }
            }
            .disabled(app.workspace == nil)
            Button("New Folder…") {
                if let root = app.workspace?.rootURL { app.createFolder(in: root) }
            }
            .disabled(app.workspace == nil)
            Divider()
            Button("Open…") { app.openFilePanel() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Open Folder…") { app.openFolderPanel() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Menu("Open Recent") {
                if !app.recentWorkspaces.isEmpty {
                    Section("Workspaces") {
                        ForEach(app.recentWorkspaces, id: \.self) { path in
                            Button(abbreviate(path)) {
                                app.openWorkspace(URL(fileURLWithPath: path))
                            }
                        }
                    }
                }
                if !app.recentFiles.isEmpty {
                    Section("Files") {
                        ForEach(app.recentFiles, id: \.self) { path in
                            Button(URL(fileURLWithPath: path).lastPathComponent) {
                                app.openFile(URL(fileURLWithPath: path))
                            }
                        }
                    }
                }
                if app.recentWorkspaces.isEmpty && app.recentFiles.isEmpty {
                    Text("No Recent Items")
                }
                Divider()
                Button("Clear Menu") { app.clearRecents() }
            }
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { app.saveActiveDocument() }
                .keyboardShortcut("s", modifiers: .command)
            Button("Close Tab") { app.closeActiveTabOrWindow() }
                .keyboardShortcut("w", modifiers: .command)
            Divider()
            Menu("Export Notebook") {
                Button("As Python Script…") { app.exportActiveNotebookAsPython() }
                Button("As HTML…") { app.exportActiveNotebookAsHTML() }
                Button("As PDF…") { app.exportActiveNotebookAsPDF() }
            }
            .disabled(app.activeDocument?.kind != .notebook)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find…") { app.openFind() }
                .keyboardShortcut("f", modifiers: .command)
            Button("Find Next") {
                if let document = app.activeDocument { app.findAdvance(in: document, delta: 1) }
            }
            .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous") {
                if let document = app.activeDocument { app.findAdvance(in: document, delta: -1) }
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            Divider()
            Button("Toggle Comment") { app.toggleCommentInFocusedEditor() }
                .keyboardShortcut("/", modifiers: .command)
                .disabled(!app.activeDocumentIsEditable)
            Divider()
            Button("Find in Files…") { app.focusFileSearch() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(app.workspace == nil)
        }
        CommandMenu("Cell") {
            Button("Insert Cell Above") { app.commandInsert(offset: 0) }
                .disabled(!app.hasSelectedCell)
            Button("Insert Cell Below") { app.commandInsert(offset: 1) }
                .disabled(!app.hasSelectedCell)
            Divider()
            Button("Copy Cell") { app.commandCopy() }
                .disabled(!app.hasSelectedCell)
            Button("Cut Cell") { app.commandCut() }
                .disabled(!app.hasSelectedCell)
            Button("Paste Cell Below") { app.commandPaste() }
                .disabled(!app.hasSelectedCell)
            Button("Duplicate Cell") { app.commandDuplicate() }
                .disabled(!app.hasSelectedCell)
            Button("Undo Delete Cell") {
                if let document = app.activeDocument { app.undoCellDeletion(in: document) }
            }
            .keyboardShortcut("z", modifiers: [.command, .option])
            .disabled(!app.canUndoCellDeletion)
            Divider()
            Button("Delete Cell", role: .destructive) { app.commandDelete() }
                .disabled(!app.hasSelectedCell)
            Button("Convert to Markdown") { app.commandConvert(to: .markdown) }
                .disabled(!app.hasSelectedCell)
            Button("Convert to Code") { app.commandConvert(to: .code) }
                .disabled(!app.hasSelectedCell)
            Divider()
            Button("Split Cell at Cursor") { app.splitSelectedCell() }
                .keyboardShortcut("-", modifiers: [.control, .shift])
                .disabled(!app.hasSelectedCell)
            Button("Merge Cell With Below") { app.mergeSelectedCellWithBelow() }
                .disabled(!app.canMergeSelectedCellWithBelow)
            Divider()
            Button("Clear All Outputs") { app.clearAllOutputs(in: app.activeDocument) }
                .disabled(app.activeDocument?.kind != .notebook)
        }
        CommandMenu("Run") {
            Button("Run Cell") { app.runSelectedCell() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!app.activeDocumentIsRunnable)
            Button("Run Cell and Advance") { app.runSelectedCell(advance: true) }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(!app.activeDocumentIsRunnable)
            Button("Run Selection or Line") { app.runSelectionOrLine() }
                .disabled(app.activeDocument?.kind != .script)
            Button(app.runCommandTitle) { app.runActiveDocument() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(app.activeDocument == nil)
            Button("Restart Kernel and Run All") { app.restartAndRunAll() }
                .disabled(app.activeDocument?.kind != .notebook)
            Divider()
            Button("Interrupt Execution") { app.interruptKernel() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(app.kernelStatus != .busy)
            Button("Restart Kernel") { app.restartKernel() }
                .keyboardShortcut("r", modifiers: [.command, .control])
        }
        CommandMenu("Source Control") {
            Button("Commit…") { app.focusCommitMessage() }
                .keyboardShortcut("c", modifiers: [.command, .control])
                .disabled(git.availability != .ready || (git.snapshot?.isClean ?? true))
            Button("Commit Changes") { app.commit() }
                .keyboardShortcut(.return, modifiers: [.command, .option])
                .disabled(git.isBusy || (git.snapshot?.staged.isEmpty ?? true)
                          || !(git.snapshot?.conflicted.isEmpty ?? true))
            Button("Stage All and Commit…") { app.stageAllAndCommit() }
                .disabled(git.isBusy || (git.snapshot?.unstaged.isEmpty ?? true)
                          || !(git.snapshot?.conflicted.isEmpty ?? true))
            Button("Stage All Changes") { app.stageAllChanges() }
                .disabled(git.isBusy || (git.snapshot?.unstaged.isEmpty ?? true))
            Button("Unstage All Changes") { app.unstageAllChanges() }
                .disabled(git.isBusy || (git.snapshot?.staged.isEmpty ?? true))
            Button("Mark All Resolved") { app.markAllResolved() }
                .disabled(git.isBusy || (git.snapshot?.conflicted.isEmpty ?? true))
            Button("Discard All Changes…", role: .destructive) { app.discardAllChanges() }
                .disabled(git.isBusy || (git.snapshot?.unstaged.isEmpty ?? true))
            Button("Discard Output-Only Changes…", role: .destructive) { app.discardOutputOnlyChanges() }
                .disabled(git.isBusy || (git.snapshot?.hiddenNotebooks.isEmpty ?? true))
            Divider()
            Button("Fetch") { app.fetch() }
                .disabled(!git.canFetch)
            Button("Pull") { app.pull() }
                .disabled(!git.canPull)
            Button("Push") { app.push() }
                .disabled(!git.canPush)
            Divider()
            Button("New Branch…") { app.createBranch() }
                .disabled(git.availability != .ready || git.isBusy)
            Divider()
            Button(showChangesTitle) { app.openDiffForActiveDocument() }
                .disabled(git.availability != .ready || app.activeDocument?.url == nil
                          || !(app.activeDocument?.isFileBacked ?? false))
            Button("Refresh Status") { app.refreshSourceControl() }
                .disabled(git.availability == .noWorkspace || git.availability == .gitMissing)
        }
        CommandGroup(after: .sidebar) {
            Button("Show \(SidebarPane.files.title)") { app.showSidebarPane(.files) }
                .keyboardShortcut("1", modifiers: .command)
            Button("Show \(SidebarPane.search.title)") { app.showSidebarPane(.search) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Show \(SidebarPane.sourceControl.title)") { app.showSidebarPane(.sourceControl) }
                .keyboardShortcut("2", modifiers: .command)
            Button("Refresh File Tree") { app.refreshWorkspace() }
                .disabled(app.workspace == nil)
            Divider()
            Button(app.showVariables ? "Hide Variables" : "Show Variables") { app.toggleVariables() }
                .keyboardShortcut("0", modifiers: [.command, .option])
            Button(app.showConsole ? "Hide Bottom Panel" : "Show Bottom Panel") { app.toggleConsole() }
                .keyboardShortcut("y", modifiers: [.command, .shift])
            Button("Focus Console") { app.focusConsoleInput() }
                .keyboardShortcut("y", modifiers: [.command, .option])
            Button(app.bottomPane == .terminal ? "Clear Terminal Scrollback" : "Clear Console") {
                if app.bottomPane == .terminal { app.terminal.clear() } else { app.console.clear() }
            }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
            Button("Open Plot in Separate Window") { app.openSelectedPlotWindow() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(!app.selectedCellHasPlot)
            Divider()
            Button("Show Next Tab") { app.selectTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(app.openDocuments.count < 2)
            Button("Show Previous Tab") { app.selectTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(app.openDocuments.count < 2)
            Divider()
            Button("Increase Font Size") { app.adjustFontSize(1) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Decrease Font Size") { app.adjustFontSize(-1) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Reset Font Size") { app.resetFontSize() }
                .keyboardShortcut("0", modifiers: .command)
        }
    }

    private func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private var showChangesTitle: String {
        if let document = app.activeDocument, document.isFileBacked, document.url != nil {
            return "Show Changes for \(document.displayName)"
        }
        return "Show Changes"
    }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @AppStorage("QuantaAutoSaveFiles") private var autoSaveFiles = false
    @AppStorage("QuantaReopenSession") private var reopenSession = true
    @AppStorage("QuantaSuppressRestartConfirm") private var suppressRestartConfirm = false
    @AppStorage(SourceControlState.hideOutputOnlyKey) private var hideOutputOnlyNotebooks = true

    var body: some View {
        TabView {
            Form {
                Section {
                    Toggle("Reopen last session at launch", isOn: $reopenSession)
                    Toggle("Auto-save files every 5 seconds", isOn: $autoSaveFiles)
                } footer: {
                    Text("With auto-save off, Quanta still keeps crash-safe drafts of unsaved changes and offers to restore them.")
                }
                Section("Kernel") {
                    Picker("Python interpreter", selection: Binding(
                        get: { app.pythonPath ?? "" },
                        set: { if !$0.isEmpty { app.selectPython($0) } })) {
                        ForEach(app.environments) { env in
                            Text(env.name).tag(env.executable)
                        }
                        if let path = app.pythonPath, !app.environments.contains(where: { $0.executable == path }) {
                            Text((path as NSString).abbreviatingWithTildeInPath).tag(path)
                        }
                    }
                    Toggle("Confirm before restarting the kernel",
                           isOn: Binding(get: { !suppressRestartConfirm },
                                         set: { suppressRestartConfirm = !$0 }))
                }
                Section {
                    Toggle("Hide notebooks whose only changes are outputs", isOn: $hideOutputOnlyNotebooks)
                        .onChange(of: hideOutputOnlyNotebooks) { _, _ in app.refreshSourceControl() }
                } header: {
                    Text("Source Control")
                } footer: {
                    Text("Running a notebook changes outputs, execution counts and metadata. With this on, the Source Control panel only lists a notebook when its cell sources differ.")
                }
                Section("Navigator") {
                    Toggle("Show hidden files", isOn: $app.showsHiddenFiles)
                }
                Section("Window") {
                    LabeledContent("Sidebar, inspector and panel sizes") {
                        Button("Reset Layout") { app.resetLayout() }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 480)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section {
                    LabeledContent("Editor font size") {
                        HStack(spacing: 8) {
                            Stepper(value: Binding(
                                get: { app.editorFontSize },
                                set: { app.setFontSize($0) }), in: 9...28) {
                                Text("\(Int(app.editorFontSize)) pt").monospacedDigit()
                            }
                            Button("Reset") { app.resetFontSize() }
                                .disabled(app.editorFontSize == 13)
                        }
                    }
                    Toggle("Show line numbers", isOn: $app.showsLineNumbers)
                    Toggle("Wrap long lines", isOn: $app.wrapsCode)
                } footer: {
                    Text("⌘+ and ⌘− adjust the size from the keyboard; outputs, tables and the console follow.")
                }
            }
            .formStyle(.grouped)
            .frame(width: 480)
            .tabItem { Label("Editor", systemImage: "textformat.size") }
        }
    }
}
