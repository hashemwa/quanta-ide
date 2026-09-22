import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var paletteMode: PaletteMode?
    @Published var bottomPane: BottomPane = .console
    let terminal = TerminalSession()
    @Published var closedDocuments: [URL] = []
    @Published var splitDocumentID: UUID?
    @Published var primarySplitDocumentID: UUID?
    @Published var userNotice: String?
    @Published var externallyChangedDocumentID: UUID?
    @Published var changedVariables: Set<String> = []
    @Published var workspace: Workspace?
    @Published var openDocuments: [Document] = []
    @Published var activeDocumentID: UUID? {
        didSet {
            guard activeDocumentID != oldValue else { return }
            if splitDocumentID != nil, activeDocumentID != splitDocumentID {
                primarySplitDocumentID = activeDocumentID
            }
            rebindCellSelection(from: oldValue)
            recordNavigation(activeDocumentID)
            persistSession()
        }
    }
    @Published private(set) var canNavigateBack = false
    @Published private(set) var canNavigateForward = false
    private var navigationHistory: [UUID] = []
    private var navigationIndex = -1
    private var isNavigatingHistory = false
    @Published var variables: [VariableInfo] = []
    let console = ConsoleModel()
    let plots = PlotHistory()
    let dataBrowser = DataBrowser()
    @Published var kernelStatus: KernelStatus = .stopped
    let selection = CellSelection()
    var selectedCellID: UUID? {
        get { selection.selectedCellID }
        set {
            guard selection.selectedCellID != newValue else { return }
            selection.selectedCellID = newValue
            if let newValue, !selection.selectedCellIDs.contains(newValue) {
                selection.selectedCellIDs = [newValue]
                selection.anchorCellID = newValue
            } else if newValue == nil {
                selection.selectedCellIDs = []
                selection.anchorCellID = nil
            }
        }
    }
    var isCommandMode: Bool {
        get { selection.isCommandMode }
        set { if selection.isCommandMode != newValue { selection.isCommandMode = newValue } }
    }
    @Published var showVariables = QuantaDefaults.store.object(forKey: "QuantaShowVariables") as? Bool ?? true {
        didSet { QuantaDefaults.store.set(showVariables, forKey: "QuantaShowVariables") }
    }
    @Published var showConsole = QuantaDefaults.store.object(forKey: "QuantaShowConsole") as? Bool ?? false {
        didSet {
            QuantaDefaults.store.set(showConsole, forKey: "QuantaShowConsole")
            if showConsole { consoleRevealPending = false }
        }
    }
    @Published var consoleHeight: CGFloat =
        QuantaDefaults.store.object(forKey: "QuantaConsoleHeight") as? CGFloat ?? DS.Layout.consoleDefaultHeight {
        didSet { QuantaDefaults.store.set(consoleHeight, forKey: "QuantaConsoleHeight") }
    }
    @Published var editorSplitFraction: CGFloat =
        QuantaDefaults.store.object(forKey: "QuantaEditorSplitFraction") as? CGFloat ?? 0.5 {
        didSet { QuantaDefaults.store.set(editorSplitFraction, forKey: "QuantaEditorSplitFraction") }
    }
    private lazy var consoleUserHidden = !showConsole
    @Published var consoleRevealPending = false
    @Published var isExportingPDF = false
    @Published var workspaceTrustRequest: URL?
    @Published var kernelTransition: KernelTransition?
    @Published var pythonPath: String?
    @Published var kernelBanner = "No kernel"
    @Published var environments: [PythonEnvironment] = []
    @Published var environmentVersions: [String: String] = [:]
    let latex = LatexState()
    let git = SourceControlState()
    @Published var sidebarPane: SidebarPane =
        SidebarPane(rawValue: QuantaDefaults.store.string(forKey: "QuantaSidebarPane") ?? "") ?? .files {
        didSet { QuantaDefaults.store.set(sidebarPane.rawValue, forKey: "QuantaSidebarPane") }
    }
    @Published var sidebarRevealRequest = 0
    @Published var fileSearchFocusRequest = 0
    @Published var showsHiddenFiles = QuantaDefaults.store.bool(forKey: "QuantaShowsHiddenFiles") {
        didSet {
            QuantaDefaults.store.set(showsHiddenFiles, forKey: "QuantaShowsHiddenFiles")
            refreshWorkspace()
        }
    }
    @Published var showsLineNumbers = QuantaDefaults.store.object(forKey: "QuantaShowsLineNumbers") as? Bool ?? true {
        didSet { QuantaDefaults.store.set(showsLineNumbers, forKey: "QuantaShowsLineNumbers") }
    }
    @Published var wrapsCode = QuantaDefaults.store.object(forKey: "QuantaWrapsCode") as? Bool ?? true {
        didSet { QuantaDefaults.store.set(wrapsCode, forKey: "QuantaWrapsCode") }
    }
    @Published var adaptsPlotTheme = QuantaDefaults.store.object(forKey: "QuantaAdaptsPlotTheme") as? Bool ?? true {
        didSet {
            QuantaDefaults.store.set(adaptsPlotTheme, forKey: "QuantaAdaptsPlotTheme")
            pushAppearance()
        }
    }
    @Published private(set) var cellRevision = 0
    var handledFileSearchFocusRequest = 0

    let kernel = KernelSession()
    private var bootstrapped = false
    private var versionProbesInFlight = Set<String>()
    private var latexCache: [String: LatexResult] = [:]
    private var latexPending: [String: [(LatexResult) -> Void]] = [:]

    var activeDocument: Document? {
        openDocuments.first { $0.id == activeDocumentID }
    }

    init() {
        kernel.onStatusChange = { [weak self] status in
            self?.kernelStatusChanged(status)
        }
        kernel.onOrphanMessage = { [weak self] message in
            self?.handleOrphan(message)
        }
        configureSourceControl()
    }

    func bootstrap() {
        guard !bootstrapped, !QuantaDefaults.isRunningTests else { return }
        bootstrapped = true
        if let preview = QuantaDefaults.previewDirectory {
            openWorkspace(preview.appendingPathComponent("Workspace", isDirectory: true))
            openFile(preview.appendingPathComponent("Workspace/Example.ipynb"))
            return
        }
        loadRecents()
        EditorTheme.fontSize = editorFontSize
        if let path = QuantaDefaults.store.string(forKey: "QuantaLastWorkspace") {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                openWorkspace(URL(fileURLWithPath: path))
            }
        }
        restoreSession()
        restoreUntitledDrafts()
        startAutosave()
        startKernelIfNeeded()
        let condaCount = environments.filter { $0.kind == .conda }.count
        appendConsole(.system, "Discovered \(environments.count) Python environments"
            + (condaCount > 0 ? " (\(condaCount) conda)" : ""))
    }

    func refreshEnvironments() {
        environments = PythonLocator.discover(workspace: workspace?.rootURL)
        probeVersions()
    }

    private func probeVersions() {
        guard isWorkspaceTrusted else { return }
        for env in environments
        where WorkspaceTrust.allows(env, workspace: workspace?.rootURL)
            && environmentVersions[env.executable] == nil
            && !versionProbesInFlight.contains(env.executable) {
            versionProbesInFlight.insert(env.executable)
            let executable = env.executable
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let version = PythonLocator.probeVersion(executable)
                DispatchQueue.main.async {
                    self?.versionProbesInFlight.remove(executable)
                    self?.environmentVersions[executable] = version ?? ""
                }
            }
        }
    }

    private func kernelScriptURL() -> URL? {
        Bundle.main.url(forResource: "quanta_kernel", withExtension: "py")
            ?? Bundle.main.url(forResource: "quanta_kernel", withExtension: "py",
                               subdirectory: "Resources")
    }

    func startKernelIfNeeded() {
        guard !kernel.isRunning else { return }
        startKernel()
    }

    func startKernel() {
        guard isWorkspaceTrusted, kernelTransition == nil else { return }
        guard let script = kernelScriptURL() else {
            appendConsole(.system, "Internal error: quanta_kernel.py missing from the app bundle.")
            return
        }
        refreshEnvironments()
        let allowed = environments.filter { WorkspaceTrust.allows($0, workspace: workspace?.rootURL) }
        let chosen: String?
        if let selected = pythonPath {
            chosen = allowed.first { $0.executable == selected }?.executable
            if chosen == nil {
                kernelBanner = "Interpreter unavailable"
                userNotice = "The selected Python interpreter is unavailable or not trusted in this workspace. Choose an interpreter from the kernel menu."
                return
            }
        } else {
            chosen = PythonLocator.preferred(from: allowed)?.executable
        }
        guard let python = chosen else {
            kernelBanner = "No Python found"
            appendConsole(.system, "No Python 3 interpreter found. Install one (python.org, Homebrew, or conda) and pick it from the kernel menu.")
            return
        }
        pythonPath = python
        appendConsole(.system, "Starting kernel: \(python)")
        kernel.start(python: python, scriptURL: script,
                     workingDirectory: workspace?.rootURL ?? FileManager.default.homeDirectoryForCurrentUser)
    }

    func setConsoleVisible(_ visible: Bool, animated: Bool = true) {
        guard visible != showConsole else { return }
        consoleUserHidden = !visible
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            withAnimation(DS.Motion.quick) { showConsole = visible }
        } else {
            showConsole = visible
        }
    }

    func toggleConsole() {
        if !showConsole && consoleRevealPending { bottomPane = .console }
        setConsoleVisible(!showConsole)
    }

    func focusConsoleInput() {
        bottomPane = .console
        setConsoleVisible(true)
        console.focusRequest += 1
    }

    func setVariablesVisible(_ visible: Bool) {
        guard visible != showVariables else { return }
        showVariables = visible
    }

    func toggleVariables() { setVariablesVisible(!showVariables) }

    func resetLayout() {
        showVariables = true
        setConsoleVisible(false, animated: false)
        consoleHeight = DS.Layout.consoleDefaultHeight
        splitDocumentID = nil
        primarySplitDocumentID = nil
        sidebarRevealRequest += 1
    }

    func revealConsole(force: Bool = false) {
        if force { bottomPane = .console }
        if showConsole { return }
        if force || !consoleUserHidden {
            consoleUserHidden = false
            setConsoleVisible(true)
        } else {
            consoleRevealPending = true
        }
    }

    func restartKernel(confirm: Bool = true) {
        guard allowExecution() else { return }
        if confirm, !variables.isEmpty,
           !QuantaDefaults.store.bool(forKey: "QuantaSuppressRestartConfirm") {
            let alert = NSAlert()
            alert.messageText = "Restart the Python kernel?"
            alert.informativeText = "All \(variables.count) variable\(variables.count == 1 ? "" : "s") in memory will be lost."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Restart")
            alert.addButton(withTitle: "Cancel")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't ask again"
            let proceed = { [weak self] (response: NSApplication.ModalResponse) in
                guard let self, response == .alertFirstButtonReturn else { return }
                if alert.suppressionButton?.state == .on {
                    QuantaDefaults.store.set(true, forKey: "QuantaSuppressRestartConfirm")
                }
                self.performKernelRestart()
            }
            if let window = NSApp.keyWindow {
                alert.beginSheetModal(for: window, completionHandler: proceed)
            } else {
                proceed(alert.runModal())
            }
            return
        }
        performKernelRestart()
    }

    private func performKernelRestart() {
        kernel.stop()
        variables = []
        clearRunningFlags()
        appendConsole(.system, "Restarting kernel…")
        startKernel()
    }

    func selectTab(offset: Int) {
        guard !openDocuments.isEmpty else { return }
        let current = openDocuments.firstIndex { $0.id == activeDocumentID } ?? 0
        let count = openDocuments.count
        let next = ((current + offset) % count + count) % count
        activeDocumentID = openDocuments[next].id
    }

    private func recordNavigation(_ id: UUID?) {
        guard !isNavigatingHistory, let id else { return }
        if navigationIndex >= 0, navigationIndex < navigationHistory.count,
           navigationHistory[navigationIndex] == id { return }
        if navigationIndex + 1 < navigationHistory.count {
            navigationHistory.removeSubrange((navigationIndex + 1)...)
        }
        navigationHistory.append(id)
        if navigationHistory.count > 100 { navigationHistory.removeFirst() }
        navigationIndex = navigationHistory.count - 1
        updateNavigationAvailability()
    }

    func navigateHistory(_ delta: Int) {
        var target = navigationIndex + delta
        while target >= 0, target < navigationHistory.count {
            let id = navigationHistory[target]
            if openDocuments.contains(where: { $0.id == id }) {
                isNavigatingHistory = true
                navigationIndex = target
                activeDocumentID = id
                isNavigatingHistory = false
                updateNavigationAvailability()
                return
            }
            target += delta
        }
    }

    private func updateNavigationAvailability() {
        canNavigateBack = navigationIndex > 0
        canNavigateForward = navigationIndex >= 0 && navigationIndex + 1 < navigationHistory.count
    }

    func closeOtherDocuments(except document: Document) {
        for other in openDocuments where other.id != document.id && !other.isPinned {
            guard closeDocument(other, persist: false) else { break }
        }
        persistSession()
    }

    func interruptActiveExecution() {
        if let session = activeDocument?.dataSession { session.stop() }
        else { interruptKernel() }
    }

    func interruptKernel() {
        if let id = runningChainDocumentID,
           let document = openDocuments.first(where: { $0.id == id }) {
            endRunChain(in: document)
        }
        pausedRunDocumentID = nil
        pausedRunCellIDs = []
        kernel.interrupt()
    }

    func selectPython(_ path: String) {
        guard allowExecution() else { return }
        let transition = KernelTransition(workspace: workspace?.rootURL, python: path,
                                          rememberInterpreter: true)
        if kernel.isRunning {
            kernelTransition = transition
        } else {
            applyKernelTransition(transition)
        }
    }

    func choosePythonManually() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.message = "Select a Python 3 interpreter"
        if panel.runModal() == .OK, let url = panel.url {
            selectPython(url.path)
        }
    }

    func pushAppearance() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        kernel.notify(["op": "config", "appearance": dark ? "dark" : "light", "adapt_plot_theme": adaptsPlotTheme])
    }

    private func clearRunningFlags() {
        runningChainDocumentID = nil
        for document in openDocuments {
            document.notebook?.cells.forEach {
                $0.isRunning = false
                $0.isQueued = false
            }
        }
    }

    private func kernelStatusChanged(_ status: KernelStatus) {
        kernelStatus = status
        if status == .dead {
            userNotice = "The Python kernel stopped unexpectedly. Restart it from the interpreter menu, then rerun the cells you need."
            clearRunningFlags()
            cancelPendingRunAll()
            variables = []
            revealConsole()
        }
        if status == .idle { kernelBecameIdle() }
        updateBanner()
    }

    private func updateBanner() {
        if let info = kernel.readyInfo, let version = info["python_version"] as? String {
            kernelBanner = "Python \(version) · \(kernelStatus.label)"
        } else {
            kernelBanner = kernelStatus.label
        }
    }

    var environmentName: String {
        guard let path = pythonPath else { return "No interpreter" }
        if let env = environments.first(where: { $0.executable == path }) { return env.name }
        let url = URL(fileURLWithPath: path)
        let generic: Set<String> = ["", "/", "usr", "local", "opt", "bin", "Cellar",
                                    "homebrew", "Library", "System", "Frameworks"]
        if url.deletingLastPathComponent().lastPathComponent == "bin" {
            let name = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            if !generic.contains(name) { return name }
        }
        return url.lastPathComponent
    }

    var kernelPythonVersion: String? {
        kernel.readyInfo?["python_version"] as? String
    }

    private func handleOrphan(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "ready":
            updateBanner()
            latexCache = latexCache.filter {
                if case .image = $0.value { return true }
                return false
            }
            var features: [String] = []
            if let f = message["features"] as? [String: Bool] {
                features = f.filter { $0.value }.map { $0.key }.sorted()
            }
            if let version = message["python_version"] as? String {
                let suffix = features.isEmpty ? "" : " (\(features.joined(separator: ", ")))"
                appendConsole(.system, "Kernel ready — Python \(version)\(suffix)")
            }
            latex.generation += 1
            pushAppearance()
            refreshVariables()
            if let jsPath = message["plotly_js"] as? String {
                PlotlyWebView.preloadScript(at: jsPath)
            }
        case "stream":
            if let text = message["text"] as? String {
                let name = message["name"] as? String ?? "stdout"
                appendConsole(name == "stderr" ? .stderr : .stdout, text)
            }
        case "fatal":
            if let error = message["error"] as? String {
                appendConsole(.stderr, error)
            }
        default:
            break
        }
    }

    func appendConsole(_ kind: ConsoleLine.Kind, _ text: String) {
        console.append(kind, text)
        if kind == .system, !showConsole { consoleRevealPending = true }
    }

    func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            openWorkspace(url)
        }
    }

    private var workspaceWatcher: WorkspaceWatcher?

    func openWorkspace(_ url: URL) {
        for document in openDocuments where document.kind == .diff {
            closeDocument(document, persist: false)
        }
        workspace = Workspace(rootURL: url, root: FileNode(url: url, name: url.lastPathComponent,
                                                             isDirectory: true, children: []))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let loaded = Workspace.load(url: url, showsHiddenFiles: self.showsHiddenFiles)
            DispatchQueue.main.async {
                guard self.workspace?.rootURL == url else { return }
                self.workspace = loaded
            }
        }
        git.setWorkspace(url)
        QuantaDefaults.store.set(url.path, forKey: "QuantaLastWorkspace")
        recordRecent(url.path, isWorkspace: true)
        workspaceWatcher = WorkspaceWatcher(url: url) { [weak self] in
            self?.refreshWorkspace()
        }
        kernelTransition = nil
        workspaceTrustRequest = nil
        refreshEnvironments()
        if isWorkspaceTrusted {
            synchronizeWorkspaceKernel()
        } else {
            workspaceTrustRequest = url
            appendConsole(.system, "Restricted workspace: Python probing and execution are disabled until you trust this folder.")
        }
    }

    private var workspaceRefreshScheduled = false

    var hasSelectedCell: Bool {
        selectionContext != nil
    }

    var selectedCellHasPlot: Bool {
        guard let ctx = selectionContext else { return false }
        return ctx.cell.outputs.contains { output in
            switch output.kind {
            case .image, .plotlyFigure: return true
            default: return false
            }
        }
    }

    var canMergeSelectedCellWithBelow: Bool {
        guard let document = activeDocument, let notebook = document.notebook,
              let index = notebook.cells.firstIndex(where: { $0.id == selectedCellID })
        else { return false }
        return index + 1 < notebook.cells.count
    }

    var canUndoCellDeletion: Bool {
        !(activeDocument?.deletedCells.isEmpty ?? true)
    }

    var activeDocumentIsRunnable: Bool {
        switch activeDocument?.kind {
        case .script, .notebook: return true
        default: return false
        }
    }

    var activeDocumentIsEditable: Bool {
        switch activeDocument?.kind {
        case .script, .notebook: return true
        default: return false
        }
    }

    var focusedEditor: QuantaTextView? {
        NSApp.keyWindow?.firstResponder as? QuantaTextView
    }

    func toggleCommentInFocusedEditor() {
        focusedEditor?.toggleComment()
    }

    func deleteVariable(named name: String) {
        confirmDestructive(
            title: "Delete “\(name)”?",
            message: "\(name) is removed from the kernel namespace. "
                + "You will have to re-run the code that created it.",
            button: "Delete") { [weak self] in
            self?.runConsoleInput("del \(name)")
            self?.refreshVariables()
        }
    }

    func focusFileSearch() {
        showSidebarPane(.search)
        fileSearchFocusRequest += 1
    }

    func refreshWorkspace() {
        guard let url = workspace?.rootURL, !workspaceRefreshScheduled else { return }
        workspaceRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.workspaceRefreshScheduled = false
            guard self.workspace?.rootURL == url else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let loaded = Workspace.load(url: url, showsHiddenFiles: self.showsHiddenFiles)
                DispatchQueue.main.async {
                    guard self.workspace?.rootURL == url else { return }
                    self.workspace = loaded
                    self.git.refresh()
                    self.reloadExternallyChangedDocuments()
                }
            }
        }
    }

    func openFilePanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            openFile(url)
        }
    }

    func openFile(_ url: URL, recordSession: Bool = true) {
        if let source = LocalDataSource(url: url) { openData(source); return }
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        if let existing = openDocuments.first(where: {
            $0.url?.resolvingSymlinksInPath().standardizedFileURL == resolvedURL
        }) {
            activeDocumentID = existing.id
            return
        }
        do {
            let source = restorableDraft(for: url) ?? url
            if url.pathExtension.lowercased() == "ipynb" {
                let data = try Data(contentsOf: source)
                let notebook = try Notebook.load(from: data)
                let document = Document(notebook: notebook, url: url)
                document.fileModificationDate = fileModificationDate(of: url)
                if source != url { document.isDirty = true }
                openDocuments.append(document)
                activeDocumentID = document.id
                selectedCellID = notebook.cells.first?.id
            } else {
                let text = try String(contentsOf: source, encoding: .utf8)
                let document = Document(script: url, text: text)
                document.fileModificationDate = fileModificationDate(of: url)
                if source != url { document.isDirty = true }
                openDocuments.append(document)
                activeDocumentID = document.id
            }
            if recordSession {
                recordRecent(url.path, isWorkspace: false)
                persistSession()
            }
            startKernelIfNeeded()
        } catch {
            appendConsole(.system, "Could not open \(url.lastPathComponent): \(error.localizedDescription)")
            revealConsole()
        }
    }

    private func restorableDraft(for url: URL) -> URL? {
        let draft = draftURL(forPath: url)
        let fm = FileManager.default
        guard fm.fileExists(atPath: draft.path),
              let draftDate = (try? fm.attributesOfItem(atPath: draft.path))?[.modificationDate] as? Date,
              let fileDate = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              draftDate > fileDate else { return nil }
        let alert = NSAlert()
        alert.messageText = "Restore unsaved changes to \(url.lastPathComponent)?"
        alert.informativeText = "Quanta kept a draft with edits newer than the file on disk."
        alert.addButton(withTitle: "Restore Draft")
        alert.addButton(withTitle: "Open Saved File")
        if alert.runModal() == .alertFirstButtonReturn {
            return draft
        }
        try? fm.removeItem(at: draft)
        return nil
    }

    func newNotebook() {
        let notebook = Notebook.empty()
        let document = Document(notebook: notebook, url: nil)
        document.isDirty = true
        openDocuments.append(document)
        activeDocumentID = document.id
        selectedCellID = notebook.cells.first?.id
        startKernelIfNeeded()
        if let first = notebook.cells.first { focusCellEditor(first.id) }
    }

    func newScript() {
        let document = Document(script: nil, text: "")
        document.isDirty = true
        openDocuments.append(document)
        activeDocumentID = document.id
        focusEditor(document.id)
    }

    @discardableResult
    func closeDocument(_ document: Document, persist: Bool = true) -> Bool {
        if document.isDirty, document.isFileBacked {
            switch promptToSave(document) {
            case .save:
                guard save(document) else { return false }
            case .discard:
                break
            case .cancel:
                return false
            }
        }
        if let url = document.url {
            closedDocuments.removeAll { $0 == url }
            closedDocuments.insert(url, at: 0)
            closedDocuments = Array(closedDocuments.prefix(20))
        }
        if splitDocumentID == document.id { splitDocumentID = nil; primarySplitDocumentID = nil }
        endRunChain(in: document)
        clearDraft(for: document)
        let position = openDocuments.firstIndex { $0.id == document.id } ?? openDocuments.count
        document.dataSession?.stop()
        openDocuments.removeAll { $0.id == document.id }
        if primarySplitDocumentID == document.id {
            primarySplitDocumentID = openDocuments.first { $0.id != splitDocumentID }?.id
            if primarySplitDocumentID == nil { splitDocumentID = nil }
        }
        if activeDocumentID == document.id {
            activeDocumentID = openDocuments.isEmpty
                ? nil
                : openDocuments[min(position, openDocuments.count - 1)].id
        }
        if persist { persistSession() }
        return true
    }

    @MainActor
    func closeActiveTabOrWindow() {
        if let window = NSApp.keyWindow, PlotWindow.owns(window) {
            window.performClose(nil)
            return
        }
        if let document = activeDocument { closeDocument(document) }
    }

    func saveActiveDocument() {
        if let document = activeDocument {
            _ = save(document)
        }
    }

    @discardableResult
    func save(_ document: Document, interactive: Bool = true) -> Bool {
        guard document.isFileBacked else { return true }
        var url = document.url
        if url == nil {
            let panel = NSSavePanel()
            panel.directoryURL = workspace?.rootURL
            panel.nameFieldStringValue = document.displayName
            let ext = document.kind == .notebook ? "ipynb" : "py"
            if let type = UTType(filenameExtension: ext) {
                panel.allowedContentTypes = [type]
            }
            guard panel.runModal() == .OK, let chosen = panel.url else { return false }
            url = chosen
        }
        guard let target = url else { return false }
        if document.url != nil, let known = document.fileModificationDate,
           let current = fileModificationDate(of: target), current > known {
            guard interactive, confirmOverwritingChangedFile(document) else { return false }
        }
        do {
            switch document.kind {
            case .script:
                try document.text.write(to: target, atomically: true, encoding: .utf8)
            case .notebook:
                guard let notebook = document.notebook else { return false }
                try notebook.serializedData().write(to: target, options: .atomic)
            case .dataSource, .dataFrame, .diff:
                break
            }
            clearDraft(for: document)
            document.url = target
            document.isDirty = false
            userNotice = nil
            document.fileModificationDate = fileModificationDate(of: target)
            clearDraft(for: document)
            persistSession()
            refreshWorkspace()
            return true
        } catch {
            userNotice = "Could not save \(document.displayName): \(error.localizedDescription). Your edits are still open; try Save again or save to another location."
            appendConsole(.system, "Save failed: \(error.localizedDescription)")
            revealConsole()
            return false
        }
    }

    private func confirmOverwritingChangedFile(_ document: Document) -> Bool {
        let alert = NSAlert()
        alert.messageText = "\(document.displayName) has changed on disk."
        alert.informativeText = "Saving will overwrite the version now on disk, for example after a branch switch or pull."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Overwrite").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    var runCommandTitle: String {
        switch activeDocument?.kind {
        case .notebook: return "Run All Cells"
        case .dataSource: return "Run Query"
        case .dataFrame: return "Reload Table"
        case .diff: return "Reload Changes"
        default: return "Run File"
        }
    }

    var runCommandIcon: String {
        switch activeDocument?.kind {
        case .dataFrame, .diff: return "arrow.clockwise"
        default: return "play.fill"
        }
    }

    var runCommandHelp: String {
        switch activeDocument?.kind {
        case .notebook: return "Run all cells (⌘R)"
        case .dataSource: return "Run query (⌘R)"
        case .dataFrame: return "Reload table (⌘R)"
        case .diff: return "Reload changes (⌘R)"
        default: return "Run file (⌘R)"
        }
    }

    func runActiveDocument() {
        if let document = activeDocument {
            runDocument(document)
        }
    }

    func runDocument(_ document: Document) {
        switch document.kind {
        case .script:
            runScript(document)
        case .notebook:
            runAllCells(in: document)
        case .dataSource:
            document.dataSession?.run()
        case .dataFrame:
            reloadDataFrame(document)
        case .diff:
            reloadDiff(document)
        }
    }

    func runScript(_ document: Document) {
        guard allowExecution() else { return }
        startKernelIfNeeded()
        guard kernel.isRunning else {
            revealConsole(force: true)
            appendConsole(.system, "Kernel is not running — cannot execute.")
            return
        }
        if document.url != nil && document.isDirty {
            guard save(document) else { return }
        }
        if bottomPane == .plots { setConsoleVisible(true) } else { revealConsole(force: true) }
        appendConsole(.input, "run \(document.displayName)")
        let plotOrigin = plots.beginRun(document: document)
        kernel.execute(code: document.text, filename: document.url?.path) { [weak self] message in
            guard let self else { return true }
            return self.handleConsoleExecution(message, plotOrigin: plotOrigin)
        }
    }

    func runConsoleInput(_ code: String) {
        guard allowExecution() else { return }
        startKernelIfNeeded()
        guard kernel.isRunning else {
            appendConsole(.system, "Kernel is not running — cannot execute.")
            return
        }
        appendConsole(.input, code)
        let plotOrigin = plots.beginRun(document: nil)
        kernel.execute(code: code) { [weak self] message in
            guard let self else { return true }
            return self.handleConsoleExecution(message, plotOrigin: plotOrigin)
        }
    }

    private func handleConsoleExecution(_ message: [String: Any], plotOrigin: PlotOrigin) -> Bool {
        switch message["type"] as? String {
        case "stream":
            let name = message["name"] as? String ?? "stdout"
            appendConsole(name == "stderr" ? .stderr : .stdout, message["text"] as? String ?? "")
        case "result":
            appendConsole(.result, message["text"] as? String ?? "")
        case "dataframe":
            if let dict = message["payload"] as? [String: Any],
               let payload = DataFramePayload(dict: dict) {
                appendConsole(.result, payload.text)
            }
        case "ndarray", "jsontree", "objectcard":
            let text = (message["text"] as? String)
                ?? ((message["payload"] as? [String: Any])?["text"] as? String)
                ?? ""
            appendConsole(.result, text)
        case "rich":
            if let bundle = message["mime_bundle"] as? [String: Any] {
                appendConsole(.result, RichOutput.text(bundle["text/plain"]))
                plots.consume(message, origin: plotOrigin)
            }
        case "plotlyhtml", "display":
            plots.consume(message, origin: plotOrigin)
        case "error":
            let ename = message["ename"] as? String ?? "Error"
            let evalue = message["evalue"] as? String ?? ""
            let traceback = message["traceback"] as? String ?? ""
            appendConsole(.stderr, traceback.isEmpty ? "\(ename): \(evalue)\n" : traceback)
        case "done":
            let ok = (message["status"] as? String) == "ok"
            appendConsole(.system, ok ? "✓ done" : "✗ finished with errors")
            refreshVariables()
            return true
        case "dead":
            appendConsole(.system, "Kernel died during execution.")
            return true
        default:
            break
        }
        return false
    }

    func runCell(_ cell: NotebookCell, in document: Document, advance: Bool,
                 completion: ((Bool) -> Void)? = nil) {
        guard cell.cellType == .code else {
            cell.isEditingMarkdown = false
            if advance { advanceSelection(after: cell, in: document) }
            completion?(true)
            return
        }
        guard allowExecution() else {
            completion?(false)
            return
        }
        startKernelIfNeeded()
        guard kernel.isRunning else {
            appendConsole(.system, "Kernel is not running — cannot execute.")
            revealConsole()
            completion?(false)
            return
        }
        guard !cell.isRunning else {
            completion?(false)
            return
        }
        if document.id == activeDocumentID { selectedCellID = cell.id }
        cell.lastExecutedSource = cell.source
        cell.outputs = []
        cell.isRunning = true
        cell.isQueued = false
        cell.runStartedAt = Date()
        document.isDirty = true
        let plotOrigin = plots.beginRun(document: document, cell: cell)
        kernel.execute(code: cell.source) { [weak self, weak cell, weak document] message in
            guard let self else { return true }
            guard let cell else {
                let type = message["type"] as? String
                return type == "done" || type == "dead"
            }
            let finished = self.handleCellExecution(message, cell: cell, document: document,
                                                    advance: advance, completion: completion)
            if let bundle = message["mime_bundle"] as? [String: Any], !cell.outputs.isEmpty {
                cell.outputs[cell.outputs.count - 1].raw = RichOutput.raw(bundle, metadata: message["metadata"] as? [String: Any] ?? [:])
            }
            if ["display", "plotlyhtml", "rich"].contains(message["type"] as? String ?? ""),
               let output = cell.outputs.last {
                self.plots.record(output, origin: plotOrigin)
            }
            return finished
        }
    }

    private func handleCellExecution(_ message: [String: Any], cell: NotebookCell,
                                     document: Document?, advance: Bool,
                                     completion: ((Bool) -> Void)?) -> Bool {
        switch message["type"] as? String {
        case "stream":
            let name = message["name"] as? String ?? "stdout"
            let text = message["text"] as? String ?? ""
            bufferStream(name: name, text: text, into: cell)
        case "result":
            flushStreams(into: cell)
            cell.outputs.append(CellOutput(kind: .executeResult(text: message["text"] as? String ?? "")))
        case "display":
            flushStreams(into: cell)
            if message["mime"] as? String == "image/png",
               let b64 = message["data"] as? String,
               let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) {
                cell.outputs.append(CellOutput(kind: .image(data: data, image: NSImage(data: data))))
            }
        case "rich":
            flushStreams(into: cell)
            if let bundle = message["mime_bundle"] as? [String: Any] {
                cell.outputs.append(CellOutput(kind: RichOutput.kind(bundle), raw: RichOutput.raw(bundle, metadata: message["metadata"] as? [String: Any] ?? [:])))
            }
        case "plotlyhtml":
            flushStreams(into: cell)
            if let html = message["html"] as? String,
               let jsPath = message["js_path"] as? String {
                let height = (message["height"] as? NSNumber)?.doubleValue ?? 450
                let hasPNG = (message["has_png"] as? Bool) ?? true
                if hasPNG, let last = cell.outputs.last,
                   case .image(let data, let image) = last.kind {
                    cell.outputs[cell.outputs.count - 1].kind = .plotlyFigure(
                        html: html, jsPath: jsPath, data: data, image: image, height: height)
                } else {
                    cell.outputs.append(CellOutput(kind: .plotlyFigure(
                        html: html, jsPath: jsPath, data: Data(), image: nil, height: height)))
                }
            }
        case "dataframe":
            flushStreams(into: cell)
            if let dict = message["payload"] as? [String: Any],
               let payload = DataFramePayload(dict: dict) {
                cell.outputs.append(CellOutput(kind: .dataFrame(payload)))
            }
        case "ndarray":
            flushStreams(into: cell)
            if let dict = message["payload"] as? [String: Any],
               let payload = NDArrayPayload(dict: dict) {
                cell.outputs.append(CellOutput(kind: .ndarray(payload)))
            }
        case "jsontree":
            flushStreams(into: cell)
            if let data = message["data"] {
                cell.outputs.append(CellOutput(kind: .jsonTree(JSONTreePayload(
                    value: data,
                    summary: message["summary"] as? String ?? "",
                    text: message["text"] as? String ?? ""))))
            }
        case "objectcard":
            flushStreams(into: cell)
            if let payload = ObjectCardPayload(dict: message) {
                cell.outputs.append(CellOutput(kind: .objectCard(payload)))
            }
        case "error":
            let frames = (message["frames"] as? [[String: Any]] ?? [])
                .compactMap(TraceFrame.init)
            flushStreams(into: cell)
            cell.outputs.append(CellOutput(kind: .error(
                ename: message["ename"] as? String ?? "Error",
                evalue: message["evalue"] as? String ?? "",
                traceback: (message["traceback"] as? String ?? "").strippingANSI,
                frames: frames)))
        case "done":
            flushStreams(into: cell)
            cell.isRunning = false
            document?.isDirty = true
            if let started = cell.runStartedAt {
                cell.lastDuration = -started.timeIntervalSinceNow
            }
            cell.executionCount = message["execution_count"] as? Int
            refreshVariables()
            if advance, let document { advanceSelection(after: cell, in: document) }
            completion?((message["status"] as? String) == "ok")
            return true
        case "dead":
            flushStreams(into: cell)
            cell.isRunning = false
            cell.outputs.append(CellOutput(kind: .error(
                ename: "KernelError", evalue: "Kernel died during execution",
                traceback: "", frames: [])))
            completion?(false)
            return true
        default:
            break
        }
        return false
    }

    private var pendingStreams: [UUID: (name: String, text: String)] = [:]
    private var streamFlushScheduled: Set<UUID> = []

    private func bufferStream(name: String, text: String, into cell: NotebookCell) {
        if let pending = pendingStreams[cell.id], pending.name != name {
            flushStreams(into: cell)
        }
        var pending = pendingStreams[cell.id] ?? (name: name, text: "")
        pending.text += text
        pendingStreams[cell.id] = pending
        guard !streamFlushScheduled.contains(cell.id) else { return }
        streamFlushScheduled.insert(cell.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.033) { [weak self, weak cell] in
            guard let self, let cell else { return }
            self.streamFlushScheduled.remove(cell.id)
            self.flushStreams(into: cell)
        }
    }

    private func flushStreams(into cell: NotebookCell) {
        guard let pending = pendingStreams.removeValue(forKey: cell.id) else { return }
        if case .stream(let lastName, let lastText)? = cell.outputs.last?.kind, lastName == pending.name {
            cell.outputs[cell.outputs.count - 1].kind =
                .stream(name: pending.name, text: lastText.appendingTerminalOutput(pending.text))
        } else {
            cell.outputs.append(CellOutput(kind: .stream(
                name: pending.name, text: "".appendingTerminalOutput(pending.text))))
        }
    }

    func handleCellCommand(_ command: EditorCommand, cell: NotebookCell, document: Document) {
        switch command {
        case .runCell:
            runCell(cell, in: document, advance: false)
        case .runCellAndAdvance:
            runCell(cell, in: document, advance: true)
        }
    }

    func runSelectedCell(advance: Bool = false) {
        guard let document = activeDocument else { return }
        if document.kind == .script {
            runScript(document)
            return
        }
        guard let notebook = document.notebook,
              let cell = notebook.cells.first(where: { $0.id == selectedCellID }) else { return }
        runCell(cell, in: document, advance: advance)
    }

    func runAllCells(in document: Document) {
        guard allowExecution() else { return }
        guard let notebook = document.notebook,
              !notebook.cells.contains(where: { $0.isRunning }) else { return }
        notebook.cells.forEach { $0.isQueued = $0.cellType == .code }
        runningChainDocumentID = document.id
        runningChainCellIDs = notebook.cells.filter { $0.cellType == .code }.map(\.id)
        runningChainIndex = 0
        pausedRunDocumentID = nil
        pausedRunCellIDs = []
        runNextQueuedCell(in: document)
    }

    func setSourceCollapsed(_ collapsed: Bool, for cell: NotebookCell, in document: Document) {
        guard cell.isSourceCollapsed != collapsed else { return }
        cell.isSourceCollapsed = collapsed
        document.isDirty = true
    }

    func setOutputCollapsed(_ collapsed: Bool, for cell: NotebookCell, in document: Document) {
        guard cell.isOutputCollapsed != collapsed else { return }
        cell.isOutputCollapsed = collapsed
        document.isDirty = true
    }

    private func endRunChain(in document: Document) {
        if runningChainDocumentID == document.id { runningChainDocumentID = nil }
        runningChainCellIDs = []
        runningChainIndex = 0
        document.notebook?.cells.forEach { $0.isQueued = false }
    }

    private func runNextQueuedCell(in document: Document) {
        guard runningChainDocumentID == document.id,
              openDocuments.contains(where: { $0.id == document.id }),
              let notebook = document.notebook else {
            endRunChain(in: document)
            return
        }
        guard runningChainIndex < runningChainCellIDs.count else {
            endRunChain(in: document)
            return
        }
        let cellID = runningChainCellIDs[runningChainIndex]
        runningChainIndex += 1
        guard let cell = notebook.cells.first(where: { $0.id == cellID }) else {
            runNextQueuedCell(in: document)
            return
        }
        runCell(cell, in: document, advance: false) { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.pausedRunDocumentID = document.id
                self.pausedRunCellIDs = Array(self.runningChainCellIDs.dropFirst(self.runningChainIndex))
                self.selectedCellID = cell.id
                self.scrollRequest = cell.id
                self.userNotice = "Run All stopped at a cell error. Fix the error or continue the remaining cells."
                self.endRunChain(in: document)
                return
            }
            self.runNextQueuedCell(in: document)
        }
    }

    func continueRemainingCells() {
        guard let id = pausedRunDocumentID,
              let document = openDocuments.first(where: { $0.id == id }),
              let notebook = document.notebook, !pausedRunCellIDs.isEmpty else { return }
        runningChainDocumentID = id
        runningChainCellIDs = pausedRunCellIDs
        runningChainIndex = 0
        pausedRunDocumentID = nil
        pausedRunCellIDs = []
        let queued = Set(runningChainCellIDs)
        notebook.cells.forEach { $0.isQueued = queued.contains($0.id) }
        runNextQueuedCell(in: document)
    }

    func runCells(above cell: NotebookCell, in document: Document) {
        guard let notebook = document.notebook,
              let index = notebook.cells.firstIndex(where: { $0.id == cell.id }) else { return }
        runCellSequence(Array(notebook.cells.prefix(index)).filter { $0.cellType == .code }, in: document)
    }

    func runCells(below cell: NotebookCell, in document: Document) {
        guard let notebook = document.notebook,
              let index = notebook.cells.firstIndex(where: { $0.id == cell.id }) else { return }
        runCellSequence(Array(notebook.cells.dropFirst(index + 1)).filter { $0.cellType == .code }, in: document)
    }

    func runSelectedCells() {
        guard let document = activeDocument, let notebook = document.notebook else { return }
        let ids = selection.selectedCellIDs
        runCellSequence(notebook.cells.filter { ids.contains($0.id) && $0.cellType == .code },
                        in: document)
    }

    private func runCellSequence(_ cells: [NotebookCell], in document: Document) {
        guard allowExecution() else { return }
        guard !cells.isEmpty, runningChainDocumentID == nil else { return }
        runningChainDocumentID = document.id
        runningChainCellIDs = cells.map(\.id)
        runningChainIndex = 0
        let queued = Set(runningChainCellIDs)
        document.notebook?.cells.forEach { $0.isQueued = queued.contains($0.id) }
        runNextQueuedCell(in: document)
    }

    private func advanceSelection(after cell: NotebookCell, in document: Document) {
        guard let notebook = document.notebook,
              let index = notebook.cells.firstIndex(where: { $0.id == cell.id }) else { return }
        let next: NotebookCell
        if index + 1 < notebook.cells.count {
            next = notebook.cells[index + 1]
        } else {
            next = NotebookCell(type: .code)
            notebook.cells.append(next)
            document.isDirty = true
        }
        selectedCellID = next.id
        if !isCommandMode {
            if next.cellType == .markdown && !next.isEditingMarkdown {
                scrollRequest = next.id
            } else {
                focusCellEditor(next.id)
            }
        } else {
            scrollRequest = next.id
        }
    }

    func appendCell(type: CellType, to notebook: Notebook, in document: Document) {
        activeDocumentID = document.id
        let cell = NotebookCell(type: type)
        if type == .markdown { cell.isEditingMarkdown = true }
        notebook.cells.append(cell)
        selectedCellID = cell.id
        scrollRequest = cell.id
        if !isCommandMode { focusCellEditor(cell.id) }
        document.isDirty = true
    }

    func insertCell(type: CellType, nextTo cell: NotebookCell, offset: Int,
                    in notebook: Notebook, document: Document, editing: Bool = false) {
        guard let index = notebook.cells.firstIndex(where: { $0.id == cell.id }) else { return }
        activeDocumentID = document.id
        let newCell = NotebookCell(type: type)
        if type == .markdown { newCell.isEditingMarkdown = true }
        let target = max(0, min(index + offset, notebook.cells.count))
        notebook.cells.insert(newCell, at: target)
        selectedCellID = newCell.id
        scrollRequest = newCell.id
        if editing { isCommandMode = false }
        if !isCommandMode { focusCellEditor(newCell.id) }
        document.isDirty = true
    }

    func deleteCell(_ cell: NotebookCell, in notebook: Notebook, document: Document) {
        guard runningChainDocumentID != document.id else {
            userNotice = "Stop the current Run All before deleting or reordering cells."
            return
        }
        guard let index = notebook.cells.firstIndex(where: { $0.id == cell.id }) else { return }
        document.deletedCells.append((dict: notebook.serializeCell(cell), index: index,
                                      restoreSource: nil))
        if document.deletedCells.count > 50 { document.deletedCells.removeFirst() }
        notebook.cells.remove(at: index)
        if notebook.cells.isEmpty {
            notebook.cells.append(NotebookCell(type: .code))
        }
        selectedCellID = notebook.cells[min(index, notebook.cells.count - 1)].id
        document.isDirty = true
    }

    func moveCell(_ cell: NotebookCell, direction: Int, in notebook: Notebook, document: Document) {
        guard runningChainDocumentID != document.id else {
            userNotice = "Stop the current Run All before deleting or reordering cells."
            return
        }
        guard let index = notebook.cells.firstIndex(where: { $0.id == cell.id }) else { return }
        let target = index + direction
        guard target >= 0, target < notebook.cells.count else { return }
        notebook.cells.swapAt(index, target)
        document.isDirty = true
        cellRevision += 1
    }

    func reorderCells(draggedID: UUID, before targetID: UUID,
                      in notebook: Notebook, document: Document) {
        guard runningChainDocumentID != document.id, draggedID != targetID else { return }
        let ids = selection.selectedCellIDs.contains(draggedID)
            ? selection.selectedCellIDs : Set([draggedID])
        let moving = notebook.cells.filter { ids.contains($0.id) }
        guard !moving.isEmpty, !ids.contains(targetID) else { return }
        notebook.cells.removeAll { ids.contains($0.id) }
        guard let target = notebook.cells.firstIndex(where: { $0.id == targetID }) else { return }
        notebook.cells.insert(contentsOf: moving, at: target)
        selection.selectedCellIDs = ids
        selectedCellID = moving.last?.id
        document.isDirty = true
        cellRevision += 1
    }

    func convertCell(_ cell: NotebookCell, to type: CellType, in document: Document) {
        guard cell.cellType != type else { return }
        cell.cellType = type
        cell.outputs = []
        cell.executionCount = nil
        if type == .markdown { cell.isEditingMarkdown = true }
        document.isDirty = true
    }

    enum LatexResult {
        case image(NSImage, depth: CGFloat)
        case failure(String)
    }

    func renderLatex(_ tex: String, fontSize: CGFloat, colorHex: String,
                     completion: @escaping (LatexResult) -> Void) {
        let key = "\(colorHex)|\(Int(fontSize))|\(tex)"
        if let cached = latexCache[key] {
            completion(cached)
            return
        }
        if latexPending[key] != nil {
            latexPending[key]?.append(completion)
            return
        }
        guard isWorkspaceTrusted, kernelTransition == nil, kernel.isRunning else {
            completion(.failure("Python rendering requires a trusted workspace and a running kernel"))
            return
        }
        latexPending[key] = [completion]
        kernel.request(["op": "latex", "tex": tex,
                        "fontsize": Double(fontSize), "color": colorHex]) { [weak self] message in
            guard let self else { return true }
            switch message["type"] as? String {
            case "latex":
                if let b64 = message["data"] as? String,
                   let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
                   let image = NSImage(data: data) {
                    let depth = CGFloat((message["depth"] as? Double) ?? 0)
                    self.finishLatex(key, with: .image(image, depth: depth), cache: true)
                } else {
                    self.finishLatex(key, with: .failure("malformed kernel reply"), cache: true)
                }
                return true
            case "latex_error":
                self.finishLatex(key,
                                 with: .failure(message["error"] as? String ?? "unsupported expression"),
                                 cache: true)
                return true
            case "dead":
                self.finishLatex(key, with: .failure("kernel stopped"), cache: false)
                return true
            default:
                return false
            }
        }
    }

    private func finishLatex(_ key: String, with result: LatexResult, cache: Bool) {
        if cache { latexCache[key] = result }
        latexPending.removeValue(forKey: key)?.forEach { $0(result) }
    }

    func refreshVariables() {
        guard isWorkspaceTrusted, kernelTransition == nil, kernel.isRunning else { return }
        kernel.request(["op": "vars"]) { [weak self] message in
            guard let self else { return true }
            switch message["type"] as? String {
            case "vars":
                let raw = message["variables"] as? [[String: Any]] ?? []
                let previous = Dictionary(uniqueKeysWithValues: self.variables.map { ($0.name, $0.summary + $0.typeName) })
                let next = raw.compactMap { VariableInfo(dict: $0) }
                self.changedVariables = Set(next.filter { previous[$0.name] != $0.summary + $0.typeName }.map(\.name))
                self.variables = next
                return true
            case "dead":
                return true
            default:
                return false
            }
        }
    }

    func openDataFrame(named name: String) {
        if let existing = openDocuments.first(where: { $0.kind == .dataFrame && $0.dataFrameName == name }) {
            activeDocumentID = existing.id
            reloadDataFrame(existing)
            return
        }
        let document = Document(dataFrameNamed: name)
        openDocuments.append(document)
        activeDocumentID = document.id
        reloadDataFrame(document)
    }

    func reloadDataFrame(_ document: Document) {
        guard let name = document.dataFrameName else { return }
        document.dataFrameRequest += 1
        let request = document.dataFrameRequest
        document.dataFrameError = nil
        document.isLoadingDataFrame = true
        fetchDataFrame(name: name, offset: 0, limit: 1000, filter: document.dataFrameFilter,
                       sortColumn: document.dataFrameSortColumn, ascending: document.dataFrameSortAscending) { [weak document] payload, error in
            guard document?.dataFrameRequest == request else { return }
            document?.isLoadingDataFrame = false
            document?.dataFrame = payload
            document?.dataFrameError = error
        }
    }

    func loadMoreDataFrame(_ document: Document) {
        guard let name = document.dataFrameName,
              let current = document.dataFrame, !document.isLoadingDataFrame else { return }
        document.isLoadingDataFrame = true
        let request = document.dataFrameRequest
        fetchDataFrame(name: name, offset: current.rows.count, limit: 1000, filter: document.dataFrameFilter,
                       sortColumn: document.dataFrameSortColumn, ascending: document.dataFrameSortAscending) { [weak self, weak document] payload, error in
            guard document?.dataFrameRequest == request else { return }
            document?.isLoadingDataFrame = false
            if let payload {
                document?.dataFrame?.appendPage(payload)
            } else if let error {
                self?.appendConsole(.system, "Could not load more rows: \(error)")
            }
        }
    }

    private func fetchDataFrame(name: String, offset: Int, limit: Int, filter: String = "",
                                sortColumn: Int? = nil, ascending: Bool = true,
                                completion: @escaping (DataFramePayload?, String?) -> Void) {
        guard isWorkspaceTrusted, kernelTransition == nil, kernel.isRunning else {
            completion(nil, "Data inspection requires a trusted workspace and a running kernel")
            return
        }
        var request: [String: Any] = ["op": "df", "name": name, "offset": offset, "limit": limit,
                                      "max_cols": 60, "filter": filter, "ascending": ascending]
        if let sortColumn { request["sort_column"] = sortColumn }
        kernel.request(request) { message in
            switch message["type"] as? String {
            case "dataframe":
                if let dict = message["payload"] as? [String: Any],
                   let payload = DataFramePayload(dict: dict) {
                    completion(payload, nil)
                } else {
                    completion(nil, "Malformed response from kernel")
                }
                return true
            case "df_error":
                completion(nil, message["error"] as? String ?? "Unknown error")
                return true
            case "dead":
                completion(nil, "Kernel died")
                return true
            default:
                return false
            }
        }
    }

    func requestCompletions(code: String, cursor: Int,
                            reply: @escaping ([String], Int, Int) -> Void) {
        guard isWorkspaceTrusted, kernelTransition == nil, kernel.isRunning, kernelStatus == .idle else {
            reply([], cursor, cursor)
            return
        }
        kernel.request(["op": "complete", "code": code, "cursor": cursor]) { message in
            switch message["type"] as? String {
            case "completions":
                reply(message["matches"] as? [String] ?? [],
                      message["start"] as? Int ?? 0,
                      message["end"] as? Int ?? 0)
                return true
            case "dead":
                return true
            default:
                return false
            }
        }
    }

    func requestInspection(code: String, cursor: Int,
                           reply: @escaping (InspectionInfo?) -> Void) {
        guard isWorkspaceTrusted, kernelTransition == nil, kernel.isRunning, kernelStatus == .idle else {
            reply(nil)
            return
        }
        kernel.request(["op": "inspect", "code": code, "cursor": cursor]) { message in
            switch message["type"] as? String {
            case "inspection":
                reply(InspectionInfo(signature: message["signature"] as? String ?? "",
                                     doc: message["doc"] as? String ?? ""))
                return true
            case "inspect_error", "dead":
                reply(nil)
                return true
            default:
                return false
            }
        }
    }

    @Published var scrollRequest: UUID?
    private var pendingDeleteTimestamp: TimeInterval = 0

    func enterCommandMode() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let catcher = CommandCatcherView.activeCatcher(in: window) else { return }
        window.makeFirstResponder(catcher)
    }

    func enterEditMode() {
        guard let notebook = activeDocument?.notebook,
              let cell = notebook.cells.first(where: { $0.id == selectedCellID }) else { return }
        if cell.cellType == .markdown { cell.isEditingMarkdown = true }
        if cell.isSourceCollapsed { cell.isSourceCollapsed = false }
        focusCellEditor(cell.id)
    }

    func focusCellEditor(_ id: UUID, caret: Int? = nil) {
        scrollRequest = id
        focusEditor(id, caret: caret)
    }

    func focusEditor(_ id: UUID, caret: Int? = nil) {
        func attempt(_ remaining: Int) {
            if let tv = EditorRegistry.shared.view(for: id), tv.window != nil {
                tv.window?.makeFirstResponder(tv)
                if let caret {
                    let length = (tv.string as NSString).length
                    tv.setSelectedRange(NSRange(location: min(caret, length), length: 0))
                }
            } else if remaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { attempt(remaining - 1) }
            }
        }
        DispatchQueue.main.async { attempt(12) }
    }

    func handleCommandModeKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
            return false
        }
        guard let document = activeDocument, document.kind == .notebook,
              let notebook = document.notebook, !notebook.cells.isEmpty else { return false }
        let index: Int
        if let found = notebook.cells.firstIndex(where: { $0.id == selectedCellID }) {
            index = found
        } else if selectedCellID == nil {
            index = 0
        } else {
            selectedCellID = notebook.cells[0].id
            return true
        }
        let cell = notebook.cells[index]
        if event.charactersIgnoringModifiers?.lowercased() != "d" { pendingDeleteTimestamp = 0 }

        switch event.keyCode {
        case 36:
            if event.modifierFlags.contains(.shift) {
                runCell(cell, in: document, advance: true)
            } else {
                enterEditMode()
            }
            return true
        case 126:
            selectCell(at: index - 1, in: notebook)
            return true
        case 125:
            selectCell(at: index + 1, in: notebook)
            return true
        default:
            break
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a":
            insertCell(type: .code, nextTo: cell, offset: 0, in: notebook, document: document)
            return true
        case "b":
            insertCell(type: .code, nextTo: cell, offset: 1, in: notebook, document: document)
            return true
        case "d":
            let now = ProcessInfo.processInfo.systemUptime
            if now - pendingDeleteTimestamp < 0.7 {
                pendingDeleteTimestamp = 0
                deleteCell(cell, in: notebook, document: document)
            } else {
                pendingDeleteTimestamp = now
            }
            return true
        case "c":
            copyCell(cell, in: notebook)
            return true
        case "x":
            copyCell(cell, in: notebook)
            deleteCell(cell, in: notebook, document: document)
            return true
        case "v":
            pasteCell(after: cell, in: notebook, document: document)
            return true
        case "m":
            convertCell(cell, to: .markdown, in: document)
            return true
        case "y":
            convertCell(cell, to: .code, in: document)
            return true
        case "z":
            undoCellDeletion(in: document)
            return true
        case "o":
            setOutputCollapsed(!cell.isOutputCollapsed, for: cell, in: document)
            return true
        case "f":
            openFind()
            return true
        default:
            return false
        }
    }

    private func rebindCellSelection(from previousID: UUID?) {
        if let previous = openDocuments.first(where: { $0.id == previousID }),
           previous.notebook?.cells.contains(where: { $0.id == selectedCellID }) == true {
            previous.lastSelectedCellID = selectedCellID
        }
        guard let document = activeDocument, let cells = document.notebook?.cells else {
            selectedCellID = nil
            return
        }
        guard !cells.contains(where: { $0.id == selectedCellID }) else { return }
        let remembered = document.lastSelectedCellID
        selectedCellID = cells.first { $0.id == remembered }?.id ?? cells.first?.id
    }

    var selectionContext: (cell: NotebookCell, notebook: Notebook, document: Document)? {
        guard let document = activeDocument, let notebook = document.notebook,
              let cell = notebook.cells.first(where: { $0.id == selectedCellID }) else { return nil }
        return (cell, notebook, document)
    }

    func commandInsert(offset: Int, type: CellType = .code) {
        guard let ctx = selectionContext else { return }
        insertCell(type: type, nextTo: ctx.cell, offset: offset,
                   in: ctx.notebook, document: ctx.document)
    }

    func commandCopy() {
        guard let ctx = selectionContext else { return }
        copyCells(selectedCells(in: ctx.notebook), in: ctx.notebook)
    }

    func commandCut() {
        guard let ctx = selectionContext else { return }
        let cells = selectedCells(in: ctx.notebook)
        copyCells(cells, in: ctx.notebook)
        deleteCells(cells, in: ctx.notebook, document: ctx.document)
    }

    func commandPaste() {
        guard let ctx = selectionContext else { return }
        pasteCell(after: ctx.cell, in: ctx.notebook, document: ctx.document)
    }

    func commandDuplicate() {
        guard let ctx = selectionContext else { return }
        duplicateCells(selectedCells(in: ctx.notebook), in: ctx.notebook, document: ctx.document)
    }

    func commandDelete() {
        guard let ctx = selectionContext else { return }
        deleteCells(selectedCells(in: ctx.notebook), in: ctx.notebook, document: ctx.document)
    }

    func commandConvert(to type: CellType) {
        guard let ctx = selectionContext, ctx.cell.cellType != type else { return }
        convertCell(ctx.cell, to: type, in: ctx.document)
    }

    @MainActor
    func openSelectedPlotWindow() {
        guard let ctx = selectionContext else { return }
        for output in ctx.cell.outputs.reversed() {
            switch output.kind {
            case .plotlyFigure(let html, let jsPath, _, let image, _):
                if !jsPath.isEmpty, FileManager.default.fileExists(atPath: jsPath) {
                    PlotWindow.open(html: html, jsPath: jsPath)
                } else if let image {
                    PlotWindow.open(image: image)
                } else {
                    continue
                }
                return
            case .image(_, let image):
                guard let image else { continue }
                PlotWindow.open(image: image)
                return
            default:
                continue
            }
        }
    }

    private func selectCell(at index: Int, in notebook: Notebook) {
        guard !notebook.cells.isEmpty else { return }
        let clamped = max(0, min(index, notebook.cells.count - 1))
        selectedCellID = notebook.cells[clamped].id
        scrollRequest = selectedCellID
    }

    private var cellClipboard: [[String: Any]] = []

    private func selectedCells(in notebook: Notebook) -> [NotebookCell] {
        let ids = selection.selectedCellIDs
        let result = notebook.cells.filter { ids.contains($0.id) }
        return result.isEmpty ? notebook.cells.filter { $0.id == selectedCellID } : result
    }

    func selectCell(_ cell: NotebookCell, in notebook: Notebook,
                    modifiers: NSEvent.ModifierFlags = []) {
        activeDocumentID = activeDocument?.id
        if modifiers.contains(.shift), let anchor = selection.anchorCellID,
           let start = notebook.cells.firstIndex(where: { $0.id == anchor }),
           let end = notebook.cells.firstIndex(where: { $0.id == cell.id }) {
            let range = min(start, end)...max(start, end)
            selection.selectedCellIDs = Set(range.map { notebook.cells[$0].id })
            selection.selectedCellID = cell.id
        } else if modifiers.contains(.command) {
            if selection.selectedCellIDs.contains(cell.id) {
                selection.selectedCellIDs.remove(cell.id)
                selection.selectedCellID = selection.selectedCellIDs.first
            } else {
                selection.selectedCellIDs.insert(cell.id)
                selection.selectedCellID = cell.id
                selection.anchorCellID = cell.id
            }
        } else {
            selection.selectedCellIDs = [cell.id]
            selection.selectedCellID = cell.id
            selection.anchorCellID = cell.id
        }
        enterCommandMode()
    }

    func copyCell(_ cell: NotebookCell, in notebook: Notebook) {
        copyCells([cell], in: notebook)
    }

    func copyCells(_ cells: [NotebookCell], in notebook: Notebook) {
        cellClipboard = cells.map { notebook.serializeCell($0) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cells.map(\.source).joined(separator: "\n\n"), forType: .string)
    }

    func pasteCell(after cell: NotebookCell, in notebook: Notebook, document: Document) {
        guard !cellClipboard.isEmpty else { return }
        guard let index = notebook.cells.firstIndex(where: { $0.id == cell.id }) else { return }
        let restored = cellClipboard.map { source -> NotebookCell in
            var dict = source
            dict["id"] = NotebookCell.makeNBID()
            return Notebook.parseCell(dict)
        }
        notebook.cells.insert(contentsOf: restored, at: index + 1)
        selection.selectedCellIDs = Set(restored.map(\.id))
        selectedCellID = restored.last?.id
        scrollRequest = restored.last?.id
        document.isDirty = true
    }

    func duplicateCell(_ cell: NotebookCell, in notebook: Notebook, document: Document) {
        duplicateCells([cell], in: notebook, document: document)
    }

    func duplicateCells(_ cells: [NotebookCell], in notebook: Notebook, document: Document) {
        guard let last = cells.last,
              let index = notebook.cells.firstIndex(where: { $0.id == last.id }) else { return }
        let copies = cells.map { cell -> NotebookCell in
            var dict = notebook.serializeCell(cell)
            dict["id"] = NotebookCell.makeNBID()
            return Notebook.parseCell(dict)
        }
        notebook.cells.insert(contentsOf: copies, at: index + 1)
        selection.selectedCellIDs = Set(copies.map(\.id))
        selectedCellID = copies.last?.id
        scrollRequest = copies.last?.id
        document.isDirty = true
    }

    func deleteCells(_ cells: [NotebookCell], in notebook: Notebook, document: Document) {
        let ordered = cells.compactMap { cell in notebook.cells.firstIndex(where: { $0.id == cell.id }).map { ($0, cell) } }
            .sorted { $0.0 > $1.0 }
        for (_, cell) in ordered { deleteCell(cell, in: notebook, document: document) }
    }

    func undoCellDeletion(in document: Document) {
        guard let notebook = document.notebook,
              let record = document.deletedCells.popLast() else { return }
        if let restore = record.restoreSource,
           let merged = notebook.cells.first(where: { $0.id == restore.cellID }) {
            merged.source = restore.source
        }
        let cell = Notebook.parseCell(record.dict)
        let index = max(0, min(record.index, notebook.cells.count))
        notebook.cells.insert(cell, at: index)
        selectedCellID = cell.id
        scrollRequest = cell.id
        document.isDirty = true
    }

    func splitSelectedCell() {
        guard let document = activeDocument, let notebook = document.notebook,
              let cell = notebook.cells.first(where: { $0.id == selectedCellID }),
              let tv = EditorRegistry.shared.view(for: cell.id),
              let index = notebook.cells.firstIndex(where: { $0.id == cell.id }) else { return }
        let ns = cell.source as NSString
        let caret = min(tv.selectedRange().location, ns.length)
        let head = ns.substring(to: caret)
        let tail = ns.substring(from: caret)
        cell.source = head
        let newCell = NotebookCell(type: cell.cellType, source: tail)
        if cell.cellType == .markdown { newCell.isEditingMarkdown = true }
        notebook.cells.insert(newCell, at: index + 1)
        selectedCellID = newCell.id
        document.isDirty = true
        focusCellEditor(newCell.id, caret: 0)
    }

    func mergeSelectedCellWithBelow() {
        guard let document = activeDocument, let notebook = document.notebook,
              let index = notebook.cells.firstIndex(where: { $0.id == selectedCellID }),
              index + 1 < notebook.cells.count else { return }
        let cell = notebook.cells[index]
        let below = notebook.cells[index + 1]
        document.deletedCells.append((dict: notebook.serializeCell(below), index: index + 1,
                                      restoreSource: (cellID: cell.id, source: cell.source)))
        cell.source += "\n" + below.source
        notebook.cells.remove(at: index + 1)
        document.isDirty = true
        cellRevision += 1
    }

    func clearAllOutputs(in document: Document?) {
        guard let document, let notebook = document.notebook else { return }
        for cell in notebook.cells {
            if !cell.outputs.isEmpty {
                document.clearedOutputs.append((cell.id, cell.outputs, cell.executionCount, cell.lastDuration))
            }
            cell.outputs = []
            cell.executionCount = nil
            cell.lastDuration = nil
        }
        document.isDirty = true
    }

    func clearOutput(for cell: NotebookCell, in document: Document) {
        guard !cell.outputs.isEmpty else { return }
        document.clearedOutputs.append((cell.id, cell.outputs, cell.executionCount, cell.lastDuration))
        if document.clearedOutputs.count > 100 { document.clearedOutputs.removeFirst() }
        cell.outputs = []
        cell.executionCount = nil
        cell.lastDuration = nil
        document.isDirty = true
    }

    func undoClearedOutput(in document: Document) {
        guard let notebook = document.notebook,
              let record = document.clearedOutputs.popLast(),
              let cell = notebook.cells.first(where: { $0.id == record.cellID }) else { return }
        cell.outputs = record.outputs
        cell.executionCount = record.executionCount
        cell.lastDuration = record.duration
        selectedCellID = cell.id
        scrollRequest = cell.id
        document.isDirty = true
    }

    private var pendingRunAllDocumentID: UUID?
    private var runningChainDocumentID: UUID?
    private var runningChainCellIDs: [UUID] = []
    private var runningChainIndex = 0
    @Published private(set) var pausedRunDocumentID: UUID?
    private var pausedRunCellIDs: [UUID] = []

    var runQueueProgress: (completed: Int, total: Int)? {
        guard runningChainDocumentID != nil, !runningChainCellIDs.isEmpty else { return nil }
        return (min(runningChainIndex, runningChainCellIDs.count), runningChainCellIDs.count)
    }

    func restartAndRunAll() {
        guard allowExecution() else { return }
        guard let document = activeDocument, document.kind == .notebook else { return }
        clearAllOutputs(in: document)
        pendingRunAllDocumentID = document.id
        restartKernel(confirm: false)
        if kernelStatus != .starting && kernelStatus != .idle {
            pendingRunAllDocumentID = nil
        }
    }

    func kernelBecameIdle() {
        guard let id = pendingRunAllDocumentID else { return }
        pendingRunAllDocumentID = nil
        if let document = openDocuments.first(where: { $0.id == id }) {
            runAllCells(in: document)
        }
    }

    func cancelPendingRunAll() {
        pendingRunAllDocumentID = nil
    }

    func openFind() {
        guard let document = activeDocument else { return }
        switch document.kind {
        case .script:
            performScriptFinderAction(.showFindInterface, in: document)
        case .notebook:
            let find = document.find
            find.isVisible = true
            find.focusRequest += 1
            recomputeFind(in: document, resetIndex: false)
        case .dataSource, .dataFrame, .diff:
            break
        }
    }

    private func performScriptFinderAction(_ action: NSTextFinder.Action, in document: Document) {
        guard let tv = EditorRegistry.shared.view(for: document.id) else { return }
        if action == .showFindInterface { tv.window?.makeFirstResponder(tv) }
        let item = NSMenuItem()
        item.tag = action.rawValue
        tv.performTextFinderAction(item)
    }

    func closeFind(in document: Document) {
        document.find.isVisible = false
        document.find.matches = []
        document.find.currentIndex = 0
        if let id = selectedCellID, EditorRegistry.shared.view(for: id) != nil {
            focusCellEditor(id)
        } else {
            enterCommandMode()
        }
    }

    func recomputeFind(in document: Document, resetIndex: Bool) {
        let find = document.find
        guard let notebook = document.notebook, !find.query.isEmpty else {
            find.matches = []
            find.currentIndex = 0
            return
        }
        var matches: [(cellID: UUID, range: NSRange)] = []
        for cell in notebook.cells {
            let ns = cell.source as NSString
            var search = NSRange(location: 0, length: ns.length)
            while true {
                let found = ns.range(of: find.query, options: .caseInsensitive, range: search)
                guard found.location != NSNotFound else { break }
                matches.append((cell.id, found))
                let next = found.location + max(found.length, 1)
                guard next < ns.length else { break }
                search = NSRange(location: next, length: ns.length - next)
            }
        }
        find.matches = matches
        find.currentIndex = resetIndex ? 0
            : (matches.isEmpty ? 0 : min(find.currentIndex, matches.count - 1))
        find.hasNavigated = resetIndex ? false : find.hasNavigated
    }

    func findQueryChanged(in document: Document) {
        recomputeFind(in: document, resetIndex: true)
        highlightCurrentMatch(in: document)
    }

    func findAdvance(in document: Document, delta: Int) {
        guard document.kind == .notebook else {
            performScriptFinderAction(delta > 0 ? .nextMatch : .previousMatch, in: document)
            return
        }
        let find = document.find
        if find.matches.isEmpty { recomputeFind(in: document, resetIndex: true) }
        guard !find.matches.isEmpty else { return }
        if find.hasNavigated {
            let count = find.matches.count
            find.currentIndex = ((find.currentIndex + delta) % count + count) % count
        }
        find.hasNavigated = true
        highlightCurrentMatch(in: document)
    }

    func highlightCurrentMatch(in document: Document) {
        let find = document.find
        guard find.currentIndex < find.matches.count, let notebook = document.notebook else { return }
        let match = find.matches[find.currentIndex]
        guard let cell = notebook.cells.first(where: { $0.id == match.cellID }) else { return }
        if cell.cellType == .markdown, !cell.isEditingMarkdown { cell.isEditingMarkdown = true }
        if cell.isSourceCollapsed { cell.isSourceCollapsed = false }
        if selectedCellID != cell.id { selectedCellID = cell.id }
        scrollRequest = cell.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let tv = EditorRegistry.shared.view(for: cell.id) else { return }
            let length = (tv.string as NSString).length
            guard match.range.location + match.range.length <= length else { return }
            tv.setSelectedRange(match.range)
            tv.scrollRangeToVisible(match.range)
            tv.showFindIndicator(for: match.range)
        }
    }

    func replaceCurrentMatch(in document: Document) {
        let find = document.find
        guard find.currentIndex < find.matches.count, let notebook = document.notebook else { return }
        let match = find.matches[find.currentIndex]
        guard let cell = notebook.cells.first(where: { $0.id == match.cellID }) else { return }
        let ns = cell.source as NSString
        guard match.range.location + match.range.length <= ns.length,
              ns.substring(with: match.range).caseInsensitiveCompare(find.query) == .orderedSame else {
            recomputeFind(in: document, resetIndex: false)
            return
        }
        cell.source = ns.replacingCharacters(in: match.range, with: find.replacement)
        document.isDirty = true
        recomputeFind(in: document, resetIndex: false)
        if !find.matches.isEmpty {
            find.currentIndex = min(find.currentIndex, find.matches.count - 1)
            highlightCurrentMatch(in: document)
        }
    }

    func replaceAllMatches(in document: Document) {
        let find = document.find
        guard let notebook = document.notebook, !find.query.isEmpty else { return }
        let pending = notebook.cells.compactMap { cell -> (NotebookCell, String)? in
            let replaced = cell.source.replacingOccurrences(
                of: find.query, with: find.replacement, options: .caseInsensitive)
            return replaced == cell.source ? nil : (cell, replaced)
        }
        guard !pending.isEmpty else { return }
        let cellCount = pending.count
        let replacementLabel = find.replacement.isEmpty ? "nothing" : "“\(find.replacement)”"
        confirmDestructive(
            title: "Replace every match in \(cellCount) cell\(cellCount == 1 ? "" : "s")?",
            message: "“\(find.query)” becomes \(replacementLabel) throughout this notebook. This cannot be undone.",
            button: "Replace All") { [weak self] in
            for (cell, replaced) in pending { cell.source = replaced }
            document.isDirty = true
            self?.recomputeFind(in: document, resetIndex: true)
        }
    }

    @Published var recentWorkspaces: [String] = []
    @Published var recentFiles: [String] = []

    func loadRecents() {
        recentWorkspaces = QuantaDefaults.store.stringArray(forKey: "QuantaRecentWorkspaces") ?? []
        recentFiles = QuantaDefaults.store.stringArray(forKey: "QuantaRecentFiles") ?? []
    }

    func recordRecent(_ path: String, isWorkspace: Bool) {
        let key = isWorkspace ? "QuantaRecentWorkspaces" : "QuantaRecentFiles"
        var list = QuantaDefaults.store.stringArray(forKey: key) ?? []
        list.removeAll { $0 == path }
        list.insert(path, at: 0)
        list = Array(list.prefix(8))
        QuantaDefaults.store.set(list, forKey: key)
        if isWorkspace { recentWorkspaces = list } else { recentFiles = list }
    }

    func clearRecents() {
        QuantaDefaults.store.removeObject(forKey: "QuantaRecentWorkspaces")
        QuantaDefaults.store.removeObject(forKey: "QuantaRecentFiles")
        recentWorkspaces = []
        recentFiles = []
    }

    func persistSession() {
        let files = openDocuments.filter { $0.isFileBacked }.compactMap { $0.url?.path }
        QuantaDefaults.store.set(files, forKey: "QuantaSessionFiles")
        QuantaDefaults.store.set(openDocuments.filter(\.isPinned).compactMap { $0.url?.path }, forKey: "QuantaPinnedFiles")
        QuantaDefaults.store.set(activeDocument?.url?.path, forKey: "QuantaSessionActive")
    }

    func restoreSession() {
        guard QuantaDefaults.store.object(forKey: "QuantaReopenSession") as? Bool ?? true else { return }
        let files = QuantaDefaults.store.stringArray(forKey: "QuantaSessionFiles") ?? []
        let active = QuantaDefaults.store.string(forKey: "QuantaSessionActive")
        let pinned = Set(QuantaDefaults.store.stringArray(forKey: "QuantaPinnedFiles") ?? [])
        for path in files where FileManager.default.fileExists(atPath: path) {
            openFile(URL(fileURLWithPath: path), recordSession: false)
        }
        for document in openDocuments { document.isPinned = document.url.map { pinned.contains($0.path) } ?? false }
        if let active, let document = openDocuments.first(where: { $0.url?.path == active }) {
            activeDocumentID = document.id
        }
    }

    private var autosaveTimer: Timer?
    private let draftQueue = DispatchQueue(label: "quanta.drafts", qos: .utility)
    private var draftFingerprints: [UUID: Int] = [:]

    private var draftsDirectory: URL {
        QuantaStorage.draftsDirectory(applicationSupport:
            QuantaDefaults.previewDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }

    func draftURL(for document: Document) -> URL {
        if let url = document.url { return draftURL(forPath: url) }
        let ext = document.kind == .notebook ? "ipynb" : "py"
        return draftsDirectory.appendingPathComponent("untitled-\(document.draftKey).\(ext)")
    }

    func draftURL(forPath fileURL: URL) -> URL {
        var hash: UInt64 = 5381
        for byte in fileURL.path.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return draftsDirectory.appendingPathComponent(
            String(hash, radix: 16) + "-" + fileURL.lastPathComponent)
    }

    func startAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.autosaveTick()
        }
    }

    private func autosaveTick() {
        let saveInPlace = QuantaDefaults.store.bool(forKey: "QuantaAutoSaveFiles")
        for document in openDocuments where document.isDirty && document.isFileBacked {
            if saveInPlace, document.url != nil, save(document, interactive: false) {
                continue
            }
            writeDraft(for: document)
        }
    }

    func writeDraft(for document: Document) {
        let fingerprint: Int
        let data: Data
        switch document.kind {
        case .script:
            fingerprint = document.text.hashValue
            guard draftFingerprints[document.id] != fingerprint else { return }
            data = Data(document.text.utf8)
        case .notebook:
            guard let notebook = document.notebook else { return }
            fingerprint = notebook.contentFingerprint
            guard draftFingerprints[document.id] != fingerprint,
                  let serialized = try? notebook.serializedData() else { return }
            data = serialized
        case .dataSource, .dataFrame, .diff:
            return
        }
        draftFingerprints[document.id] = fingerprint
        let target = draftURL(for: document)
        draftQueue.async {
            try? data.write(to: target, options: .atomic)
        }
    }

    func clearDraft(for document: Document) {
        draftFingerprints[document.id] = nil
        let target = draftURL(for: document)
        draftQueue.async { try? FileManager.default.removeItem(at: target) }
    }

    func restoreUntitledDrafts() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: draftsDirectory,
                                                      includingPropertiesForKeys: nil) else { return }
        for url in items where url.lastPathComponent.hasPrefix("untitled-") {
            let key = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "untitled-", with: "")
            do {
                if url.pathExtension == "ipynb" {
                    let notebook = try Notebook.load(from: Data(contentsOf: url))
                    let document = Document(notebook: notebook, url: nil, draftKey: key)
                    document.isDirty = true
                    openDocuments.append(document)
                } else {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    let document = Document(script: nil, text: text, draftKey: key)
                    document.isDirty = true
                    openDocuments.append(document)
                }
                appendConsole(.system, "Recovered unsaved \(url.pathExtension == "ipynb" ? "notebook" : "script") from the last session.")
            } catch {
                let quarantined = url.appendingPathExtension("corrupt")
                try? fm.removeItem(at: quarantined)
                if (try? fm.moveItem(at: url, to: quarantined)) != nil {
                    appendConsole(.system,
                                  "Could not read an unsaved draft — kept it at \(quarantined.path)")
                }
            }
        }
        if activeDocumentID == nil { activeDocumentID = openDocuments.last?.id }
    }

    func confirmDiscardingUnsavedChanges() -> Bool {
        let previous = activeDocumentID
        for document in openDocuments where document.isDirty && document.isFileBacked {
            activeDocumentID = document.id
            switch promptToSave(document) {
            case .save:
                guard save(document) else { return false }
            case .discard:
                clearDraft(for: document)
            case .cancel:
                return false
            }
        }
        activeDocumentID = previous
        draftQueue.sync {}
        return true
    }

    enum SavePromptChoice { case save, discard, cancel }

    func promptToSave(_ document: Document) -> SavePromptChoice {
        let alert = NSAlert()
        alert.messageText = "Save changes to \(document.displayName)?"
        alert.informativeText = "Your changes will be lost otherwise."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    @Published var editorFontSize: CGFloat =
        QuantaDefaults.store.object(forKey: "QuantaFontSize") as? CGFloat ?? 13

    func adjustFontSize(_ delta: CGFloat) {
        setFontSize(editorFontSize + delta)
    }

    func resetFontSize() {
        setFontSize(13)
    }

    func setFontSize(_ size: CGFloat) {
        let clamped = max(9, min(28, size))
        editorFontSize = clamped
        QuantaDefaults.store.set(clamped, forKey: "QuantaFontSize")
        EditorTheme.fontSize = clamped
        for tv in EditorRegistry.shared.allViews {
            tv.typingAttributes = [.font: EditorTheme.font, .foregroundColor: EditorTheme.text]
            if let storage = tv.textStorage { PythonHighlighter.highlight(storage) }
            tv.onLayoutChange?()
        }
    }

    func exportActiveNotebookAsPython() {
        guard let document = activeDocument, let notebook = document.notebook else { return }
        let script = NotebookExporter.pythonScript(from: notebook)
        savePanelWrite(data: Data(script.utf8),
                       suggested: document.displayName.replacingOccurrences(of: ".ipynb", with: ".py"),
                       type: .pythonScript)
    }

    func exportActiveNotebookAsHTML() {
        guard let document = activeDocument, let notebook = document.notebook else { return }
        let html = NotebookExporter.html(from: notebook, title: document.displayName,
                                         baseDirectory: document.url?.deletingLastPathComponent())
        savePanelWrite(data: Data(html.utf8),
                       suggested: document.displayName.replacingOccurrences(of: ".ipynb", with: ".html"),
                       type: .html)
    }

    func exportActiveNotebookAsPDF() {
        guard !isExportingPDF, let document = activeDocument, let notebook = document.notebook else { return }
        let panel = NSSavePanel()
        panel.directoryURL = document.url?.deletingLastPathComponent() ?? workspace?.rootURL
        panel.nameFieldStringValue = (document.displayName as NSString).deletingPathExtension + ".pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExportingPDF = true
        let html = NotebookExporter.html(from: notebook, title: document.displayName,
                                         baseDirectory: document.url?.deletingLastPathComponent())
        NotebookExporter.renderPDF(html: html) { [weak self] data in
            guard let self else { return }
            self.isExportingPDF = false
            guard let data else {
                self.userNotice = "PDF export could not finish rendering the notebook. Check its outputs and try again."
                return
            }
            do {
                try data.write(to: url, options: .atomic)
                self.refreshWorkspace()
            } catch { self.userNotice = "Could not save PDF: \(error.localizedDescription)" }
        }
    }

    private func savePanelWrite(data: Data, suggested: String, type: UTType) {
        let panel = NSSavePanel()
        panel.directoryURL = workspace?.rootURL
        panel.nameFieldStringValue = suggested
        panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            refreshWorkspace()
        } catch {
            appendConsole(.system, "Export failed: \(error.localizedDescription)")
            revealConsole()
        }
    }

    func promptForName(title: String, message: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    func createFile(in directory: URL) {
        guard let name = promptForName(title: "New File",
                                       message: "Name for the new file:",
                                       initial: "untitled.py") else { return }
        let url = directory.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            userNotice = "“\(name)” already exists. Choose a different name."
            return
        }
        do {
            if url.pathExtension.lowercased() == "ipynb" {
                try Notebook.empty().serializedData().write(to: url)
            } else if !FileManager.default.createFile(atPath: url.path, contents: Data()) {
                throw CocoaError(.fileWriteUnknown)
            }
            refreshWorkspace()
            openFile(url)
        } catch {
            userNotice = "Could not create \(name): \(error.localizedDescription)"
        }
    }

    func createFolder(in directory: URL) {
        guard let name = promptForName(title: "New Folder",
                                       message: "Name for the new folder:",
                                       initial: "folder") else { return }
        do {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(name), withIntermediateDirectories: false)
            refreshWorkspace()
        } catch {
            userNotice = "Could not create \(name): \(error.localizedDescription)"
        }
    }

    func renameNode(_ node: FileNode) {
        guard let name = promptForName(title: "Rename",
                                       message: "New name for \(node.name):",
                                       initial: node.name),
              name != node.name else { return }
        let target = node.url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: node.url, to: target)
            for document in openDocuments {
                guard let relative = Self.relativePath(of: document.url, under: node.url) else { continue }
                document.url = relative.isEmpty ? target : target.appendingPathComponent(relative)
            }
            persistSession()
            refreshWorkspace()
        } catch {
            appendConsole(.system, "Rename failed: \(error.localizedDescription)")
        }
    }

    func duplicateNodes(at urls: [URL]) {
        finishFileOperation(FileOperations.duplicate(urls), moved: false)
    }

    func copyNodes(at urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
    }

    func pasteNodes(into directory: URL) {
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL] ?? []
        transferNodes(at: urls, to: directory, copying: true)
    }

    func chooseDestinationAndMoveNodes(at urls: [URL]) {
        guard !urls.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Move"
        panel.message = "Choose a destination for \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items")"
        panel.directoryURL = workspace?.rootURL
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        transferNodes(at: urls, to: destination, copying: false)
    }

    func transferNodes(at urls: [URL], to directory: URL, copying: Bool) {
        guard !urls.isEmpty else { return }
        let report = FileOperations.transfer(urls, to: directory, copying: copying) { target in
            let alert = NSAlert()
            alert.messageText = "“\(target.lastPathComponent)” already exists"
            alert.informativeText = "Choose a new automatic name, skip this item, or cancel the remaining operation."
            alert.addButton(withTitle: "Keep Both")
            alert.addButton(withTitle: "Skip")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: return .keepBoth
            case .alertSecondButtonReturn: return .skip
            default: return .cancel
            }
        }
        finishFileOperation(report, moved: !copying)
    }

    private func finishFileOperation(_ report: FileOperationReport, moved: Bool) {
        if moved {
            for pair in report.completed {
                for document in openDocuments {
                    guard let relative = Self.relativePath(of: document.url, under: pair.source) else { continue }
                    document.url = relative.isEmpty ? pair.destination : pair.destination.appendingPathComponent(relative)
                }
            }
            persistSession()
            if !report.completed.isEmpty {
                NSApp.keyWindow?.undoManager?.registerUndo(withTarget: self) { target in
                    target.restoreMovedItems(report.completed)
                }
                NSApp.keyWindow?.undoManager?.setActionName("Move Files")
            }
        }
        refreshWorkspace()
        guard let summary = report.summary else { return }
        let details = report.failures.prefix(3).map { "\($0.0.lastPathComponent): \($0.1)" }.joined(separator: "\n")
        userNotice = details.isEmpty ? summary : "\(summary)\n\(details)"
    }

    private func restoreMovedItems(_ pairs: [(source: URL, destination: URL)]) {
        var failures: [String] = []
        for pair in pairs.reversed() {
            guard !FileManager.default.fileExists(atPath: pair.source.path) else {
                failures.append("\(pair.source.lastPathComponent): the original location is occupied")
                continue
            }
            do { try FileManager.default.moveItem(at: pair.destination, to: pair.source) }
            catch { failures.append("\(pair.destination.lastPathComponent): \(error.localizedDescription)") }
        }
        for document in openDocuments {
            for pair in pairs {
                guard let relative = Self.relativePath(of: document.url, under: pair.destination) else { continue }
                document.url = relative.isEmpty ? pair.source : pair.source.appendingPathComponent(relative)
            }
        }
        persistSession()
        refreshWorkspace()
        if !failures.isEmpty { userNotice = failures.joined(separator: "\n") }
    }

    func trashNodes(at urls: [URL]) {
        let nodes = urls.map { FileNode(url: $0, name: $0.lastPathComponent,
                                       isDirectory: $0.hasDirectoryPath, children: nil) }
        let affected = openDocuments.filter { document in
            nodes.contains { Self.relativePath(of: document.url, under: $0.url) != nil }
        }
        if affected.contains(where: \.isDirty) {
            let alert = NSAlert()
            alert.messageText = "Move selected items to the Trash?"
            alert.informativeText = "Unsaved changes in affected open tabs will be lost."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        var failures: [String] = []
        var trashed: [(source: URL, destination: URL)] = []
        for node in nodes {
            do {
                var result: NSURL?
                try FileManager.default.trashItem(at: node.url, resultingItemURL: &result)
                if let result = result as URL? { trashed.append((node.url, result)) }
            }
            catch { failures.append("\(node.name): \(error.localizedDescription)") }
        }
        for document in affected {
            document.isDirty = false
            closeDocument(document)
        }
        if !trashed.isEmpty {
            NSApp.keyWindow?.undoManager?.registerUndo(withTarget: self) { target in
                target.restoreMovedItems(trashed)
            }
            NSApp.keyWindow?.undoManager?.setActionName("Move to Trash")
        }
        refreshWorkspace()
        if !failures.isEmpty { userNotice = failures.joined(separator: "\n") }
    }

    func trashNode(_ node: FileNode) {
        trashNodes(at: [node.url])
    }

    static func relativePath(of url: URL?, under base: URL) -> String? {
        guard let path = url?.path else { return nil }
        let basePath = base.path
        if path == basePath { return "" }
        guard path.hasPrefix(basePath + "/") else { return nil }
        return String(path.dropFirst(basePath.count + 1))
    }

    struct FileSearchResult: Identifiable {
        let id = UUID()
        let fileURL: URL
        let line: Int
        let preview: String
        var cellIndex: Int? = nil
    }

    func searchWorkspace(_ query: String, options: WorkspaceSearchOptions = WorkspaceSearchOptions(),
                         completion: @escaping (WorkspaceSearchReport) -> Void) {
        guard let root = workspace?.rootURL else { completion(WorkspaceSearchReport()); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = WorkspaceSearcher.search(root: root, query: query, options: options)
            DispatchQueue.main.async { completion(result) }
        }
    }

    func openSearchResult(_ result: FileSearchResult) {
        openFile(result.fileURL)
        if let index = result.cellIndex, let document = activeDocument,
           let cells = document.notebook?.cells, cells.indices.contains(index) {
            navigateTo(file: "<cell>", line: result.line, cellID: cells[index].id)
            return
        }
        guard result.fileURL.pathExtension.lowercased() != "ipynb" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let document = self?.openDocuments.first(where: { $0.url == result.fileURL }),
                  let tv = EditorRegistry.shared.view(for: document.id) else { return }
            let lines = (tv.string as NSString)
            var location = 0
            var current = 1
            lines.enumerateSubstrings(in: NSRange(location: 0, length: lines.length),
                                      options: [.byLines, .substringNotRequired]) { _, range, _, stop in
                if current == result.line {
                    location = range.location
                    stop.pointee = true
                }
                current += 1
            }
            tv.window?.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: location, length: 0))
            tv.scrollRangeToVisible(NSRange(location: location, length: 0))
        }
    }

    func runSelectionOrLine(in document: Document? = nil) {
        guard let document = document ?? activeDocument, document.kind == .script,
              let tv = EditorRegistry.shared.view(for: document.id) else { return }
        let ns = tv.string as NSString
        let selection = tv.selectedRange()
        let range = ns.lineRange(for: NSRange(location: min(selection.location, ns.length),
                                              length: min(selection.length, ns.length - min(selection.location, ns.length))))
        let code = Self.dedent(ns.substring(with: range))
        if selection.length == 0 {
            let next = min(NSMaxRange(range), ns.length)
            tv.setSelectedRange(NSRange(location: next, length: 0))
            tv.scrollRangeToVisible(NSRange(location: next, length: 0))
        }
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        revealConsole(force: true)
        runConsoleInput(code)
    }

    static func dedent(_ code: String) -> String {
        var lines = code.components(separatedBy: "\n").map { line -> String in
            var columns = 0
            var index = line.startIndex
            while index < line.endIndex, line[index] == " " || line[index] == "\t" {
                columns += line[index] == "\t" ? 4 : 1
                index = line.index(after: index)
            }
            return String(repeating: " ", count: columns) + line[index...]
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        let indents = lines
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " }.count }
        guard let common = indents.min(), common > 0 else { return lines.joined(separator: "\n") }
        return lines.map { String($0.dropFirst(min(common, $0.prefix { $0 == " " }.count))) }
            .joined(separator: "\n")
    }
}

final class LatexState: ObservableObject {
    @Published var generation = 0
}

final class CellSelection: ObservableObject {
    @Published var selectedCellID: UUID?
    @Published var selectedCellIDs: Set<UUID> = []
    var anchorCellID: UUID?
    @Published var isCommandMode = false
}
