import AppKit

extension AppState {
    var focusedCodeEditor: QuantaTextView? {
        (NSApp.keyWindow?.firstResponder as? QuantaTextView)
            ?? selectedCellID.flatMap { EditorRegistry.shared.view(for: $0) }
            ?? activeDocumentID.flatMap { EditorRegistry.shared.view(for: $0) }
    }

    func goToDefinition() {
        guard let editor = focusedCodeEditor, let id = editor.languageEditorID else { return }
        if !language.ready { userNotice = language.status; return }
        language.definition(editorID: id, code: editor.string, offset: editor.selectedRange().location)
    }

    func showEditorDocumentation() { focusedCodeEditor?.requestDocumentation() }
    func showEditorCompletions() { focusedCodeEditor?.requestCompletions() }

    func nextLanguageIssue() {
        guard let document = activeDocument else { return }
        let issues = language.diagnostics[document.id, default: []]
        guard !issues.isEmpty else { userNotice = language.ready ? "No issues in this document." : language.status; return }
        let editor = focusedCodeEditor
        let editorIDs = document.notebook?.cells.map(\.id) ?? [document.id]
        let currentEditor = editorIDs.firstIndex(of: editor?.languageEditorID ?? selectedCellID ?? document.id) ?? 0
        let current = issues.firstIndex {
            let targetEditor = editorIDs.firstIndex(of: $0.editorID) ?? 0
            return targetEditor > currentEditor || (targetEditor == currentEditor && $0.range.location > (editor?.selectedRange().location ?? -1))
        }
        let issue = issues[current ?? 0]
        revealLanguageLocation(documentID: document.id, editorID: issue.editorID, offset: issue.range.location)
    }

    func revealLanguageLocation(documentID: UUID, editorID: UUID, offset: Int) {
        guard let document = openDocuments.first(where: { $0.id == documentID }) else { return }
        activeDocumentID = documentID
        if let cell = document.notebook?.cells.first(where: { $0.id == editorID }) {
            cell.isSourceCollapsed = false
            selectedCellID = editorID
            scrollRequest = editorID
            isCommandMode = false
            focusCellEditor(editorID, caret: offset)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard let editor = EditorRegistry.shared.view(for: editorID), editor.string.utf16.count >= offset else { return }
                editor.window?.makeFirstResponder(editor)
                editor.setSelectedRange(NSRange(location: offset, length: 0))
                editor.scrollRangeToVisible(NSRange(location: offset, length: 0))
            }
        }
    }
}
