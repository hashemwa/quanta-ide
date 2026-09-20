import AppKit

struct LanguageReference: Identifiable {
    let uri: String
    let position: LanguagePosition
    let label: String
    var id: String { "\(uri):\(position.line):\(position.character)" }
}

struct LanguageChange {
    let document: Document
    let cell: NotebookCell?
    let before: String
    let after: String
    let wasDirty: Bool
    var current: String { cell?.source ?? document.text }
    var reversed: LanguageChange {
        LanguageChange(document: document, cell: cell, before: after, after: before, wasDirty: true)
    }
}

enum LanguageRename {
    static func prepare(_ edit: [String: Any], documents: [Document], root: URL?, snapshots: [String: LanguageDocument], versions: [String: Int], oldName: String? = nil) throws -> [LanguageChange] {
        var grouped = edit["changes"] as? [String: [[String: Any]]] ?? [:]
        for item in edit["documentChanges"] as? [[String: Any]] ?? [] {
            guard let document = item["textDocument"] as? [String: Any], let uri = document["uri"] as? String,
                  let edits = item["edits"] as? [[String: Any]], item["kind"] == nil else {
                throw QuantaError("This rename requires unsupported file operations.")
            }
            if let version = document["version"] as? Int, version != versions[uri] { throw QuantaError("The document changed. Try renaming again.") }
            grouped[uri, default: []] += edits
        }
        var result: [LanguageChange] = []
        for (uri, edits) in grouped.sorted(by: { $0.key < $1.key }) {
            let document: Document
            let snapshot: LanguageDocument
            if let existing = snapshots[uri], let open = documents.first(where: { $0.id == existing.documentID }) {
                document = open; snapshot = existing
            } else {
                guard let url = URL(string: uri), url.isFileURL, ["py", "pyi"].contains(url.pathExtension.lowercased()),
                      let root, url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
                    throw QuantaError("Rename is limited to Python source files in this workspace.")
                }
                let open = documents.first { $0.url == url }
                let source: String
                if let open { source = open.text }
                else {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 4 * 1024 * 1024 else { throw QuantaError("A rename target is too large to edit safely.") }
                    source = try String(contentsOf: url, encoding: .utf8)
                }
                document = open ?? Document(script: url, text: source)
                snapshot = LanguageDocument(document: document, root: root)!
            }
            guard let segment = snapshot.segments.first, snapshot.segments.count == 1 else { throw QuantaError("Cannot map this rename to an editor.") }
            let cell = document.notebook?.cells.first { $0.id == segment.editorID }
            let before = cell?.source ?? document.text
            guard before == segment.source else { throw QuantaError("The document changed. Try renaming again.") }
            var parsed: [CompletionEdit] = []
            for item in edits {
                guard let range = snapshot.range(item["range"], editorID: segment.editorID), let value = item["newText"] as? String else { throw QuantaError("The language server returned an invalid rename edit.") }
                if let oldName, (before as NSString).substring(with: range) != oldName { throw QuantaError("A rename target no longer matches the original symbol. No changes were applied.") }
                parsed.append(CompletionEdit(range: range, text: value))
            }
            guard let first = parsed.first else { continue }
            var completion = CodeCompletion(label: "Rename", text: first.text, range: first.range)
            completion.additionalEdits = Array(parsed.dropFirst())
            guard let transaction = CompletionTransaction(source: before, completion: completion) else { throw QuantaError("The language server returned overlapping edits.") }
            let text = NSMutableString(string: before)
            for edit in transaction.edits.reversed() { text.replaceCharacters(in: edit.range, with: edit.text) }
            result.append(LanguageChange(document: document, cell: cell, before: before, after: text as String, wasDirty: document.isDirty))
        }
        return result
    }
}

extension AppState {
    func findReferences() {
        guard let editor = focusedCodeEditor, let id = editor.languageEditorID else { return }
        guard language.ready else { userNotice = language.status; return }
        language.findReferences(editorID: id, code: editor.string, offset: editor.selectedRange().location)
    }
    func renameSymbol() {
        guard let editor = focusedCodeEditor, let id = editor.languageEditorID else { return }
        guard language.ready else { userNotice = language.status; return }
        let alert = NSAlert()
        alert.messageText = "Rename Symbol"
        alert.informativeText = "Enter the new Python name. You can review the affected files before applying it."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Review Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue
        guard let first = name.first, first.isLetter || first == "_",
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
              !PythonHighlighter.keywords.contains(name), !PythonHighlighter.constants.contains(name) else {
            userNotice = "Enter a valid Python identifier."; return
        }
        language.rename(editorID: id, code: editor.string, offset: editor.selectedRange().location, name: name, undoManager: editor.undoManager)
    }

    func applyLanguageChanges(_ changes: [LanguageChange], undoManager: UndoManager?, restoring: Bool = false) throws {
        guard changes.allSatisfy({ $0.current == $0.before }) else { throw QuantaError("A document changed after the rename was prepared. No changes were applied.") }
        for change in changes where !openDocuments.contains(where: { $0.id == change.document.id }) {
            if let url = change.document.url {
                guard (try? String(contentsOf: url, encoding: .utf8)) == change.before else { throw QuantaError("A rename target changed on disk. No changes were applied.") }
            }
        }
        let reverse = changes.map(\.reversed)
        undoManager?.registerUndo(withTarget: self) { app in
            do { try app.applyLanguageChanges(reverse, undoManager: undoManager, restoring: !restoring) }
            catch { app.userNotice = error.localizedDescription }
        }
        undoManager?.setActionName("Rename Symbol")
        for change in changes {
            if !openDocuments.contains(where: { $0.id == change.document.id }) {
                change.document.fileModificationDate = change.document.url.flatMap { fileModificationDate(of: $0) }
                openDocuments.append(change.document)
            }
            if let cell = change.cell { cell.source = change.after }
            else { change.document.text = change.after }
            change.document.isDirty = true
        }
        language.synchronize()
    }
}
