import AppKit
import Combine

final class PythonLanguageService: ObservableObject {
    @Published private(set) var status = "Open a trusted workspace to enable analysis."
    @Published var showingReferences = false
    @Published private(set) var references: [LanguageReference] = []
    @Published private(set) var diagnostics: [UUID: [LanguageDiagnostic]] = [:]
    @Published var enabled = QuantaDefaults.store.object(forKey: "QuantaLanguageEnabled") as? Bool ?? true {
        didSet { QuantaDefaults.store.set(enabled, forKey: "QuantaLanguageEnabled"); restart() }
    }
    @Published private(set) var serverPath = QuantaDefaults.store.string(forKey: "QuantaNativeLanguageServer") ?? ""
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
    private var notebooks: [String: [String]] = [:]
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
            stop(); status = "ty not found. Install it or choose its executable in Settings → Editor."; return
        }
        let key = "\(root.path)|\(path)|\(executable.path)"
        if configuration != key {
            start(executable: executable, root: root, python: path)
            configuration = key
        }
        if ready { update(app.openDocuments, root: root) }
    }

    static func findServer(configured: String) -> URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ty").path
        let paths = configured.isEmpty ? [bundled, "/opt/homebrew/bin/ty", "/usr/local/bin/ty",
                                           NSHomeDirectory() + "/.local/bin/ty"] : [configured]
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
        status = "Starting ty…"
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
                    case "ty": return self.settings
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
        } catch { status = "Could not start ty: \(error.localizedDescription)"; return }
        server.request("initialize", [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "rootUri": root.absoluteString,
            "clientInfo": ["name": "Quanta"],
            "capabilities": [
                "general": ["positionEncodings": ["utf-16"]],
                "workspace": ["configuration": true, "workspaceFolders": true],
                "notebookDocument": ["synchronization": ["dynamicRegistration": false]],
                "textDocument": ["completion": ["completionItem": ["snippetSupport": true, "documentationFormat": ["plaintext"]]],
                                 "publishDiagnostics": ["versionSupport": true],
                                 "hover": ["contentFormat": ["plaintext"]],
                                 "signatureHelp": ["signatureInformation": ["documentationFormat": ["plaintext"]]]],
            ],
            "initializationOptions": ["experimental": ["useUv": "off"]],
            "workspaceFolders": [["uri": root.absoluteString, "name": root.lastPathComponent]],
        ]) { [weak self] result in
            guard let self, self.session == currentSession else { return }
            guard let result = result as? [String: Any] else {
                self.server.stop()
                self.status = "ty did not initialize. Check its installation, then restart analysis."
                return
            }
            let capabilities = result["capabilities"] as? [String: Any] ?? [:]
            guard (capabilities["positionEncoding"] as? String ?? "utf-16") == "utf-16" else {
                self.stop(); self.status = "The language server must support UTF-16 positions."; return
            }
            self.server.notify("initialized", [:])
            self.server.notify("workspace/didChangeConfiguration", ["settings": ["ty": self.settings]])
            self.ready = true
            self.status = "ty ready"
            self.watcher = WorkspaceWatcher(url: root, onFileChanges: { [weak self] changes in
                self?.filesChanged(changes)
            }, onChange: {})
            self.synchronize()
        }
    }

    private var settings: [String: Any] {
        ["diagnosticMode": "openFilesOnly", "configuration": ["environment": ["python": python ?? ""]],
         "completions": ["autoImport": true, "completeFunctionParentheses": true]]
    }

    func stop() {
        scheduled?.cancel()
        session += 1
        ready = false
        configuration = nil
        snapshots.removeAll()
        notebooks.removeAll()
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
        panel.message = "Choose the ty executable. It runs when analysis is enabled in a trusted workspace."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            app?.userNotice = "Choose an executable ty file."; return
        }
        serverPath = url.path
        QuantaDefaults.store.set(serverPath, forKey: "QuantaNativeLanguageServer")
        restart()
    }

    func useAutomaticServer() {
        serverPath = ""
        QuantaDefaults.store.removeObject(forKey: "QuantaNativeLanguageServer")
        restart()
    }

    func update(_ documents: [Document], root: URL) {
        guard ready else { return }
        let current = documents.flatMap { LanguageDocument.documents($0, root: root) }
        let previous = snapshots
        let activeURIs = Set(current.map(\.uri))
        let groups = Dictionary(grouping: current.filter { $0.notebookURI != nil }, by: { $0.notebookURI! })
        var changed = false
        for uri in Array(notebooks.keys) where groups[uri] == nil {
            server.notify("notebookDocument/didClose", ["notebookDocument": ["uri": uri],
                          "cellTextDocuments": notebooks[uri, default: []].map { ["uri": $0] }])
            notebooks.removeValue(forKey: uri)
        }
        for uri in Array(snapshots.keys) where !activeURIs.contains(uri) {
            if snapshots[uri]?.notebookURI == nil {
                server.notify("textDocument/didClose", ["textDocument": ["uri": uri]])
            }
            snapshots.removeValue(forKey: uri)
            versions.removeValue(forKey: uri)
            changed = true
        }
        for snapshot in current where previous[snapshot.uri] != snapshot {
            revision += 1
            versions[snapshot.uri] = revision
            snapshots[snapshot.uri] = snapshot
            changed = true
            if snapshot.notebookURI == nil {
                if previous[snapshot.uri] == nil {
                    server.notify("textDocument/didOpen", ["textDocument": textDocument(snapshot)])
                } else {
                    server.notify("textDocument/didChange", ["textDocument": ["uri": snapshot.uri, "version": revision], "contentChanges": [["text": snapshot.text]]])
                }
            }
            let ids = Set(snapshot.segments.map(\.editorID))
            diagnostics[snapshot.documentID]?.removeAll { ids.contains($0.editorID) }
        }
        for (uri, cells) in groups {
            let newURIs = cells.map(\.uri)
            let cellList: [[String: Any]] = newURIs.map { ["kind": 2, "document": $0] }
            if let oldURIs = notebooks[uri] {
                var change: [String: Any] = [:]
                if oldURIs != newURIs {
                    change["structure"] = ["array": ["start": 0, "deleteCount": oldURIs.count, "cells": cellList],
                                           "didOpen": cells.filter { !oldURIs.contains($0.uri) }.map(textDocument),
                                           "didClose": oldURIs.filter { !newURIs.contains($0) }.map { ["uri": $0] }]
                }
                let edits: [[String: Any]] = cells.filter { oldURIs.contains($0.uri) && previous[$0.uri] != $0 }.map {
                    ["document": ["uri": $0.uri, "version": versions[$0.uri, default: 1]], "changes": [["text": $0.text]]]
                }
                if !edits.isEmpty { change["textContent"] = edits }
                if !change.isEmpty {
                    revision += 1
                    server.notify("notebookDocument/didChange", ["notebookDocument": ["uri": uri, "version": revision], "change": ["cells": change]])
                }
            } else {
                server.notify("notebookDocument/didOpen", ["notebookDocument": ["uri": uri, "notebookType": "jupyter-notebook", "version": revision, "cells": cellList],
                                                         "cellTextDocuments": cells.map(textDocument)])
            }
            notebooks[uri] = newURIs
        }
        let activeEditors = Set(current.flatMap { $0.segments.map(\.editorID) })
        let activeIDs = Set(current.map(\.documentID))
        diagnostics = diagnostics.filter { activeIDs.contains($0.key) }.mapValues { $0.filter { activeEditors.contains($0.editorID) } }
        if changed { applyDiagnostics() }
    }

    private func textDocument(_ snapshot: LanguageDocument) -> [String: Any] {
        ["uri": snapshot.uri, "languageId": "python", "version": versions[snapshot.uri, default: 1], "text": snapshot.text]
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
        let otherCells = diagnostics[snapshot.documentID, default: []].filter { old in !snapshot.segments.contains { $0.editorID == old.editorID } }
        diagnostics[snapshot.documentID] = otherCells + values.sorted {
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
                 parameters: [String: Any] = [:], reply: @escaping (Any?, LanguageDocument?) -> Void) {
        guard let (snapshot, position) = context(editorID: editorID, code: code, offset: offset) else { reply(nil, nil); return }
        let key = "\(editorID):\(method)"
        if let previous = requests.removeValue(forKey: key) { server.cancel(previous) }
        let version = versions[snapshot.uri]
        let requestRevision = revision
        let currentSession = session
        let params = parameters.merging(["textDocument": ["uri": snapshot.uri], "position": position.json]) { _, value in value }
        requests[key] = server.request(method, params) { [weak self] result in
            guard let self, self.session == currentSession, self.versions[snapshot.uri] == version, self.revision == requestRevision else { reply(nil, nil); return }
            self.requests.removeValue(forKey: key)
            reply(result, snapshot)
        }
    }

    func suggestions(editorID: UUID, code: String, offset: Int, reply: @escaping ([CodeCompletion]) -> Void) {
        request("textDocument/completion", editorID: editorID, code: code, offset: offset) { result, snapshot in
            guard let snapshot else { reply([]); return }
            let items = (result as? [[String: Any]]) ?? (result as? [String: Any])?["items"] as? [[String: Any]] ?? []
            reply(items.prefix(500).compactMap { CodeCompletion.parse($0, snapshot: snapshot, editorID: editorID, offset: offset) })
        }
    }

    func completions(editorID: UUID, code: String, offset: Int, reply: @escaping ([String], Int, Int) -> Void) {
        suggestions(editorID: editorID, code: code, offset: offset) { items in
            let range = items.first?.edit.range ?? NSRange(location: offset, length: 0)
            reply(items.map(\.label), range.location, NSMaxRange(range))
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
    func findReferences(editorID: UUID, code: String, offset: Int) {
        request("textDocument/references", editorID: editorID, code: code, offset: offset, parameters: ["context": ["includeDeclaration": true]]) { [weak self] result, snapshot in
            guard let self, snapshot != nil else { return }
            self.references = (result as? [[String: Any]] ?? []).compactMap { item in
                guard let uri = item["uri"] as? String, let range = item["range"] as? [String: Any], let position = LanguagePosition(range["start"]) else { return nil }
                let target = self.snapshots[uri]
                let document = self.app?.openDocuments.first { $0.id == target?.documentID }
                let cell = document?.notebook?.cells.firstIndex { $0.id == target?.segments.first?.editorID }
                let file = document?.displayName ?? URL(string: uri)?.lastPathComponent ?? uri
                let label = file + (cell.map { " · Cell \($0 + 1)" } ?? "") + " · Line \(position.line + 1)"
                return LanguageReference(uri: uri, position: position, label: label)
            }
            self.showingReferences = true
        }
    }

    func reveal(_ reference: LanguageReference) {
        showingReferences = false
        if let snapshot = snapshots[reference.uri], let location = snapshot.location(reference.position) {
            app?.revealLanguageLocation(documentID: snapshot.documentID, editorID: location.editorID, offset: location.offset)
        } else if let url = URL(string: reference.uri), url.isFileURL, ["py", "pyi"].contains(url.pathExtension.lowercased()) {
            app?.openFile(url)
            if let document = app?.openDocuments.first(where: { $0.url == url }), let offset = LanguagePosition.offset(reference.position, in: document.text) {
                app?.revealLanguageLocation(documentID: document.id, editorID: document.id, offset: offset)
            }
        }
    }

    func rename(editorID: UUID, code: String, offset: Int, name: String, undoManager: UndoManager?) {
        let ns = code as NSString
        var start = min(offset, ns.length), end = min(offset, ns.length)
        func identifier(_ unit: unichar) -> Bool { unit == 95 || (48...57).contains(unit) || (65...90).contains(unit) || (97...122).contains(unit) || unit > 127 }
        while start > 0, identifier(ns.character(at: start - 1)) { start -= 1 }
        while end < ns.length, identifier(ns.character(at: end)) { end += 1 }
        let oldName = ns.substring(with: NSRange(location: start, length: end - start))
        request("textDocument/rename", editorID: editorID, code: code, offset: offset, parameters: ["newName": name]) { [weak self] result, snapshot in
            guard let self, let app = self.app else { return }
            guard snapshot != nil, let edit = result as? [String: Any] else { app.userNotice = "This symbol cannot be renamed, or its source changed. Try again at its definition."; return }
            do {
                let changes = try LanguageRename.prepare(edit, documents: app.openDocuments, root: app.workspace?.rootURL, snapshots: self.snapshots, versions: self.versions, oldName: oldName)
                guard !changes.isEmpty else { app.userNotice = "No occurrences can be renamed here."; return }
                let alert = NSAlert()
                alert.messageText = "Rename to “\(name)”?"
                let names = Array(Set(changes.map { $0.document.displayName })).sorted()
                alert.informativeText = "Update \(changes.count) source sections in:\n" + names.joined(separator: "\n") + "\n\nChanges remain unsaved and can be undone."
                alert.addButton(withTitle: "Rename")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn { try app.applyLanguageChanges(changes, undoManager: undoManager) }
            } catch { app.userNotice = error.localizedDescription }
        }
    }

}
