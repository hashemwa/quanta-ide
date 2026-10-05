import AppKit
import Combine

final class DocumentCodeTools: ObservableObject {
    @Published private(set) var diagnostics: [PythonDiagnostic] = []
    @Published private(set) var isChecking = false
    @Published private(set) var isFormatting = false
    @Published private(set) var hasChecked = false
    @Published private(set) var toolName = "Python"
    @Published private(set) var notice: String?
    private(set) var checkedSources: [UUID: String] = [:]
    @MainActor private lazy var analyzer = PythonTooling()
    @MainActor private lazy var formatter = PythonTooling()
    private weak var document: Document?
    private var python: String?
    private var directory: URL?
    private var enabled = false
    private var generation = UUID()
    private var pending: DispatchWorkItem?
    private var subscriptions: Set<AnyCancellable> = []
    private var cellSubscriptions: Set<AnyCancellable> = []
    private var notebookSubscription: AnyCancellable?

    @MainActor
    func configure(document: Document, python: String?, directory: URL?, enabled: Bool) {
        guard self.document !== document || self.python != python || self.directory != directory
                || self.enabled != enabled else { return }
        cancel()
        self.document = document
        self.python = python
        self.directory = directory
        self.enabled = enabled
        subscriptions.removeAll()
        cellSubscriptions.removeAll()
        notebookSubscription = nil
        if document.kind == .script {
            document.$text.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            }.store(in: &subscriptions)
        } else if document.kind == .notebook {
            document.$notebook.receive(on: DispatchQueue.main).sink { [weak self] notebook in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.notebookSubscription = notebook?.$cells.receive(on: DispatchQueue.main).sink { [weak self] cells in
                        MainActor.assumeIsolated { self?.observe(cells) }
                    }
                    if notebook == nil { self.observe([]) }
                }
            }.store(in: &subscriptions)
        }
        schedule()
    }

    @MainActor
    private func observe(_ cells: [NotebookCell]) {
        cellSubscriptions.removeAll()
        for cell in cells {
            cell.$source.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            }.store(in: &cellSubscriptions)
            cell.$cellType.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            }.store(in: &cellSubscriptions)
        }
        schedule()
    }

    @MainActor
    func schedule() {
        pending?.cancel()
        analyzer.cancel()
        generation = UUID()
        checkedSources = [:]
        diagnostics = []
        hasChecked = false
        isChecking = false
        guard enabled, python != nil, let document, document.isFileBacked else {
            notice = enabled ? "Select a Python interpreter to check code." : "Trust the workspace to check Python code."
            return
        }
        notice = nil
        let request = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == request else { return }
            self.checkNow()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    @MainActor
    func checkNow() {
        pending?.cancel()
        pending = nil
        guard enabled, let python, let document, document.isFileBacked else { return }
        let sources = document.pythonSources
        let request = UUID()
        generation = request
        isChecking = true
        notice = nil
        analyzer.analyze(sources: sources, python: python, workingDirectory: directory,
                         isNotebook: document.kind == .notebook) { [weak self, weak document] result in
            guard let self, let document, self.generation == request,
                  document.pythonSources == sources else { return }
            self.isChecking = false
            switch result {
            case .success(let analysis):
                self.checkedSources = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.source) })
                self.diagnostics = analysis.diagnostics
                self.toolName = analysis.toolName
                self.notice = analysis.notice
                self.hasChecked = true
            case .failure(let error):
                self.checkedSources = [:]
                self.diagnostics = []
                self.hasChecked = false
                self.notice = error.localizedDescription
            }
        }
    }

    @MainActor
    func format(sourceID: UUID, apply: @escaping (String, String) -> Bool) {
        guard !isFormatting, enabled, let python, let document,
              let source = document.pythonSources.first(where: { $0.id == sourceID }) else { return }
        isFormatting = true
        notice = nil
        formatter.format(source: source.source, python: python, workingDirectory: directory,
                         isNotebook: document.kind == .notebook) { [weak self, weak document] result in
            guard let self else { return }
            self.isFormatting = false
            guard let document, self.document === document,
                  self.enabled, self.python == python,
                  document.pythonSources.first(where: { $0.id == sourceID }) == source else {
                self.notice = "Code changed while formatting. Format again to use the latest version."
                return
            }
            switch result {
            case .success(let text):
                if text == source.source {
                    self.notice = "Code is already formatted."
                } else if apply(source.source, text) {
                    self.schedule()
                } else {
                    self.notice = "The editor changed while formatting. Format again in the active editor."
                }
            case .failure(let error):
                self.notice = error.localizedDescription
            }
        }
    }

    @MainActor
    func cancel() {
        pending?.cancel()
        pending = nil
        generation = UUID()
        analyzer.cancel()
        formatter.cancel()
        isChecking = false
        isFormatting = false
    }
}

extension Document {
    var pythonSources: [PythonSourceInput] {
        if kind == .script { return [PythonSourceInput(id: id, source: text)] }
        return notebook?.cells.filter { $0.cellType == .code }.map {
            PythonSourceInput(id: $0.id, source: $0.source)
        } ?? []
    }
}

extension PythonDiagnostic {
    func editorRange(in source: String) -> NSRange {
        let text = source as NSString
        func offset(line: Int, column: Int) -> Int {
            let start = AppState.lineLocation(in: text, line: max(1, line))
            guard start < text.length else { return text.length }
            let range = text.lineRange(for: NSRange(location: start, length: 0))
            let value = text.substring(with: range).trimmingTrailingNewlines
            return start + value.prefix(max(0, column - 1)).utf16.count
        }
        let start = min(text.length, offset(line: line, column: column))
        let end = min(text.length, max(start, offset(line: endLine, column: endColumn)))
        if end > start { return NSRange(location: start, length: end - start) }
        if start < text.length { return text.rangeOfComposedCharacterSequence(at: start) }
        return NSRange(location: start, length: 0)
    }
}

extension AppState {
    func showPythonEnvironment() {
        refreshEnvironments()
        showsPythonEnvironment = true
    }

    var codeToolsPython: String? {
        let allowed = environments.filter { WorkspaceTrust.allows($0, workspace: workspace?.rootURL) }
        if let pythonPath { return allowed.first { $0.executable == pythonPath }?.executable }
        return PythonLocator.preferred(from: allowed)?.executable
    }

    @MainActor
    func configureCodeTools(for document: Document) {
        document.codeTools.configure(document: document, python: codeToolsPython,
                                     directory: workspace?.rootURL ?? document.url?.deletingLastPathComponent(),
                                     enabled: isWorkspaceTrusted && kernelTransition == nil)
    }

    @MainActor
    func checkActivePython() {
        guard let document = activeDocument, document.isFileBacked else { return }
        if !isWorkspaceTrusted { requestWorkspaceTrust(); return }
        configureCodeTools(for: document)
        document.codeTools.checkNow()
        showProblems()
    }

    func showProblems() {
        bottomPane = .problems
        setConsoleVisible(true)
    }

    @MainActor
    func formatActivePython() {
        guard let document = activeDocument, document.isFileBacked else { return }
        if !isWorkspaceTrusted { requestWorkspaceTrust(); return }
        configureCodeTools(for: document)
        let sourceID = document.kind == .script ? document.id : selectedCellID
        guard let sourceID, document.pythonSources.contains(where: { $0.id == sourceID }) else { return }
        showProblems()
        if document.kind == .notebook {
            document.notebook?.cells.first { $0.id == sourceID }?.isSourceCollapsed = false
            isCommandMode = false
            focusCellEditor(sourceID)
        }
        func attempt(_ remaining: Int) {
            guard activeDocumentID == document.id else { return }
            guard let editor = EditorRegistry.shared.view(for: sourceID) else {
                if remaining > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { attempt(remaining - 1) }
                } else {
                    userNotice = "The editor is not ready to format. Try Format Code again."
                }
                return
            }
            document.codeTools.format(sourceID: sourceID) { [weak self, weak document, weak editor] original, formatted in
                guard let self, let document, let editor, self.activeDocumentID == document.id else { return false }
                return editor.applyPythonFormatting(original: original, formatted: formatted)
            }
        }
        attempt(12)
    }

    @MainActor
    func revealDiagnostic(_ diagnostic: PythonDiagnostic, in document: Document) {
        guard let source = document.pythonSources.first(where: { $0.id == diagnostic.sourceID }),
              document.codeTools.checkedSources[source.id] == source.source else { return }
        activeDocumentID = document.id
        let range = diagnostic.editorRange(in: source.source)
        if document.kind == .notebook {
            selectedCellID = diagnostic.sourceID
            document.notebook?.cells.first { $0.id == diagnostic.sourceID }?.isSourceCollapsed = false
            isCommandMode = false
            focusCellEditor(diagnostic.sourceID, caret: range.location)
        } else {
            focusEditor(document.id, caret: range.location)
        }
    }
}
