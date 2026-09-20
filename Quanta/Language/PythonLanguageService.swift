import AppKit
import Combine

final class PythonLanguageService: ObservableObject {
    @Published private(set) var status = "Open a trusted workspace to enable analysis."
    @Published private(set) var diagnostics: [UUID: [LanguageDiagnostic]] = [:]
    @Published var enabled = QuantaDefaults.store.object(forKey: "QuantaLanguageEnabled") as? Bool ?? true {
        didSet { QuantaDefaults.store.set(enabled, forKey: "QuantaLanguageEnabled"); restart() }
    }
    @Published private(set) var serverPath = QuantaDefaults.store.string(forKey: "QuantaLanguageServer") ?? ""
    private(set) var ready = false
    private let server = LanguageServer()
    private weak var app: AppState?
    private var subscriptions: [AnyCancellable] = []
    private var documentSubscriptions: [AnyCancellable] = []
    private var scheduled: DispatchWorkItem?
    private var configuration: String?
    private var session = 0
    private var revision = 0
    private var snapshots: [String: LanguageDocument] = [:]
    private var versions: [String: Int] = [:]
    private var requests: [String: Int] = [:]
    private var python: String?
    private var automaticStartup = false
    private var watcher: WorkspaceWatcher?

    func observe(_ app: AppState, automatic: Bool = !QuantaDefaults.isRunningTests) {
        self.app = app
        automaticStartup = automatic
        guard automatic else { return }
        app.$workspace.map { $0?.rootURL }.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        app.$pythonPath.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        app.$openDocuments.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.bindDocuments() }.store(in: &subscriptions)
    }

    private func bindDocuments() {
        documentSubscriptions.removeAll()
        guard let app else { return }
        for document in app.openDocuments {
            document.$text.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.schedule() }.store(in: &documentSubscriptions)
            document.$url.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.schedule() }.store(in: &documentSubscriptions)
            document.$notebook.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.bindDocuments() }.store(in: &documentSubscriptions)
            if let notebook = document.notebook {
                notebook.$cells.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.bindDocuments() }.store(in: &documentSubscriptions)
                for cell in notebook.cells {
                    cell.$source.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.schedule() }.store(in: &documentSubscriptions)
                    cell.$cellType.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.schedule() }.store(in: &documentSubscriptions)
                }
            }
        }
        schedule()
    }

    func schedule() {
        scheduled?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.synchronize() }
        scheduled = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func synchronize() {
        guard let app, automaticStartup else { return }
        guard enabled else { stop(); status = "Python analysis is off."; return }
        guard let root = app.workspace?.rootURL, app.isWorkspaceTrusted else {
            stop(); status = "Open a trusted workspace to enable analysis."; return
        }
        guard let path = app.pythonPath,
              let environment = app.environments.first(where: { $0.executable == path }),
              WorkspaceTrust.allows(environment, workspace: root) else {
            stop(); status = "Select a trusted Python interpreter to enable analysis."; return
        }
        guard let executable = Self.findServer(configured: serverPath) else {
            stop(); status = "Pyright not found. Install it or choose its executable in Settings → Editor."; return
        }
        let key = "\(root.path)|\(path)|\(executable.path)"
        if configuration != key {
            start(executable: executable, root: root, python: path)
            configuration = key
        }
        if ready { update(app.openDocuments, root: root) }
    }

    static func findServer(configured: String) -> URL? {
        let paths = configured.isEmpty ? ["/opt/homebrew/bin/pyright-langserver", "/usr/local/bin/pyright-langserver",
                                           NSHomeDirectory() + "/.local/bin/pyright-langserver"] : [configured]
        return paths.first { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static func environment(server: URL, python: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["NODE_OPTIONS", "NODE_PATH", "PYTHONPATH", "PYTHONHOME"] { env.removeValue(forKey: key) }
        let inherited = (env["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        let paths = [server.deletingLastPathComponent().path, (python as NSString).deletingLastPathComponent,
                     "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] + inherited
        env["PATH"] = paths.joined(separator: ":")
        return env
    }

    func start(executable: URL, root: URL, python: String) {
        stop()
        self.python = python
        let currentSession = session
        status = "Starting Pyright…"
        server.onFailure = { [weak self] message in
            guard let self else { return }
            self.ready = false
            self.watcher = nil
            self.clearDiagnostics()
            self.status = message
        }
        server.onRequest = { [weak self] method, params in
            guard let self else { return NSNull() }
            if method == "workspace/configuration" {
                return (params["items"] as? [[String: Any]] ?? []).map { item -> Any in
                    switch item["section"] as? String {
                    case "python": return self.settings
                    case "python.analysis": return self.analysisSettings
                    case "pyright": return ["disableOrganizeImports": true]
                    default: return NSNull()
                    }
                }
            }
            if method == "workspace/applyEdit" { return ["applied": false] }
            return NSNull()
        }
        server.onNotification = { [weak self] method, params in
            if method == "textDocument/publishDiagnostics" { self?.receiveDiagnostics(params) }
        }
        do {
            try server.start(executable: executable, root: root, environment: Self.environment(server: executable, python: python))
        } catch { status = "Could not start Pyright: \(error.localizedDescription)"; return }
        server.request("initialize", [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "rootUri": root.absoluteString,
            "clientInfo": ["name": "Quanta"],
            "capabilities": [
                "general": ["positionEncodings": ["utf-16"]],
                "workspace": ["configuration": true, "workspaceFolders": true],
                "textDocument": ["completion": ["completionItem": ["snippetSupport": false]],
                                 "publishDiagnostics": ["versionSupport": true],
                                 "hover": ["contentFormat": ["plaintext"]],
                                 "signatureHelp": ["signatureInformation": ["documentationFormat": ["plaintext"]]]],
            ],
            "workspaceFolders": [["uri": root.absoluteString, "name": root.lastPathComponent]],
        ]) { [weak self] result in
            guard let self, self.session == currentSession else { return }
            guard let result = result as? [String: Any] else {
                self.server.stop()
                self.status = "Pyright did not initialize. Check its installation, then restart analysis."
                return
            }
            let capabilities = result["capabilities"] as? [String: Any] ?? [:]
            guard (capabilities["positionEncoding"] as? String ?? "utf-16") == "utf-16" else {
                self.stop(); self.status = "The language server must support UTF-16 positions."; return
            }
            self.server.notify("initialized", [:])
            self.server.notify("workspace/didChangeConfiguration", ["settings": ["python": self.settings]])
            self.ready = true
            self.status = "Pyright ready"
            self.watcher = WorkspaceWatcher(url: root, onFileChanges: { [weak self] changes in
                self?.filesChanged(changes)
            }, onChange: {})
            self.synchronize()
        }
    }

    private var analysisSettings: [String: Any] {
        ["diagnosticMode": "openFilesOnly", "typeCheckingMode": "basic", "autoImportCompletions": false,
         "autoSearchPaths": true, "useLibraryCodeForTypes": true]
    }

    private var settings: [String: Any] { ["pythonPath": python ?? "", "analysis": analysisSettings] }

    func stop() {
        scheduled?.cancel()
        session += 1
        ready = false
        configuration = nil
        snapshots.removeAll()
        versions.removeAll()
        requests.removeAll()
        watcher = nil
        server.stop()
        clearDiagnostics()
    }

    func restart() { stop(); synchronize() }

    func filesChanged(_ changes: [(URL, Int)]) {
        guard ready, !changes.isEmpty else { return }
        server.notify("workspace/didChangeWatchedFiles", ["changes": changes.map { ["uri": $0.0.absoluteString, "type": $0.1] }])
    }

    func chooseServer() {
        let panel = NSOpenPanel()
        panel.message = "Choose the pyright-langserver executable. It runs when analysis is enabled in a trusted workspace."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            app?.userNotice = "Choose an executable pyright-langserver file."; return
        }
        serverPath = url.path
        QuantaDefaults.store.set(serverPath, forKey: "QuantaLanguageServer")
        restart()
    }

    func useAutomaticServer() {
        serverPath = ""
        QuantaDefaults.store.removeObject(forKey: "QuantaLanguageServer")
        restart()
    }

    func update(_ documents: [Document], root: URL) {
        guard ready else { return }
        let current = documents.compactMap { LanguageDocument(document: $0, root: root) }
        let activeURIs = Set(current.map(\.uri))
        var changed = false
        for uri in Array(snapshots.keys) where !activeURIs.contains(uri) {
            server.notify("textDocument/didClose", ["textDocument": ["uri": uri]])
            snapshots.removeValue(forKey: uri)
            versions.removeValue(forKey: uri)
            changed = true
        }
        for snapshot in current where snapshots[snapshot.uri] != snapshot {
            let previous = snapshots[snapshot.uri]
            revision += 1
            versions[snapshot.uri] = revision
            snapshots[snapshot.uri] = snapshot
            changed = true
            if previous == nil {
                server.notify("textDocument/didOpen", ["textDocument": ["uri": snapshot.uri, "languageId": "python", "version": revision, "text": snapshot.text]])
            } else {
                server.notify("textDocument/didChange", ["textDocument": ["uri": snapshot.uri, "version": revision], "contentChanges": [["text": snapshot.text]]])
            }
            diagnostics[snapshot.documentID] = []
        }
        let activeIDs = Set(current.map(\.documentID))
        if diagnostics.keys.contains(where: { !activeIDs.contains($0) }) {
            diagnostics = diagnostics.filter { activeIDs.contains($0.key) }
        }
        if changed { applyDiagnostics() }
    }

    private func clearDiagnostics() {
        if !diagnostics.isEmpty { diagnostics = [:] }
        for view in EditorRegistry.shared.allViews { view.applyLanguageDiagnostics([]) }
    }

    func receiveDiagnostics(_ params: [String: Any]) {
        guard let uri = params["uri"] as? String, let snapshot = snapshots[uri],
              let version = params["version"] as? Int, version == versions[uri] else { return }
        let values = (params["diagnostics"] as? [[String: Any]] ?? []).prefix(500).compactMap { item -> LanguageDiagnostic? in
            guard let raw = item["range"] as? [String: Any], let start = LanguagePosition(raw["start"]),
                  let location = snapshot.location(start), let range = snapshot.range(raw, editorID: location.editorID),
                  let segment = snapshot.segments.first(where: { $0.editorID == location.editorID }),
                  let position = LanguagePosition.at(range.location, in: segment.source),
                  let message = item["message"] as? String else { return nil }
            return LanguageDiagnostic(editorID: location.editorID, range: range, message: message,
                                      severity: item["severity"] as? Int ?? 2, line: position.line + 1)
        }
        let order = Dictionary(uniqueKeysWithValues: snapshot.segments.enumerated().map { ($0.element.editorID, $0.offset) })
        diagnostics[snapshot.documentID] = values.sorted {
            (order[$0.editorID, default: 0], $0.range.location) < (order[$1.editorID, default: 0], $1.range.location)
        }
        applyDiagnostics()
    }

    func applyDiagnostics(to view: QuantaTextView? = nil) {
        let views = view.map { [$0] } ?? EditorRegistry.shared.allViews
        for view in views {
            guard let id = view.languageEditorID,
                  let snapshot = snapshots.values.first(where: { $0.segments.contains { $0.editorID == id && $0.source == view.string } }) else {
                view.applyLanguageDiagnostics([]); continue
            }
            view.applyLanguageDiagnostics(diagnostics[snapshot.documentID, default: []].filter { $0.editorID == id })
        }
    }

    private func context(editorID: UUID, code: String, offset: Int) -> (LanguageDocument, LanguagePosition)? {
        synchronize()
        guard ready, let snapshot = snapshots.values.first(where: { $0.segments.contains { $0.editorID == editorID && $0.source == code } }),
              let position = snapshot.position(editorID: editorID, offset: offset) else { return nil }
        return (snapshot, position)
    }

    func request(_ method: String, editorID: UUID, code: String, offset: Int,
                 reply: @escaping (Any?, LanguageDocument?) -> Void) {
        guard let (snapshot, position) = context(editorID: editorID, code: code, offset: offset) else { reply(nil, nil); return }
        let key = "\(editorID):\(method)"
        if let previous = requests.removeValue(forKey: key) { server.cancel(previous) }
        let version = versions[snapshot.uri]
        let currentSession = session
        requests[key] = server.request(method, ["textDocument": ["uri": snapshot.uri], "position": position.json]) { [weak self] result in
            guard let self, self.session == currentSession, self.versions[snapshot.uri] == version else { reply(nil, nil); return }
            self.requests.removeValue(forKey: key)
            reply(result, snapshot)
        }
    }

    func completions(editorID: UUID, code: String, offset: Int, reply: @escaping ([String], Int, Int) -> Void) {
        request("textDocument/completion", editorID: editorID, code: code, offset: offset) { result, snapshot in
            guard let snapshot else { reply([], offset, offset); return }
            let items = (result as? [[String: Any]]) ?? (result as? [String: Any])?["items"] as? [[String: Any]] ?? []
            let prefix = (code as NSString).substring(to: offset)
            let token = prefix.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            var bounds = NSRange(location: offset - String(token).utf16.count, length: String(token).utf16.count)
            var matches: [String] = []
            for item in items {
                guard item["insertTextFormat"] as? Int != 2, (item["additionalTextEdits"] as? [Any] ?? []).isEmpty else { continue }
                let edit = item["textEdit"] as? [String: Any]
                let range = edit.flatMap { snapshot.range($0["range"] ?? $0["replace"], editorID: editorID) } ?? bounds
                guard range.location <= offset, NSMaxRange(range) >= offset else { continue }
                if matches.isEmpty { bounds = range }
                guard range == bounds, let value = edit?["newText"] as? String ?? item["insertText"] as? String ?? item["label"] as? String else { continue }
                if !matches.contains(value) { matches.append(value) }
                if matches.count == 300 { break }
            }
            reply(matches, bounds.location, NSMaxRange(bounds))
        }
    }

    func inspect(editorID: UUID, code: String, offset: Int, reply: @escaping (InspectionInfo?) -> Void) {
        request("textDocument/signatureHelp", editorID: editorID, code: code, offset: offset) { [weak self] result, snapshot in
            if let value = result as? [String: Any], let signatures = value["signatures"] as? [[String: Any]], !signatures.isEmpty {
                let index = value["activeSignature"] as? Int ?? 0
                let signature = signatures[signatures.indices.contains(index) ? index : 0]
                reply(InspectionInfo(signature: signature["label"] as? String ?? "", doc: Self.documentation(signature["documentation"])))
            } else if snapshot != nil, let self {
                self.request("textDocument/hover", editorID: editorID, code: code, offset: offset) { result, _ in
                    let text = Self.documentation((result as? [String: Any])?["contents"])
                    reply(text.isEmpty ? nil : InspectionInfo(signature: "", doc: text))
                }
            } else { reply(nil) }
        }
    }

    static func documentation(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let dict = value as? [String: Any] { return dict["value"] as? String ?? "" }
        if let values = value as? [Any] { return values.map(documentation).joined(separator: "\n\n") }
        return ""
    }

    func definition(editorID: UUID, code: String, offset: Int) {
        request("textDocument/definition", editorID: editorID, code: code, offset: offset) { [weak self] result, snapshot in
            guard let self, let snapshot, self.app?.activeDocumentID == snapshot.documentID else { return }
            if let editor = EditorRegistry.shared.view(for: editorID), editor.selectedRange().location != offset { return }
            let first = (result as? [[String: Any]])?.first ?? result as? [String: Any]
            guard let first, let uri = first["uri"] as? String ?? first["targetUri"] as? String,
                  let range = (first["targetSelectionRange"] ?? first["range"]) as? [String: Any],
                  let position = LanguagePosition(range["start"]) else {
                self.app?.userNotice = "No definition found at this position."; return
            }
            if let target = self.snapshots[uri], let location = target.location(position) {
                self.app?.revealLanguageLocation(documentID: target.documentID, editorID: location.editorID, offset: location.offset)
            } else if let url = URL(string: uri), url.isFileURL, ["py", "pyi"].contains(url.pathExtension.lowercased()) {
                self.app?.openFile(url)
                if let document = self.app?.openDocuments.first(where: { $0.url == url }),
                   let offset = LanguagePosition.offset(position, in: document.text) {
                    self.app?.revealLanguageLocation(documentID: document.id, editorID: document.id, offset: offset)
                }
            }
        }
    }
}
