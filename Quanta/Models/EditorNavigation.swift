import AppKit

extension AppState {
    func togglePin(_ document: Document) {
        document.isPinned.toggle()
        openDocuments = openDocuments.filter(\.isPinned) + openDocuments.filter { !$0.isPinned }
        persistSession()
    }

    func reopenClosedDocument() {
        guard let url = closedDocuments.first else { return }
        closedDocuments.removeFirst()
        openFile(url)
    }

    func toggleSplitEditor() {
        if splitDocumentID != nil {
            splitDocumentID = nil
            primarySplitDocumentID = nil
        } else if let activeDocumentID {
            primarySplitDocumentID = activeDocumentID
            splitDocumentID = openDocuments.first { $0.id != activeDocumentID }?.id ?? activeDocumentID
        }
    }

    func reorderDocument(_ id: UUID, beside target: UUID, after: Bool) {
        guard id != target,
              let from = openDocuments.firstIndex(where: { $0.id == id }) else { return }
        var reordered = openDocuments
        let document = reordered.remove(at: from)
        guard let dest = reordered.firstIndex(where: { $0.id == target }) else { return }
        reordered.insert(document, at: after ? dest + 1 : dest)
        openDocuments = reordered.filter(\.isPinned) + reordered.filter { !$0.isPinned }
        persistSession()
    }

    func moveDocumentToEnd(_ id: UUID) {
        guard let from = openDocuments.firstIndex(where: { $0.id == id }) else { return }
        var reordered = openDocuments
        let document = reordered.remove(at: from)
        reordered.append(document)
        openDocuments = reordered.filter(\.isPinned) + reordered.filter { !$0.isPinned }
        persistSession()
    }

    func tabTitle(_ document: Document) -> String {
        guard let url = document.url,
              openDocuments.filter({ $0.displayName == document.displayName }).count > 1 else { return document.displayName }
        return relativePath(url)
    }

    func navigateTo(file: String, line: Int, cellID: UUID? = nil) {
        if let cellID, let document = openDocuments.first(where: { $0.notebook?.cells.contains { $0.id == cellID } == true }),
           let cell = document.notebook?.cells.first(where: { $0.id == cellID }) {
            activeDocumentID = document.id
            selectedCellID = cellID
            cell.isSourceCollapsed = false
            let text = cell.source as NSString
            let caret = Self.lineLocation(in: text, line: line)
            focusCellEditor(cellID, caret: caret)
        } else if !file.hasPrefix("<") {
            let url = file.hasPrefix("/") ? URL(fileURLWithPath: file)
                : (workspace?.rootURL ?? FileManager.default.homeDirectoryForCurrentUser).appendingPathComponent(file)
            openSearchResult(FileSearchResult(fileURL: url, line: line, preview: ""))
        }
    }

    static func lineLocation(in text: NSString, line: Int) -> Int {
        guard line > 1 else { return 0 }
        var result = text.length
        var current = 1
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]) { _, range, _, stop in
            if current == line { result = range.location; stop.pointee = true }
            current += 1
        }
        return result
    }
}

struct TracebackLocation: Equatable {
    let file: String
    let line: Int
    static func parse(_ text: String) -> [TracebackLocation] {
        guard let regex = try? NSRegularExpression(pattern: #"File "([^"]+)", line (\d+)"#) else { return [] }
        let text = text as NSString
        return regex.matches(in: text as String, range: NSRange(location: 0, length: text.length)).compactMap { match in
            let file = text.substring(with: match.range(at: 1))
            guard !file.hasPrefix("<"), let line = Int(text.substring(with: match.range(at: 2))) else { return nil }
            return TracebackLocation(file: file, line: line)
        }
    }
}
